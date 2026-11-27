#!/usr/bin/env python3
"""Interactive click-to-kill window picker for Noctalia Suite under Umbriel."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

PROTECTED_NAMES = frozenset({
    "umbriel",
    "noctalia",
    "noctalia-greeter",
    "xwayland-satellite",
    "xwayland",
    "systemd",
    "dbus-daemon",
    "dbus-broker",
    "pipewire",
    "wireplumber",
})

SLURP_ARGS = [
    "slurp",
    "-r",
    "-f",
    "%l",
    "-b",
    "#080D1940",
    "-c",
    "#FF3355FF",
    "-s",
    "#FF335528",
    "-B",
    "#00000000",
    "-w",
    "3",
]


def pid_file_path() -> Path:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if runtime_dir:
        return Path(runtime_dir) / "noctalia-kill-window.pid"
    return Path(f"/tmp/noctalia-kill-window-{os.getuid()}.pid")


def notify(summary: str, body: str = "", urgency: str = "normal") -> None:
    cmd = ["notify-send", "-a", "Kill Window", "-u", urgency, summary]
    if body:
        cmd.append(body)
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def normalize_proc_name(name: str) -> str:
    clean = name.strip().lower().lstrip(".")
    if clean.endswith("-wrapped"):
        clean = clean[: -len("-wrapped")]
    return clean


def is_protected_name(name: str) -> bool:
    if not name:
        return False
    return normalize_proc_name(name) in PROTECTED_NAMES


def is_protected_pid(pid: int | None) -> bool:
    if pid is None or not isinstance(pid, int) or isinstance(pid, bool):
        return True
    if pid <= 1 or pid in (os.getpid(), os.getppid()):
        return True

    names: list[str] = []
    try:
        names.append(Path(f"/proc/{pid}/comm").read_text(encoding="utf-8", errors="replace"))
    except OSError:
        pass
    try:
        names.append(os.path.basename(os.readlink(f"/proc/{pid}/exe")))
    except OSError:
        pass

    return any(is_protected_name(name) for name in names)


def parse_proc_stat(stat_text: str) -> tuple[str, str] | None:
    rparen = stat_text.rfind(")")
    if rparen == -1:
        return None
    tail = stat_text[rparen + 1 :].strip()
    fields = tail.split()
    if len(fields) <= 19:
        return None
    return fields[0], fields[19]


def read_proc_stat(pid: int) -> tuple[str, str] | None:
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    return parse_proc_stat(text)


def terminate_pid(pid: int, timeout: float = 0.5, poll_interval: float = 0.05) -> str:
    initial = read_proc_stat(pid)
    if initial is None or initial[0] == "Z":
        return "already_exited"
    _, initial_starttime = initial

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return "already_exited"
    except PermissionError:
        return "permission_denied"

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(poll_interval)
        current = read_proc_stat(pid)
        if current is None or current[0] == "Z" or current[1] != initial_starttime:
            return "sigterm"

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return "sigterm"
    except PermissionError:
        return "permission_denied"

    kill_deadline = time.monotonic() + 0.2
    while time.monotonic() < kill_deadline:
        time.sleep(0.02)
        current = read_proc_stat(pid)
        if current is None or current[0] == "Z" or current[1] != initial_starttime:
            break
    return "sigkill"


def rect_contains(outer: tuple[int, int, int, int], inner: tuple[int, int, int, int]) -> bool:
    ox1, oy1, ox2, oy2 = outer
    ix1, iy1, ix2, iy2 = inner
    return ix1 >= ox1 and iy1 >= oy1 and ix2 <= ox2 and iy2 <= oy2


def build_slurp_entries(windows: list[dict], outputs: list[dict]) -> list[dict]:
    enabled_bounds: dict[str, tuple[int, int, int, int]] = {}
    disabled_outputs: set[str] = set()

    for output in outputs:
        name = output.get("name")
        if not name:
            continue
        if not output.get("enabled", False):
            disabled_outputs.add(name)
            continue
        pos = output.get("position") or {}
        size = output.get("logical_size") or {}
        ox = int(pos.get("x", 0))
        oy = int(pos.get("y", 0))
        ow = int(size.get("width", 0))
        oh = int(size.get("height", 0))
        if ow > 0 and oh > 0:
            enabled_bounds[name] = (ox, oy, ox + ow, oy + oh)

    clipped_candidates: list[dict] = []
    fullscreen_outputs: set[str] = set()

    for idx, win in enumerate(windows):
        if not win.get("visible", False) or win.get("tab_hidden", False):
            continue
        win_id = win.get("id")
        if not win_id:
            continue
        out_name = win.get("output") or ""
        if out_name in disabled_outputs:
            continue

        x1 = int(win.get("x", 0))
        y1 = int(win.get("y", 0))
        w = int(win.get("w", 0))
        h = int(win.get("h", 0))
        x2 = x1 + w
        y2 = y1 + h

        if out_name in enabled_bounds:
            ox1, oy1, ox2, oy2 = enabled_bounds[out_name]
            x1 = max(x1, ox1)
            y1 = max(y1, oy1)
            x2 = min(x2, ox2)
            y2 = min(y2, oy2)

        cw = x2 - x1
        ch = y2 - y1
        if cw <= 0 or ch <= 0:
            continue

        is_fs = bool(win.get("fullscreen", False))
        if is_fs and out_name:
            fullscreen_outputs.add(out_name)

        clipped_candidates.append({
            "id": win_id,
            "output": out_name,
            "x": x1,
            "y": y1,
            "w": cw,
            "h": ch,
            "rect": (x1, y1, x2, y2),
            "rank": (
                is_fs,
                bool(win.get("pinned", False)),
                bool(win.get("floating", False)),
                bool(win.get("focused", False)),
                bool(win.get("active", False)),
                -idx,
            ),
        })

    visible_on_outputs = [
        item
        for item in clipped_candidates
        if item["output"] not in fullscreen_outputs or item["rank"][0]
    ]

    # Sort top-to-bottom first to prune windows completely occluded by a higher-ranked window
    # on the same output, then reverse so topmost sits LAST (slurp -r picks last on equal area).
    top_to_bottom = sorted(visible_on_outputs, key=lambda item: item["rank"], reverse=True)
    kept_top_to_bottom: list[dict] = []
    for item in top_to_bottom:
        occluded = any(
            higher["output"] == item["output"] and rect_contains(higher["rect"], item["rect"])
            for higher in kept_top_to_bottom
        )
        if not occluded:
            kept_top_to_bottom.append(item)

    kept_bottom_to_top = list(reversed(kept_top_to_bottom))
    return [
        {
            "id": item["id"],
            "output": item["output"],
            "x": item["x"],
            "y": item["y"],
            "w": item["w"],
            "h": item["h"],
        }
        for item in kept_bottom_to_top
    ]


def format_slurp_stdin(entries: list[dict]) -> str:
    return "".join(f"{e['x']},{e['y']} {e['w']}x{e['h']} {e['id']}\n" for e in entries)


def query_umbriel_json(subcommand: str) -> list[dict]:
    res = subprocess.run(["umbriel", subcommand, "--json"], capture_output=True, text=True, check=True)
    data = json.loads(res.stdout)
    return data if isinstance(data, list) else []


def toggle_existing_instance(pid_path: Path) -> bool:
    try:
        raw = pid_path.read_text(encoding="utf-8").strip()
        existing_pid = int(raw)
    except (OSError, ValueError):
        return False

    if existing_pid <= 1 or existing_pid == os.getpid():
        return False

    try:
        cmdline = Path(f"/proc/{existing_pid}/cmdline").read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return False

    if "kill-window.py" not in cmdline:
        return False

    try:
        os.kill(existing_pid, signal.SIGTERM)
    except OSError:
        return False
    return True


def main() -> int:
    pid_path = pid_file_path()
    if toggle_existing_instance(pid_path):
        return 0

    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")

    slurp_proc: subprocess.Popen[str] | None = None

    def handle_signal(_signum: int, _frame: object) -> None:
        if slurp_proc is not None and slurp_proc.poll() is None:
            try:
                slurp_proc.terminate()
            except OSError:
                pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        try:
            outputs = query_umbriel_json("outputs")
            windows_before = query_umbriel_json("windows")
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            notify("Kill Window failed", f"Could not query compositor windows: {exc}", urgency="critical")
            return 1

        entries = build_slurp_entries(windows_before, outputs)
        if not entries:
            notify("Kill Window", "No visible windows to kill.", urgency="low")
            return 0

        slurp_proc = subprocess.Popen(
            SLURP_ARGS,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, _ = slurp_proc.communicate(input=format_slurp_stdin(entries))
        if slurp_proc.returncode != 0:
            return 0

        selected_id = stdout.strip()
        if not selected_id:
            return 0

        try:
            windows_now = query_umbriel_json("windows")
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
            windows_now = windows_before

        target = next((w for w in windows_now if w.get("id") == selected_id), None)
        if target is None:
            target = next((w for w in windows_before if w.get("id") == selected_id), None)
        if target is None:
            return 0

        app_id = target.get("app_id") or "window"
        title = target.get("title") or app_id
        pid = target.get("pid")

        if is_protected_pid(pid):
            subprocess.run(["umbriel", "msg", f"window-close:{selected_id}"], check=False)
            notify(
                f"Closed {app_id}",
                f"Sent close request to '{title}' instead of killing protected/unknown PID ({pid}).",
            )
            return 0

        assert isinstance(pid, int)
        outcome = terminate_pid(pid)
        if outcome == "sigterm":
            notify(f"Killed {app_id}", f"{title} (PID {pid}, SIGTERM)")
        elif outcome == "sigkill":
            notify(f"Force-killed {app_id}", f"{title} (PID {pid}, SIGKILL)")
        elif outcome == "already_exited":
            notify(f"Closed {app_id}", f"{title} (PID {pid}) had already exited.", urgency="low")
        elif outcome == "permission_denied":
            notify(
                f"Cannot kill {app_id}",
                f"Permission denied signaling PID {pid} ('{title}').",
                urgency="critical",
            )
            return 1
        return 0
    finally:
        if slurp_proc is not None and slurp_proc.poll() is None:
            try:
                slurp_proc.terminate()
                slurp_proc.wait(timeout=0.5)
            except (OSError, subprocess.SubprocessError):
                pass
        try:
            if pid_path.is_file() and pid_path.read_text(encoding="utf-8").strip() == str(os.getpid()):
                pid_path.unlink(missing_ok=True)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
