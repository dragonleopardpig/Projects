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


def send_mega_command(op_code: str, target_path: str) -> bool:
    if not SOCKET_PATH.exists():
        notify("MEGAsync", "MEGAsync does not appear to be running. Starting it now...", urgency="critical")
        subprocess.Popen(["megasync"])
        return False

    abs_path = str(Path(target_path).resolve())
    payload = f"{op_code}:{abs_path}\0".encode("utf-8")

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        sock.connect(str(SOCKET_PATH))
        sock.sendall(payload)
        resp = sock.recv(1024)
        sock.close()
        return True
    except Exception as e:
        notify("MEGAsync Error", f"Failed to talk to MEGAsync socket: {e}", urgency="critical")
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
