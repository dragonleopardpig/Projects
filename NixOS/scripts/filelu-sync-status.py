#!/usr/bin/env python3
"""
FileLuSync Live Status & Health Monitor
Provides real-time JSON status for AGS bar / tray widgets and CLI diagnostics.
Monitors FileLuSync progress, active rclone file transfers, and FUSE mount health.
"""

import argparse
import json
import os
from pathlib import Path
import pickle
import sqlite3
import subprocess
import sys
import time

DEFAULT_MOUNT_POINT = Path.home() / "FileLu"
DATA_DB = Path.home() / ".FileLuSync/data.db"
SYNC_DB = Path.home() / ".FileLuSync/syncfiles.db"


def get_account_info() -> dict | None:
    if not DATA_DB.exists():
        return None
    try:
        conn = sqlite3.connect(str(DATA_DB))
        cur = conn.cursor()
        cur.execute("SELECT key, value FROM data")
        username = None
        for k, v in cur.fetchall():
            try:
                val = pickle.loads(v)
            except Exception:
                continue
            if k == "username" and val:
                username = str(val)
        conn.close()
        if username:
            return {"username": username, "logged_in": True}
    except Exception:
        pass
    return None


def get_sync_folders() -> list[dict]:
    folders = []
    if not SYNC_DB.exists():
        return folders
    try:
        conn = sqlite3.connect(str(SYNC_DB))
        cur = conn.cursor()
        cur.execute("SELECT local_folder, remote_folder, is_running, trigger_mode, last_result, last_message FROM sync_configs")
        for r in cur.fetchall():
            folders.append({
                "local_path": r[0],
                "remote_path": r[1],
                "is_running": bool(r[2]),
                "trigger_mode": r[3],
                "last_result": r[4],
                "last_message": r[5]
            })
        conn.close()
    except Exception:
        pass
    return folders


def get_dbus_tooltip() -> tuple[str | None, str | None]:
    """Returns (title, status) directly from FileLu's D-Bus connection without contacting StatusNotifierWatcher"""
    candidate_buses = []
    try:
        out = subprocess.check_output(["busctl", "--user", "list"], text=True, timeout=1)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "FileLuSync.bin":
                candidate_buses.append(parts[0])
    except Exception:
        pass

    for bus in candidate_buses:
        try:
            tt_out = subprocess.check_output(
                ["busctl", "--user", "--json=pretty", "get-property", bus, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "ToolTip"],
                text=True, timeout=1, stderr=subprocess.DEVNULL
            )
            tt_data = json.loads(tt_out)
            data_arr = tt_data.get("data", ["", [], "", ""])
            title = data_arr[2] if len(data_arr) > 2 else ""
            desc = data_arr[3] if len(data_arr) > 3 else ""
            if title:
                return title, desc
        except Exception:
            continue

    return None, None


def get_active_workers() -> list[dict]:
    """Scans /proc for active filelu_linux_amd copy processes"""
    workers = []
    my_pid = os.getpid()
    for p in Path("/proc").glob("[0-9]*"):
        try:
            pid = int(p.name)
            if pid == my_pid:
                continue
            # Check executable name
            try:
                exe = (p / "exe").resolve().name
            except Exception:
                exe = ""
            if "filelu" not in exe and "rclone" not in exe:
                # also check cmdline if exe symlink is unreadable
                pass
            cmdline = (p / "cmdline").read_bytes().split(b"\0")
            cmd_str = " ".join(arg.decode(errors="replace") for arg in cmdline)
            if "filelu_linux_amd" in cmd_str and "copyto" in cmd_str:
                non_empty = [arg.decode(errors="replace") for arg in cmdline if arg]
                local_file = non_empty[-1] if non_empty else None
                remote_dest = non_empty[-2] if len(non_empty) >= 2 else None
                file_size = None
                if local_file and os.path.exists(local_file) and not os.path.isdir(local_file):
                    sz = os.path.getsize(local_file)
                    if sz >= 1024 * 1024 * 1024:
                        file_size = f"{sz / (1024**3):.1f} GB"
                    elif sz >= 1024 * 1024:
                        file_size = f"{sz / (1024**2):.1f} MB"
                    elif sz >= 1024:
                        file_size = f"{sz / 1024:.1f} KB"
                    else:
                        file_size = f"{sz} B"
                filename = os.path.basename(local_file) if local_file else None
                workers.append({
                    "pid": pid,
                    "filename": filename,
                    "local_path": local_file,
                    "remote_dest": remote_dest,
                    "size": file_size
                })
        except (OSError, ValueError):
            continue
    return workers


def is_mounted(mount_point: Path) -> bool:
    try:
        p = mount_point.resolve()
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == str(p):
                    return True
    except Exception:
        pass
    return False


def get_mount_pid() -> int | None:
    for p in Path("/proc").glob("[0-9]*"):
        try:
            cmdline = (p / "cmdline").read_bytes().split(b"\0")
            cmd_str = " ".join(arg.decode(errors="replace") for arg in cmdline)
            if "filelu-rclone" in cmd_str and "mount" in cmd_str:
                return int(p.name)
        except (OSError, ValueError):
            continue
    return None


def collect_status() -> dict:
    account = get_account_info()
    folders = get_sync_folders()
    workers = get_active_workers()
    dbus_title, dbus_desc = get_dbus_tooltip()
    mount_point = DEFAULT_MOUNT_POINT
    mounted = is_mounted(mount_point)
    mount_pid = get_mount_pid()

    # Determine state and label
    state = "idle"
    if dbus_title:
        label = dbus_title.replace("FileLuSync · ", "").strip()
        t_low = dbus_title.lower()
        if "syncing" in t_low or workers:
            state = "syncing"
        elif "paused" in t_low:
            state = "paused"
        elif "offline" in t_low:
            state = "offline"
        elif "not signed in" in t_low:
            state = "not_signed_in"
        elif "up to date" in t_low:
            state = "ok"
    elif workers:
        state = "syncing"
        label = f"Syncing {len(workers)} active files"
    else:
        label = "Up to date" if account else "Not signed in"
        state = "ok" if account else "not_signed_in"

    return {
        "state": state,
        "label": label,
        "dbus_title": dbus_title,
        "dbus_desc": dbus_desc,
        "workers": workers,
        "account": account,
        "folders": folders,
        "mount_point": str(mount_point),
        "mounted": mounted,
        "rclone_alive": bool(mount_pid),
        "rclone_mount_pid": mount_pid,
        "updated": time.time(),
    }


def main():
    parser = argparse.ArgumentParser(description="FileLuSync Status & Health Monitor")
    parser.add_argument("--json", action="store_true", help="Output status as JSON")
    args = parser.parse_args()

    status = collect_status()

    if args.json:
        print(json.dumps(status))
    else:
        print(f"FileLuSync — {status['label']}")
        if status['account']:
            print(f"Account:      {status['account']['username']}")
        if status['workers']:
            print(f"Active Files: {len(status['workers'])}")
            for w in status['workers']:
                sz = f" ({w['size']})" if w['size'] else ""
                print(f"  • {w['filename']}{sz}")
        print(f"Mount Point:  {status['mount_point']} (Mounted: {status['mounted']}, Alive: {status['rclone_alive']})")
        for f in status['folders']:
            print(f"Synced Dir:   {f['local_path']} -> {f['remote_path']}")


if __name__ == "__main__":
    main()
