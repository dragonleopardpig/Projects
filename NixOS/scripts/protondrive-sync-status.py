#!/usr/bin/env python3
"""
Proton Drive Live Status & Health Monitor
Provides real-time JSON status for AGS bar / tray widgets and CLI diagnostics.
Monitors rclone FUSE mount health and alerts immediately when rclone dies.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

DEFAULT_MOUNT_POINT = Path.home() / "Proton Drive"
CONFIG_FILE = Path.home() / ".config/protondrive-sync/config.json"
STATE_DIR = Path.home() / ".local/state/protondrive-sync"
HEALTH_FILE = STATE_DIR / "mount-health.json"


def send_notification(title: str, message: str, icon: str = "dialog-warning", urgency: str = "critical"):
    notify_send = shutil.which("notify-send")
    if notify_send:
        try:
            subprocess.run(
                [notify_send, "-a", "Proton Drive", "-i", icon, "-u", urgency, title, message],
                check=False,
            )
        except Exception:
            pass


def check_alive(pid: int) -> bool:
    try:
        if pid <= 0:
            return False
        stat = Path(f"/proc/{pid}/stat").read_text()
        state = stat.rsplit(") ", 1)[1][0]
        return state != "Z"
    except (OSError, ValueError, IndexError):
        return False


def is_mounted(mount_point: Path) -> bool:
    p = mount_point.resolve()
    if not p.exists():
        return False
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == str(p):
                    return True
    except Exception:
        pass
    return os.path.ismount(str(p))


def get_workers(mount_pid: int) -> list[dict]:
    workers = []
    my_pid = os.getpid()
    for p in Path("/proc").glob("[0-9]*"):
        try:
            pid = int(p.name)
            if pid == mount_pid or pid == my_pid:
                continue
            exe = (p / "exe").resolve().name
            if "rclone" in exe:
                cmdline = (p / "cmdline").read_bytes().split(b"\0")
                cmd_str = " ".join(arg.decode(errors="replace") for arg in cmdline)
                if "protondrive:" in cmd_str or "protondrive" in cmd_str:
                    subcmd = cmdline[1].decode(errors="replace") if len(cmdline) > 1 else "worker"
                    workers.append({"pid": pid, "command": subcmd})
        except (OSError, ValueError):
            continue
    return workers


def get_systemd_props() -> dict:
    props = {}
    try:
        res = subprocess.run(
            ["systemctl", "--user", "show", "protondrive-mount.service",
             "-p", "ActiveState,SubState,Result,MainPID,StatusText"],
            capture_output=True, text=True, timeout=2
        )
        for line in res.stdout.strip().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k] = v
    except Exception as e:
        props["Error"] = str(e)
    return props


def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def collect_status() -> dict:
    cfg = load_config()
    mount_str = cfg.get("mount_point", str(DEFAULT_MOUNT_POINT))
    mount_point = Path(mount_str)

    props = get_systemd_props()
    active_state = props.get("ActiveState", "inactive")
    sub_state = props.get("SubState", "dead")
    result = props.get("Result", "unknown")
    status_text = props.get("StatusText", "")
    try:
        main_pid = int(props.get("MainPID", 0))
    except ValueError:
        main_pid = 0

    mounted = is_mounted(mount_point)
    rclone_alive = mounted and (main_pid > 0 and check_alive(main_pid))

    # If a separate rclone process rotated `client_refresh_token` in rclone.conf after
    # `protondrive-mount.service` started, restart the mount service so it reloads the
    # fresh token instead of returning EIO on directory access.
    if rclone_alive and main_pid > 0:
        try:
            rclone_conf = Path.home() / ".config/rclone/rclone.conf"
            proc_dir = Path(f"/proc/{main_pid}")
            if rclone_conf.exists() and proc_dir.exists():
                if rclone_conf.stat().st_mtime > proc_dir.stat().st_mtime + 2.0:
                    subprocess.run(
                        ["systemctl", "--user", "restart", "protondrive-mount.service"],
                        check=False,
                        timeout=10,
                    )
        except Exception:
            pass

    workers = get_workers(main_pid)
    paused = cfg.get("paused", False)
    folders = cfg.get("folders", [])
    interval_mins = cfg.get("auto_sync_interval_minutes", 10)

    # Health transition check
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    prev_alive = None
    if HEALTH_FILE.exists():
        try:
            prev_data = json.loads(HEALTH_FILE.read_text(encoding="utf-8"))
            prev_alive = prev_data.get("rclone_alive")
        except Exception:
            pass

    try:
        HEALTH_FILE.write_text(
            json.dumps({"rclone_alive": rclone_alive, "timestamp": time.time()}),
            encoding="utf-8"
        )
    except Exception:
        pass

    if prev_alive is True and not rclone_alive:
        send_notification(
            "Proton Drive Alert",
            f"Rclone mount process died! {mount_point} is disconnected.",
            icon="dialog-error",
            urgency="critical"
        )

    # Determine state and label
    if not mounted:
        state = "stopped"
        label = "Unmounted"
        summary = f"Proton Drive is not mounted ({mount_point})"
    elif not rclone_alive:
        state = "error"
        label = "Rclone Mount Died"
        summary = f"Rclone FUSE mount is dead ({active_state}/{sub_state}). Drive disconnected."
    elif any(f.get("status") == "error" for f in folders):
        state = "error"
        label = "Sync Error"
        summary = "One or more synchronized folders encountered an error."
    elif workers:
        state = "busy"
        label = f"Syncing ({len(workers)} active)"
        summary = f"Rclone transfer active: PID {', '.join(str(w['pid']) for w in workers)}"
    elif paused:
        state = "paused"
        label = "Auto-Sync Paused"
        summary = f"Proton Drive mount active, auto-sync paused ({mount_point})"
    else:
        state = "ok"
        label = "Mounted & Idle"
        summary = f"Proton Drive FUSE mounted at {mount_point}"

    last_sync = None
    for f in folders:
        ls = f.get("last_sync")
        if ls and ls != "Never":
            if last_sync is None or ls > last_sync:
                last_sync = ls

    account_file = Path.home() / ".config/protondrive-sync/account.json"
    account = None
    if account_file.exists():
        try:
            account = json.loads(account_file.read_text(encoding="utf-8"))
        except Exception:
            pass

    return {
        "state": state,
        "label": label,
        "summary": summary,
        "mount_point": str(mount_point),
        "mounted": mounted,
        "rclone_alive": rclone_alive,
        "rclone_mount_pid": main_pid if rclone_alive else None,
        "service_state": active_state,
        "service_substate": sub_state,
        "result": result,
        "vfs_status": status_text,
        "workers": workers,
        "folders_count": len(folders),
        "folders": folders,
        "paused": paused,
        "interval_minutes": interval_mins,
        "last_sync": last_sync,
        "account": account,
        "updated": time.time(),
    }


def main():
    parser = argparse.ArgumentParser(description="Proton Drive Sync & Rclone Health Status")
    parser.add_argument("--json", action="store_true", help="Output status as JSON")
    args = parser.parse_args()

    status = collect_status()

    if args.json:
        print(json.dumps(status))
    else:
        print(f"Proton Drive — {status['label']}")
        print(f"Summary:       {status['summary']}")
        print(f"Mount Point:   {status['mount_point']} (Mounted: {status['mounted']})")
        print(f"Rclone Alive:  {status['rclone_alive']} (PID: {status['rclone_mount_pid']})")
        if status['vfs_status']:
            print(f"VFS Status:    {status['vfs_status']}")
        if status['account'] and status['account'].get('logged_in'):
            acc = status['account']
            print(f"Account:       {acc.get('name')} ({acc.get('email')}) — Quota: {acc.get('usage_str')} / {acc.get('limit_str')} ({acc.get('percent_str')})")
        print(f"Auto-Sync:     {'Paused' if status['paused'] else f'Active ({status['interval_minutes']}m interval)'}")
        print(f"Folders ({status['folders_count']}):")
        for f in status['folders']:
            print(f"  • {f.get('local_path')} -> {f.get('status','idle')} (Last sync: {f.get('last_sync','Never')})")


if __name__ == "__main__":
    main()
