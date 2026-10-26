#!/usr/bin/env python3
"""
Nemo context menu helper for Filen Desktop
Focuses Filen Desktop window, copies target path to clipboard, and sends notifications.
"""

from pathlib import Path
import shutil
import subprocess
import sys


def notify(title: str, message: str, icon: str = "filen-desktop", urgency: str = "normal"):
    notify_send = shutil.which("notify-send")
    if notify_send:
        try:
            subprocess.run([notify_send, "-a", "Filen Desktop", "-i", icon, "-u", urgency, title, message], check=False)
        except Exception:
            pass


def copy_to_clipboard(text: str):
    wl_copy = shutil.which("wl-copy")
    if wl_copy:
        try:
            subprocess.run([wl_copy, text], check=True)
            return True
        except Exception:
            pass
    return False


def focus_filen():
    hyprctl = shutil.which("hyprctl")
    if hyprctl:
        try:
            res = subprocess.run([hyprctl, "dispatch", "focuswindow", "class:^([Ff]ilen[ -][Dd]esktop)$"], capture_output=True, text=True)
            if "ok" in res.stdout.lower():
                return True
        except Exception:
            pass
    # If not running or not focused, invoke desktop launcher
    subprocess.Popen(["filen-desktop"])
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: filen-nemo-action.py <sync|open> [path]")
        sys.exit(1)

    action = sys.argv[1].lower()
    target_path = sys.argv[2] if len(sys.argv) > 2 else ""

    if action == "open":
        focus_filen()
        notify("Filen Desktop", "Opened Filen Desktop")
        sys.exit(0)

    if action == "sync" and target_path:
        p = Path(target_path).resolve()
        name = p.name
        copy_to_clipboard(str(p))
        focus_filen()
        notify(
            "Filen Sync",
            f"Path for '{name}' copied to clipboard!\nIn Filen: go to Syncs → Add Sync → paste path into folder chooser.",
            urgency="normal",
        )
        sys.exit(0)


if __name__ == "__main__":
    main()
