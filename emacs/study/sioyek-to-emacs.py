#!/usr/bin/env python3
"""Sioyek -> Emacs Study AI bridge.

Run from Sioyek custom commands: send selected text, or crop a dragged
rectangle of the page into a vector SVG (+ PNG for vision models) and push it to
the Study AI pane running inside Emacs.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import study_assets  # noqa: E402

SNIP_DIR = os.path.expanduser("~/.cache/emacs-study/snips")


def runtime_path():
    return os.environ.get("EMACS_STUDY_RUNTIME") or os.path.join(
        os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "emacs-study-server.json")


def notify(summary, body="", urgent=False):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Emacs Study", "-u", "critical" if urgent else "normal",
                        summary, body], check=False)
    print("%s %s" % (summary, body), file=sys.stderr)


def read_runtime():
    try:
        with open(runtime_path()) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def post(runtime, payload):
    request = urllib.request.Request(
        "http://127.0.0.1:%d/api/context" % runtime["port"], data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Study-Token": runtime["token"]})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def wake_emacs():
    emacsclient = shutil.which("emacsclient")
    if not emacsclient:
        return False
    result = subprocess.run([emacsclient, "--no-wait", "--eval", "(my/study-open)"],
                            capture_output=True, text=True, check=False)
    return result.returncode == 0


def deliver(payload):
    runtime = read_runtime()
    if runtime:
        try:
            return post(runtime, payload)
        except (urllib.error.URLError, OSError):
            pass
    if not wake_emacs():
        raise RuntimeError("Emacs is not running (start it, or enable the server)")
    deadline = time.time() + 8
    while time.time() < deadline:
        time.sleep(0.25)
        runtime = read_runtime()
        if runtime:
            try:
                return post(runtime, payload)
            except (urllib.error.URLError, OSError):
                continue
    raise RuntimeError("The Study AI pane did not start")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("text", "rect"), required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--page", type=int, default=0, help="0-based page index (Sioyek)")
    parser.add_argument("--text", default="")
    parser.add_argument("--rect", default="")
    parser.add_argument("--snip-dir", default=SNIP_DIR)
    args = parser.parse_args(argv)

    payload = {"file": args.file, "page": args.page + 1}
    try:
        if args.mode == "text":
            if not args.text.strip():
                notify("Emacs Study", "Select some text first, then press E", urgent=True)
                return 1
            payload["text"] = args.text
            what = "Selected text (p.%d)" % payload["page"]
        else:
            if args.rect.startswith("%{") or not args.rect:
                notify("Emacs Study", "Drag a rectangle first", urgent=True)
                return 1
            page, x0, y0, x1, y1 = (float(v) for v in args.rect.split(","))
            snap = study_assets.crop_pdf_region(args.file, int(page), (x0, y0, x1, y1), args.snip_dir)
            payload.update(page=snap["page"], svg_path=snap["svg_path"], png_path=snap["png_path"])
            what = ("Vector SVG snapshot (p.%d)" if snap["is_vector"] else "Snapshot (p.%d)") % snap["page"]
        deliver(payload)
    except Exception as exc:  # noqa: BLE001
        notify("Emacs Study failed", str(exc), urgent=True)
        return 1
    notify("Sent to Emacs Study AI", what)
    return 0


if __name__ == "__main__":
    sys.exit(main())
