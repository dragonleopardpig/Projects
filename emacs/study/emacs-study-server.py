#!/usr/bin/env python3
"""Local web server behind the Emacs Study AI pane (xwidget-webkit).

Serves the chat UI, relays reading context (text + vector PDF snapshots) from
Sioyek/Emacs, runs the selected AI agent, renders Markdown (KaTeX math, sanitised
SVG) and converts answers to Org.  Talks to Emacs over NDJSON on stdin/stdout.
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import mimetypes
import os
import queue
import secrets
import signal
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import study_agents  # noqa: E402
import study_assets  # noqa: E402

DEFAULT_SNIP_DIR = os.path.expanduser("~/.cache/emacs-study/snips")


class Study:
    """All mutable state of one server session."""

    def __init__(self, args):
        self.args = args
        self.lock = threading.RLock()
        self.token = secrets.token_hex(24)
        self.snip_dir = os.path.realpath(os.path.expanduser(args.snip_dir))
        os.makedirs(self.snip_dir, exist_ok=True)
        self.katex_dir = os.path.realpath(os.path.expanduser(args.katex_dir)) if args.katex_dir else None
        self.agent = args.agent
        self.target_org = os.path.expanduser(args.target_org) if args.target_org else None
        self.theme = {"mode": "auto"}
        self.zoom = 100
        self.context = None
        self.context_sent = False
        self.turns: list[dict] = []
        self.next_id = 0
        self.busy = False
        self.holder: dict = {}
        self.clients: list[queue.Queue] = []
        self.out_lock = threading.Lock()
        self.httpd = None

    # -- plumbing -----------------------------------------------------
    def emit(self, event: str, **payload):
        """Send an NDJSON event to Emacs."""
        if self.args.standalone:
            return
        with self.out_lock:
            sys.stdout.write(json.dumps({"event": event, **payload}) + "\n")
            sys.stdout.flush()

    def broadcast(self, event: str, data=None):
        message = "event: %s\ndata: %s\n\n" % (event, json.dumps(data if data is not None else {}))
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            client.put(message)

    def _inside_snips(self, path):
        if not path:
            return None
        real = os.path.realpath(os.path.expanduser(path))
        if real.startswith(self.snip_dir + os.sep) and os.path.isfile(real):
            return real
        return None

    # -- public state -------------------------------------------------
    def public_context(self):
        ctx = self.context
        if not ctx:
            return None
        return {
            "file": ctx.get("file"), "page": ctx.get("page"),
            "book": os.path.basename(ctx["file"]) if ctx.get("file") else None,
            "text": ctx.get("text"),
            "svg": os.path.basename(ctx["svg_path"]) if ctx.get("svg_path") else None,
            "png": os.path.basename(ctx["png_path"]) if ctx.get("png_path") else None,
        }

    def state(self):
        with self.lock:
            return {
                "agent": self.agent, "agents": study_agents.available_agents(),
                "theme": self.theme, "zoom": self.zoom, "target_org": self.target_org,
                "context": self.public_context(), "busy": self.busy,
                "turns": [{k: v for k, v in turn.items() if k != "images"} for turn in self.turns],
            }

    # -- context ------------------------------------------------------
    def set_context(self, data: dict):
        new = {
            "file": data.get("file") or None,
            "page": data.get("page"),
            "text": (data.get("text") or "").strip() or None,
            "svg_path": self._inside_snips(data.get("svg_path")),
            "png_path": self._inside_snips(data.get("png_path")),
        }
        with self.lock:
            old = self.context
            same = (old and not data.get("replace") and old.get("file") == new["file"]
                    and old.get("page") == new["page"])
            if same:
                merged = dict(old)
                for key in ("text", "svg_path", "png_path"):
                    if new[key]:
                        merged[key] = new[key]
                if new["svg_path"] or new["png_path"]:
                    for key in ("svg_path", "png_path"):
                        if not new[key]:
                            merged[key] = None
                new = merged
            self.context = new if any((new.get("text"), new.get("svg_path"), new.get("png_path"))) else None
            self.context_sent = False
        self.emit("context_received", file=new.get("file"), page=new.get("page"),
                  has_text=bool(new.get("text")), has_snapshot=bool(new.get("svg_path") or new.get("png_path")))
        self.broadcast("context")

    def clear_context(self):
        with self.lock:
            self.context = None
            self.context_sent = False
        self.broadcast("context")

    # -- chat ---------------------------------------------------------
    def _user_message(self, question: str):
        content = question
        images = []
        ctx = self.context
        if ctx and not self.context_sent:
            if ctx.get("file"):
                content += "\n\nSource: %s%s" % (
                    os.path.basename(ctx["file"]), " · Page %s" % ctx["page"] if ctx.get("page") else "")
            if ctx.get("text"):
                content += "\n\nSelected passage:\n%s" % ctx["text"]
            if ctx.get("png_path"):
                with open(ctx["png_path"], "rb") as handle:
                    images.append(base64.b64encode(handle.read()).decode("ascii"))
                content += "\n\n(The attached image is a snapshot of the PDF region.)"
        return content, images

    def ask(self, question: str):
        question = (question or "").strip()
        if not question:
            return {"ok": False, "error": "Empty question"}, HTTPStatus.BAD_REQUEST
        with self.lock:
            if self.busy:
                return {"ok": False, "error": "The agent is still answering"}, HTTPStatus.CONFLICT
            content, images = self._user_message(question)
            self.context_sent = self.context is not None
            self.next_id += 1
            user = {"id": self.next_id, "role": "user", "md": question, "content": content, "images": images}
            self.turns.append(user)
            self.busy = True
            self.holder = {}
            agent = self.agent
            history = [{"role": t["role"], "content": t["content"] if t["role"] == "user" else t["md"],
                        "images": t.get("images", [])}
                       for t in self.turns if not t.get("error")]
        self.broadcast("turn")
        threading.Thread(target=self._run_agent, args=(agent, history, question), daemon=True).start()
        return {"ok": True}, HTTPStatus.OK

    def _run_agent(self, agent, history, question):
        streamed: list[str] = []

        def on_chunk(chunk):
            streamed.append(chunk)
            self.broadcast("chunk", {"text": "".join(streamed)})

        error = None
        answer = ""
        try:
            answer = study_agents.ask(agent, history, on_chunk=on_chunk, holder=self.holder,
                                      mock=self.args.mock_agent)
        except Exception as exc:  # noqa: BLE001 - surfaced to the UI
            error = str(exc) or exc.__class__.__name__
        with self.lock:
            self.next_id += 1
            turn = {"id": self.next_id, "role": "assistant", "agent": agent, "question": question,
                    "label": study_agents.AGENTS.get(agent, {}).get("label", agent)}
            if error:
                turn.update(md="", html="", error=error)
            else:
                turn.update(md=answer, html=study_assets.render_markdown_to_html(answer))
            self.turns.append(turn)
            self.busy = False
        self.broadcast("turn")

    def cancel(self):
        with self.lock:
            holder = self.holder
        study_agents.cancel_process(holder)

    def reset(self):
        self.cancel()
        with self.lock:
            self.turns = []
            self.busy = False
        self.broadcast("reset")

    # -- save to Org --------------------------------------------------
    def _context_for_save(self):
        ctx = self.context or {}
        return {
            "source_pdf": ctx.get("file"), "page": ctx.get("page"),
            "snapshot_svg": ctx.get("svg_path"), "snapshot_png": ctx.get("png_path"),
            "selected_text": ctx.get("text"),
        }

    def save_org(self, data: dict):
        target = data.get("target_org") or self.target_org
        if not target:
            return {"ok": False, "error": "No target Org file; choose one first"}, HTTPStatus.BAD_REQUEST
        target = os.path.expanduser(target)
        org_dir = os.path.dirname(os.path.abspath(target))
        assets_dir = os.path.join(org_dir, "study-assets")
        with self.lock:
            turns = [dict(t) for t in self.turns]
        if data.get("thread"):
            md = study_assets.build_thread_markdown(turns)
            first_q = next((t["md"] for t in turns if t["role"] == "user"), "Study thread")
            agent = next((t.get("label") for t in reversed(turns) if t["role"] == "assistant"), None)
            question = None
            title = first_q
        else:
            turn = next((t for t in turns if t["id"] == data.get("turn_id") and t["role"] == "assistant"), None)
            if turn is None or not turn.get("md"):
                return {"ok": False, "error": "Nothing to save for that answer"}, HTTPStatus.BAD_REQUEST
            md, agent, question = turn["md"], turn.get("label"), turn.get("question")
            title = question
        try:
            result = study_assets.markdown_to_org(
                md, title=title, level=1, assets_dir=assets_dir, org_dir=org_dir, agent=agent,
                question=question, **self._context_for_save())
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR
        payload = {"target": target, "org_text": result["org_text"], "assets": result["assets"],
                   "turn_id": data.get("turn_id")}
        self.emit("save_to_org", **payload)
        return {"ok": True, **payload}, HTTPStatus.OK

    # -- Emacs commands ----------------------------------------------
    def handle_command(self, command: dict):
        name = command.get("cmd")
        if name == "set_target_org":
            with self.lock:
                self.target_org = os.path.expanduser(command["path"]) if command.get("path") else None
            self.broadcast("target")
        elif name == "set_theme":
            with self.lock:
                self.theme = command.get("theme") or {"mode": "auto"}
            self.broadcast("theme")
        elif name == "select_agent":
            if command.get("agent") in study_agents.AGENTS:
                with self.lock:
                    self.agent = command["agent"]
                self.broadcast("agent")
        elif name == "context":
            self.set_context(command)
        elif name == "ask":
            self.ask(command.get("question", ""))
        elif name == "save_ack":
            self.broadcast("saved", {k: command.get(k) for k in ("ok", "file", "error", "turn_id")})
        elif name == "shutdown":
            self.shutdown()

    def shutdown(self):
        self.cancel()
        if self.httpd is not None:
            threading.Thread(target=self.httpd.shutdown, daemon=True).start()


def make_handler(study: Study):
    class Handler(BaseHTTPRequestHandler):
        server_version = "EmacsStudy/1.0"

        def log_message(self, *_args):
            pass

        # -- helpers --
        def _query(self):
            return parse_qs(urlparse(self.path).query)

        def _authorised(self):
            token = self.headers.get("X-Study-Token") or (self._query().get("token") or [""])[0]
            return hmac.compare_digest(token.encode(), study.token.encode())

        def _send(self, status, body: bytes, content_type="application/json", extra=None):
            self.send_response(int(status))
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, payload, status=HTTPStatus.OK):
            self._send(status, json.dumps(payload).encode())

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if not length:
                return {}
            try:
                return json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return {}

        def _file(self, path, content_type=None):
            try:
                with open(path, "rb") as handle:
                    data = handle.read()
            except OSError:
                self._json({"ok": False, "error": "Not found"}, HTTPStatus.NOT_FOUND)
                return
            ctype = content_type or mimetypes.guess_type(path)[0] or "application/octet-stream"
            self._send(HTTPStatus.OK, data, ctype)

        # -- GET --
        def do_GET(self):  # noqa: N802
            parsed = urlparse(self.path)
            route = parsed.path
            if route.startswith("/assets/katex/"):
                if not study.katex_dir:
                    return self._json({"ok": False, "error": "KaTeX is not configured"}, HTTPStatus.NOT_FOUND)
                real = os.path.realpath(os.path.join(study.katex_dir, unquote(route[len("/assets/katex/"):])))
                if not real.startswith(study.katex_dir + os.sep):
                    return self._json({"ok": False}, HTTPStatus.FORBIDDEN)
                return self._file(real)
            if not self._authorised():
                return self._json({"ok": False, "error": "Unauthorised"}, HTTPStatus.UNAUTHORIZED)
            if route == "/":
                return self._file(str(HERE / "study_ui.html"), "text/html; charset=utf-8")
            if route == "/api/state":
                return self._json(study.state())
            if route.startswith("/api/snip/"):
                name = os.path.basename(unquote(route[len("/api/snip/"):]))
                path = study._inside_snips(os.path.join(study.snip_dir, name))
                if not path:
                    return self._json({"ok": False, "error": "Not found"}, HTTPStatus.NOT_FOUND)
                return self._file(path)
            if route == "/api/events":
                return self._events()
            return self._json({"ok": False, "error": "Not found"}, HTTPStatus.NOT_FOUND)

        def _events(self):
            client: queue.Queue = queue.Queue()
            with study.lock:
                study.clients.append(client)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(b"event: hello\ndata: {}\n\n")
                self.wfile.flush()
                while True:
                    try:
                        message = client.get(timeout=15)
                    except queue.Empty:
                        message = ": ping\n\n"
                    self.wfile.write(message.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with study.lock:
                    if client in study.clients:
                        study.clients.remove(client)

        # -- POST --
        def do_POST(self):  # noqa: N802
            if not self._authorised():
                return self._json({"ok": False, "error": "Unauthorised"}, HTTPStatus.UNAUTHORIZED)
            route = urlparse(self.path).path
            data = self._body()
            if route == "/api/context":
                study.set_context(data)
                return self._json({"ok": True, "context": study.public_context()})
            if route == "/api/context/clear":
                study.clear_context()
                return self._json({"ok": True})
            if route == "/api/agent":
                study.handle_command({"cmd": "select_agent", "agent": data.get("agent")})
                return self._json({"ok": True, "agent": study.agent})
            if route == "/api/chat":
                payload, status = study.ask(data.get("question", ""))
                return self._json(payload, status)
            if route == "/api/cancel":
                study.cancel()
                return self._json({"ok": True})
            if route == "/api/reset":
                study.reset()
                return self._json({"ok": True})
            if route == "/api/save-org":
                payload, status = study.save_org(data)
                return self._json(payload, status)
            if route == "/api/choose-org":
                study.emit("choose_org_file")
                return self._json({"ok": True})
            if route == "/api/open-sioyek":
                study.emit("open_sioyek", file=data.get("file"), page=data.get("page"))
                return self._json({"ok": True})
            if route == "/api/zoom":
                with study.lock:
                    study.zoom = int(data.get("zoom", 100))
                return self._json({"ok": True, "zoom": study.zoom})
            if route == "/api/theme":
                study.handle_command({"cmd": "set_theme", "theme": data.get("theme")})
                return self._json({"ok": True})
            return self._json({"ok": False, "error": "Not found"}, HTTPStatus.NOT_FOUND)

    return Handler


def stdin_loop(study: Study):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            study.handle_command(json.loads(line))
        except Exception as exc:  # noqa: BLE001
            study.emit("error", message=str(exc))
    study.shutdown()  # EOF: Emacs went away


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--katex-dir")
    parser.add_argument("--snip-dir", default=DEFAULT_SNIP_DIR)
    parser.add_argument("--target-org")
    parser.add_argument("--agent", default="antigravity", choices=sorted(study_agents.AGENTS))
    parser.add_argument("--runtime-file")
    parser.add_argument("--mock-agent", action="store_true")
    parser.add_argument("--standalone", action="store_true",
                        help="no Emacs on stdin/stdout (tests); print the runtime JSON instead")
    args = parser.parse_args(argv)

    study = Study(args)
    runtime = args.runtime_file or os.path.join(
        os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "emacs-study-server.json")
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(study))
    httpd.daemon_threads = True
    study.httpd = httpd
    port = httpd.server_address[1]

    fd = os.open(runtime, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump({"port": port, "token": study.token, "pid": os.getpid()}, handle)
    os.chmod(runtime, 0o600)

    signal.signal(signal.SIGTERM, lambda *_: study.shutdown())
    signal.signal(signal.SIGINT, lambda *_: study.shutdown())
    if args.standalone:
        print(json.dumps({"port": port, "token": study.token, "runtime": runtime}), flush=True)
    else:
        study.emit("ready", port=port, token=study.token)
        threading.Thread(target=stdin_loop, args=(study,), daemon=True).start()
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            with open(runtime) as handle:
                if json.load(handle).get("pid") == os.getpid():
                    os.unlink(runtime)
        except (OSError, ValueError):
            pass
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
