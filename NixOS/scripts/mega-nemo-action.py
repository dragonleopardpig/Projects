#!/usr/bin/env python3
"""
Nemo context menu helper for MEGAsync
Communicates with running MEGAsync instance over its UNIX domain socket.
"""

import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys

SOCKET_PATH = Path.home() / ".local/share/data/Mega Limited/MEGAsync/mega.socket"


def notify(title: str, message: str, icon: str = "megasync", urgency: str = "normal"):
    notify_send = shutil.which("notify-send")
    if notify_send:
        try:
            subprocess.run([notify_send, "-a", "MEGAsync", "-i", icon, "-u", urgency, title, message], check=False)
        except Exception:
            pass


def focus_mega():
    hyprctl = shutil.which("hyprctl")
    if hyprctl:
        try:
            subprocess.run([hyprctl, "dispatch", "focuswindow", "class:^nz\\.co\\.mega\\."], capture_output=True, check=False)
        except Exception:
            pass


def _connect_and_send(payload: bytes) -> bool:
    if not SOCKET_PATH.exists():
        return False
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(str(SOCKET_PATH))
        sock.sendall(payload)
        sock.recv(1024)
        sock.close()
        return True
    except (ConnectionRefusedError, FileNotFoundError):
        return False
    except Exception as e:
        notify("MEGAsync Error", f"Socket communication error: {e}", urgency="critical")
        return False


def send_mega_command(op_code: str, target_path: str) -> bool:
    abs_path = str(Path(target_path).resolve())
    payload = f"{op_code}:{abs_path}\0".encode("utf-8")

    if _connect_and_send(payload):
        focus_mega()
        return True

    # If socket connection failed or was refused, MEGAsync is not running
    notify("MEGAsync", "MEGAsync is not running. Starting it now...", urgency="normal")
    try:
        subprocess.Popen(["megasync"])
    except Exception as e:
        notify("MEGAsync Error", f"Failed to start MEGAsync: {e}", urgency="critical")
        return False

    # Retry connecting for up to 6 seconds while MEGAsync initializes
    import time
    for _ in range(12):
        time.sleep(0.5)
        if _connect_and_send(payload):
            focus_mega()
            return True

    notify("MEGAsync", "MEGAsync started. Please click Sync with MEGA again.", urgency="normal")
    return False


def main():
    if len(sys.argv) < 3:
        print("Usage: mega-nemo-action.py <upload|sync|backup|link|view> <path>")
        sys.exit(1)

    action = sys.argv[1].lower()
    paths = sys.argv[2:]

    op_codes = {
        "upload": "F",
        "sync": "Y",
        "backup": "B",
        "link": "L",
        "view": "V",
    }

    op = op_codes.get(action)
    if not op:
        print(f"Unknown action: {action}")
        sys.exit(1)

    for p in paths:
        if not p.strip():
            continue
        p_obj = Path(p).resolve()
        name = p_obj.name

        ok = send_mega_command(op, str(p_obj))
        if ok:
            if action == "sync":
                notify("MEGAsync", f"Opening Sync setup dialog for: {name}")
            elif action == "upload":
                notify("MEGAsync", f"Uploading to MEGA: {name}")
            elif action == "link":
                notify("MEGAsync", f"Retrieving MEGA link for: {name}")
            elif action == "backup":
                notify("MEGAsync", f"Opening Backup setup for: {name}")


if __name__ == "__main__":
    main()
