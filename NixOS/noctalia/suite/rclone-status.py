"""Noctalia rclone-status helper: inspects rclone remotes, FUSE mounts, systemd units, active jobs, and launches rclone-control."""

from __future__ import annotations

import argparse
import configparser
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from typing import Any

SYSTEMD_MOUNT_UNITS = (
    ("gdrive-mount.service", "Google Drive", "gdrive:"),
    ("protondrive-mount.service", "Proton Drive", "protondrive:"),
    ("mega-mount.service", "MEGA", "mega:"),
    ("scramble-cloud-mount.service", "Scramble Cloud", "scramble_private:Current"),
    ("filelu-mount.service", "FileLu", "filelu:"),
)

TRANSFER_SUBCOMMANDS = frozenset({
    "copy", "copyto", "copyurl", "move", "moveto",
    "sync", "bisync", "check", "cryptcheck", "purge", "dedupe",
})


def resolve_paths() -> dict[str, Path]:
    home_override = os.environ.get("RCLONE_STATUS_HOME")
    home_dir = Path(home_override) if home_override else Path.home()
    cfg_home = Path(os.environ.get("XDG_CONFIG_HOME") or (home_dir / ".config"))
    rclone_conf = Path(os.environ.get("RCLONE_CONFIG") or (cfg_home / "rclone" / "rclone.conf"))
    jobs_file = cfg_home / "rclone-control" / "jobs.json"
    proc_root = Path(os.environ.get("RCLONE_STATUS_PROC_ROOT") or "/proc")
    mounts_file = Path(os.environ.get("RCLONE_STATUS_MOUNTS_FILE") or "/proc/mounts")
    return {
        "home": home_dir,
        "rclone_conf": rclone_conf,
        "jobs_file": jobs_file,
        "proc_root": proc_root,
        "mounts_file": mounts_file,
    }


def _shorten_path(path_str: str, home_dir: Path) -> str:
    home_s = str(home_dir)
    if path_str == home_s:
        return "~"
    if path_str.startswith(home_s + "/"):
        return "~/" + path_str[len(home_s) + 1:]
    return path_str


def read_remotes(rclone_conf: Path) -> list[dict[str, Any]]:
    if not rclone_conf.is_file():
        return []
    cp = configparser.ConfigParser(interpolation=None)
    try:
        cp.read(rclone_conf, encoding="utf-8")
    except (OSError, configparser.Error):
        return []
    remotes: list[dict[str, Any]] = []
    for name in sorted(cp.sections()):
        sec = cp[name]
        rtype = str(sec.get("type", "unknown"))
        target = (
            sec.get("remote")
            or sec.get("url")
            or sec.get("host")
            or sec.get("endpoint")
            or sec.get("user")
            or "—"
        )
        remotes.append({
            "name": name,
            "type": rtype,
            "target_summary": str(target),
            "mounted": False,
        })
    return remotes


def _read_proc_mounts(mounts_file: Path) -> dict[str, tuple[str, bool]]:
    mounts: dict[str, tuple[str, bool]] = {}
    try:
        content = mounts_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return mounts
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 4 and "fuse.rclone" in parts[2]:
            mp = parts[1].replace("\\040", " ")
            ro = "ro" in parts[3].split(",")
            mounts[mp] = (parts[0], ro)
    return mounts


def _scan_rclone_processes(proc_root: Path) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    """Return (mount_proc_by_mp, active_transfer_jobs)."""
    mounts_by_mp: dict[str, dict[str, Any]] = {}
    jobs: list[dict[str, Any]] = []
    uid = os.getuid()
    my_pid = os.getpid()

    for entry in proc_root.glob("[0-9]*"):
        try:
            pid = int(entry.name)
            if pid == my_pid:
                continue
            if proc_root == Path("/proc") and entry.stat().st_uid != uid:
                continue
            raw = (entry / "cmdline").read_bytes()
            if not raw:
                continue
            args = [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a]
            if not args or "rclone" not in os.path.basename(args[0]):
                continue

            subcmd = next((a for a in args[1:] if not a.startswith("-")), "")
            if subcmd == "mount":
                pos_args = [a for a in args[2:] if not a.startswith("-")]
                vfs_mode = "off"
                ro_flag = "--read-only" in args
                for i, a in enumerate(args):
                    if a.startswith("--vfs-cache-mode="):
                        vfs_mode = a.split("=", 1)[1]
                    elif a == "--vfs-cache-mode" and i + 1 < len(args):
                        vfs_mode = args[i + 1]
                if len(pos_args) >= 2:
                    mounts_by_mp[pos_args[1]] = {
                        "pid": pid,
                        "vfs_cache_mode": vfs_mode,
                        "read_only": ro_flag,
                    }
            elif subcmd in TRANSFER_SUBCOMMANDS:
                pos_args = [a for a in args[1:] if not a.startswith("-")]
                summary = " ".join(pos_args[:3]) if pos_args else subcmd
                jobs.append({
                    "pid": pid,
                    "op": subcmd,
                    "cmd_short": summary,
                })
        except (OSError, ValueError):
            continue
    return mounts_by_mp, jobs


def _query_systemd_units(unit_names: list[str]) -> dict[str, dict[str, str]]:
    if not unit_names or os.environ.get("RCLONE_STATUS_SKIP_SYSTEMD") == "1":
        return {}
    try:
        res = subprocess.run(
            ["systemctl", "--user", "show", *unit_names, "-p", "Id,LoadState,ActiveState"],
            capture_output=True, text=True, timeout=1.5, check=False,
        )
    except OSError:
        return {}
    if res.returncode != 0:
        return {}
    units: dict[str, dict[str, str]] = {}
    cur: dict[str, str] = {}
    for line in res.stdout.splitlines() + [""]:
        if not line.strip():
            uid = cur.get("Id")
            if uid and cur.get("LoadState") == "loaded":
                units[uid] = cur
            cur = {}
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            cur[k] = v
    return units


def _read_saved_jobs_count(jobs_file: Path) -> int:
    if not jobs_file.is_file():
        return 0
    try:
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
        return len(data) if isinstance(data, list) else 0
    except (OSError, ValueError):
        return 0


def _find_rclone_control_bin() -> str | None:
    override = os.environ.get("RCLONE_CONTROL_BIN")
    if override and os.path.isfile(override) and os.access(override, os.X_OK):
        return override
    for candidate in (
        shutil.which("rclone-control"),
        "/run/current-system/sw/bin/rclone-control",
        str(Path.home() / ".local/bin/rclone-control"),
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def build_snapshot() -> dict[str, Any]:
    paths = resolve_paths()
    remotes = read_remotes(paths["rclone_conf"])
    mounts_by_mp = _read_proc_mounts(paths["mounts_file"])
    proc_mounts_info, active_jobs = _scan_rclone_processes(paths["proc_root"])
    systemd_props = _query_systemd_units([u for u, _, _ in SYSTEMD_MOUNT_UNITS])
    saved_jobs_count = _read_saved_jobs_count(paths["jobs_file"])
    gui_available = _find_rclone_control_bin() is not None

    mounts: list[dict[str, Any]] = []
    seen_mps: set[str] = set()
    mounted_remotes: set[str] = set()

    for unit, label, default_src in SYSTEMD_MOUNT_UNITS:
        props = systemd_props.get(unit)
        if not props:
            continue
        active = props.get("ActiveState", "inactive")
        guess_mp = str(paths["home"] / label)
        matched_mp = next(
            (mp for mp, (src, _) in mounts_by_mp.items() if src == default_src or mp == guess_mp),
            guess_mp,
        )
        seen_mps.add(matched_mp)
        is_mounted = matched_mp in mounts_by_mp
        pinfo = proc_mounts_info.get(matched_mp, {})
        ro_flag = mounts_by_mp[matched_mp][1] if is_mounted else bool(pinfo.get("read_only", False))
        state = "mounted" if is_mounted else ("error" if active == "failed" else active)
        if is_mounted:
            mounted_remotes.add(default_src.split(":", 1)[0])
        mounts.append({
            "id": unit.replace(".service", ""),
            "label": label,
            "source": default_src,
            "mountpoint": matched_mp,
            "mountpoint_short": _shorten_path(matched_mp, paths["home"]),
            "systemd_unit": unit,
            "state": state,
            "line_status": "Mounted" if is_mounted else ("Failed" if active == "failed" else active.title()),
            "is_mounted": is_mounted,
            "can_start": not is_mounted,
            "can_stop": is_mounted or active in ("active", "activating"),
            "can_unmount": is_mounted,
            "vfs_cache_mode": str(pinfo.get("vfs_cache_mode", "full")),
            "read_only": ro_flag,
        })

    for mp, (src, ro_flag) in sorted(mounts_by_mp.items()):
        if mp in seen_mps:
            continue
        pinfo = proc_mounts_info.get(mp, {})
        if ":" in src:
            mounted_remotes.add(src.split(":", 1)[0])
        mounts.append({
            "id": "custom_" + os.path.basename(mp.rstrip("/")),
            "label": os.path.basename(mp.rstrip("/")) or src,
            "source": src,
            "mountpoint": mp,
            "mountpoint_short": _shorten_path(mp, paths["home"]),
            "systemd_unit": "",
            "state": "mounted",
            "line_status": "Mounted (custom)",
            "is_mounted": True,
            "can_start": False,
            "can_stop": False,
            "can_unmount": True,
            "vfs_cache_mode": str(pinfo.get("vfs_cache_mode", "off")),
            "read_only": ro_flag,
        })

    for r in remotes:
        if r["name"] in mounted_remotes:
            r["mounted"] = True

    mounted_count = sum(1 for m in mounts if m["is_mounted"])
    failed_count = sum(1 for m in mounts if m["state"] == "error")

    if failed_count > 0:
        overall_state = "error"
        badge = f"{failed_count} Mount Error"
        summary = f"{failed_count} mount unit(s) failed"
    elif active_jobs:
        overall_state = "syncing"
        badge = f"{len(active_jobs)} Active"
        summary = f"Running {len(active_jobs)} rclone job(s)"
    elif mounted_count > 0:
        overall_state = "mounted"
        badge = f"{mounted_count} Mounted"
        summary = f"{mounted_count} mount(s) active · {len(remotes)} remote(s)"
    elif remotes:
        overall_state = "ready"
        badge = f"{len(remotes)} Remotes"
        summary = f"{len(remotes)} remote(s) configured · 0 mounted"
    else:
        overall_state = "unconfigured"
        badge = "No Remotes"
        summary = "No remotes configured in rclone.conf"

    tooltip: list[dict[str, str]] = [{"key": "Rclone Control", "value": summary}]
    for m in mounts:
        tooltip.append({"key": m["label"], "value": m["line_status"]})
    if remotes and not mounts:
        tooltip.append({"key": "Remotes", "value": ", ".join(r["name"] for r in remotes[:5])})
    if active_jobs:
        tooltip.append({"key": "Active Jobs", "value": ", ".join(j["op"] for j in active_jobs[:3])})
    tooltip.append({"key": "Click", "value": "Left: dropdown · Right: Rclone Control GUI"})

    return {
        "available": True,
        "state": overall_state,
        "badge": badge,
        "summary": summary,
        "remotes": remotes,
        "mounts": mounts,
        "active_jobs": active_jobs,
        "saved_jobs_count": saved_jobs_count,
        "gui_available": gui_available,
        "rclone_conf": str(paths["rclone_conf"]),
        "tooltip": tooltip,
    }


def _mount_action(unit: str, action: str) -> int:
    if action not in ("start", "stop", "restart") or not unit:
        return 1
    res = subprocess.run(
        ["systemctl", "--user", action, unit],
        capture_output=True, text=True, timeout=15.0, check=False,
    )
    print(json.dumps(build_snapshot()))
    return 0 if res.returncode == 0 else res.returncode


def _unmount(path: str, lazy: bool = False) -> int:
    if not path:
        return 1
    wrapper = Path("/run/wrappers/bin/fusermount3")
    fusermount = str(wrapper) if wrapper.is_file() else (shutil.which("fusermount3") or "fusermount3")
    res = subprocess.run(
        [fusermount, "-uz" if lazy else "-u", path],
        capture_output=True, text=True, timeout=10.0, check=False,
    )
    print(json.dumps(build_snapshot()))
    return 0 if res.returncode == 0 else res.returncode


def _open_gui(left: str = "", right: str = "", tab: str = "") -> int:
    bin_path = _find_rclone_control_bin()
    if not bin_path:
        return 1
    cmd = [bin_path]
    if left:
        cmd.extend(["--left", left])
    if right:
        cmd.extend(["--right", right])
    if tab:
        cmd.extend(["--tab", tab])
    subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return 0


def main() -> int:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

    parser = argparse.ArgumentParser(prog="noctalia-rclone-status")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("watch")

    ma = sub.add_parser("mount-action")
    ma.add_argument("--unit", required=True)
    ma.add_argument("--action", required=True, choices=("start", "stop", "restart"))

    um = sub.add_parser("unmount")
    um.add_argument("--path", required=True)
    um.add_argument("--lazy", action="store_true")

    og = sub.add_parser("open-gui")
    og.add_argument("--left", default="")
    og.add_argument("--right", default="")
    og.add_argument("--tab", default="")

    args = parser.parse_args()
    if args.command == "status":
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "mount-action":
        return _mount_action(args.unit, args.action)
    if args.command == "unmount":
        return _unmount(args.path, lazy=args.lazy)
    if args.command == "open-gui":
        return _open_gui(left=args.left, right=args.right, tab=args.tab)

    previous = None
    while True:
        snap = build_snapshot()
        encoded = json.dumps(snap, sort_keys=True)
        if encoded != previous:
            print(encoded, flush=True)
            previous = encoded
        time.sleep(1.5)


if __name__ == "__main__":
    sys.exit(main())
