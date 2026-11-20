#!/usr/bin/env python3
"""Inspect, stream, and trigger sync-projects rsync status for Noctalia Suite."""

from __future__ import annotations

import argparse
from datetime import datetime
import fcntl
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any

TARGETS: tuple[tuple[str, str, str, str], ...] = (
    ("projects", "Projects", "Projects", "Projects"),
    ("scramble-public", "Scramble Public", "Documents/Scramble Public", "Documents/Scramble Public"),
    ("scramble-references", "Scramble References", "Documents/Scramble References", "Documents/Scramble References"),
    (
        "trident-optics-attachment",
        "trident-optics-attachment",
        "Scramble Private/trident-optics-attachment",
        "Scramble Private/trident-optics-attachment",
    ),
)

_DONE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) done \(rsync status (\d+)\)\s*$")
_START_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) start( \(dry run\))?\s*$")
_SKIP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (skipped|refused): (.+)\s*$")
_TARGET_DONE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) target \[([a-z0-9-]+)\]: done \(status (\d+), (\d+)s(, dry run)?\)\s*$"
)
_TARGET_LINE_RE = re.compile(r'^TARGET="([^"]+)"')


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError, TypeError):
        return None


def _process_alive(pid: int | None) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
        state = stat.rsplit(") ", 1)[1][0]
        return state != "Z"
    except (OSError, ValueError, IndexError):
        return False


def _find_live_rsync_pids(target_root: Path) -> list[int]:
    """Return PIDs of running sync-projects or rsync processes targeting target_root."""
    pids: list[int] = []
    uid = os.getuid()
    my_pid = os.getpid()
    marker = str(target_root)
    for proc_dir in Path("/proc").glob("[0-9]*"):
        try:
            pid = int(proc_dir.name)
            if pid == my_pid:
                continue
            if proc_dir.stat().st_uid != uid:
                continue
            raw = (proc_dir / "cmdline").read_bytes()
            if not raw:
                continue
            args = [arg.decode("utf-8", "replace") for arg in raw.split(b"\0") if arg]
            if not args:
                continue
            exe_name = os.path.basename(args[0])
            cmd = " ".join(args)
            if ("rsync" in exe_name and marker in cmd) or (
                "sync-projects" in cmd and "noctalia-rsync-status" not in cmd
            ):
                if _process_alive(pid):
                    pids.append(pid)
        except (OSError, ValueError):
            continue
    return pids


def _is_lock_held(lock_path: Path) -> bool:
    if not lock_path.exists():
        return False
    try:
        fd = os.open(lock_path, os.O_RDONLY)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True
    except OSError:
        return False
    finally:
        os.close(fd)


def _resolve_script_path(script_path: Path | None = None) -> Path:
    if script_path is not None:
        return script_path
    override = os.environ.get("SYNC_PROJECTS_BIN")
    if override:
        return Path(override)
    local_bin = Path.home() / ".local/bin/sync-projects"
    if local_bin.exists():
        return local_bin
    found = shutil.which("sync-projects")
    return Path(found) if found else local_bin


def _resolve_target_root(script_path: Path, target_root: Path | None = None) -> Path:
    if target_root is not None:
        return target_root
    user = os.environ.get("USER") or getpass.getuser()
    default_target = Path(f"/run/media/{user}/nixos/home/{user}")
    if not script_path.is_file():
        return default_target
    try:
        text = script_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return default_target
    for line in text.splitlines():
        match = _TARGET_LINE_RE.match(line.strip())
        if match:
            raw = match.group(1)
            raw = raw.replace("${USER_NAME}", user).replace("${USER:-thinky}", user).replace("${USER}", user)
            if "$" not in raw:
                return Path(raw)
    return default_target


def _parse_timestamp_epoch(timestamp: str) -> int | None:
    if not timestamp:
        return None
    try:
        return int(datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S").timestamp())
    except ValueError:
        return None


def format_short_time(timestamp: str, now_dt: datetime | None = None) -> str:
    """Format 'YYYY-MM-DD HH:MM:SS' compactly relative to today."""
    if not timestamp:
        return ""
    try:
        dt = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return timestamp
    ref = now_dt or datetime.now()
    if dt.date() == ref.date():
        return dt.strftime("%H:%M")
    if dt.year == ref.year:
        return dt.strftime("%b %d %H:%M")
    return dt.strftime("%Y-%m-%d %H:%M")


def parse_log_tail(log_path: Path, max_bytes: int = 262144) -> dict[str, Any]:
    """Read the tail of sync-projects.log for fallback history without loading huge logs."""
    result: dict[str, Any] = {
        "exists": log_path.is_file(),
        "last_attempt": None,
        "last_real_done": None,
        "last_dry_done": None,
        "targets": {},
        "unclosed_start": None,
    }
    if not result["exists"]:
        return result
    try:
        size = log_path.stat().st_size
        with log_path.open("rb") as stream:
            if size > max_bytes:
                stream.seek(size - max_bytes)
            chunk = stream.read().decode("utf-8", errors="replace")
    except OSError:
        return result

    lines = chunk.splitlines()
    if size > max_bytes and lines:
        lines = lines[1:]  # Drop potentially truncated first line.

    pending_dry = False
    open_start: dict[str, Any] | None = None
    for line in lines:
        m_start = _START_RE.match(line)
        if m_start:
            pending_dry = bool(m_start.group(2))
            open_start = {"timestamp": m_start.group(1), "dry_run": pending_dry}
            continue
        m_target = _TARGET_DONE_RE.match(line)
        if m_target:
            ts, tid, rc_str, dur_str, dry_flag = m_target.groups()
            entry = {
                "id": tid,
                "exit_code": int(rc_str),
                "duration_sec": int(dur_str),
                "dry_run": bool(dry_flag),
                "timestamp": ts,
                "epoch": _parse_timestamp_epoch(ts),
            }
            bucket = result["targets"].setdefault(tid, {})
            if entry["dry_run"]:
                bucket["dry"] = entry
            else:
                bucket["sync"] = entry
            continue
        m_done = _DONE_RE.match(line)
        if m_done:
            ts, rc_str = m_done.groups()
            rc = int(rc_str)
            entry = {
                "state": "ok" if rc == 0 else "error",
                "exit_code": rc,
                "dry_run": pending_dry,
                "timestamp": ts,
                "epoch": _parse_timestamp_epoch(ts),
                "reason": "",
            }
            result["last_attempt"] = entry
            if pending_dry:
                result["last_dry_done"] = entry
            else:
                result["last_real_done"] = entry
            pending_dry = False
            open_start = None
            continue
        m_skip = _SKIP_RE.match(line)
        if m_skip:
            ts, kind, reason = m_skip.groups()
            result["last_attempt"] = {
                "state": kind,
                "exit_code": 1 if kind == "refused" else 0,
                "dry_run": False,
                "timestamp": ts,
                "epoch": _parse_timestamp_epoch(ts),
                "reason": reason.strip(),
            }
            pending_dry = False
            open_start = None

    result["unclosed_start"] = open_start
    return result


def _shorten_home(path: Path, home: Path) -> str:
    try:
        rel = path.relative_to(home)
        return "~" if str(rel) == "." else f"~/{rel}"
    except ValueError:
        return str(path)


def _check_mount(home: Path, target_root: Path) -> tuple[bool, bool]:
    """Return (disk_mounted, same_disk) safely."""
    target_projects = target_root / "Projects"
    if not target_projects.is_dir():
        return False, False
    try:
        home_dev = home.stat().st_dev
        target_dev = target_root.stat().st_dev
        if home_dev == target_dev:
            return False, True
    except OSError:
        return False, False
    return True, False


def build_snapshot(
    home: Path | None = None,
    state_dir: Path | None = None,
    cache_dir: Path | None = None,
    runtime_dir: Path | None = None,
    script_path: Path | None = None,
    target_root: Path | None = None,
    now_dt: datetime | None = None,
    live_pids: list[int] | None = None,
) -> dict[str, Any]:
    """Build a complete JSON-serializable rsync status snapshot."""
    home_dir = home or Path.home()
    xdg_state = Path(os.environ.get("XDG_STATE_HOME") or (home_dir / ".local/state"))
    xdg_cache = Path(os.environ.get("XDG_CACHE_HOME") or (home_dir / ".cache"))
    xdg_runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")

    resolved_state = state_dir or (xdg_state / "sync-projects")
    resolved_cache = cache_dir or xdg_cache
    resolved_runtime = runtime_dir or xdg_runtime
    resolved_script = _resolve_script_path(script_path)
    resolved_target = _resolve_target_root(resolved_script, target_root)

    log_path = resolved_cache / "sync-projects.log"
    lock_path = resolved_runtime / "sync-projects.lock"
    targets_state_dir = resolved_state / "targets"
    run_data = _read_json(resolved_state / "run.json")
    log_info = parse_log_tail(log_path)

    script_exists = resolved_script.is_file() and os.access(resolved_script, os.X_OK)
    disk_mounted, same_disk = _check_mount(home_dir, resolved_target)
    lock_held = _is_lock_held(lock_path)
    detected_pids = live_pids if live_pids is not None else _find_live_rsync_pids(resolved_target)

    # Check if run.json claims a sync is running with a live PID.
    run_active = False
    if run_data and run_data.get("state") == "syncing":
        run_active = _process_alive(run_data.get("pid")) or lock_held or bool(detected_pids)

    globally_syncing = run_active or lock_held or bool(detected_pids)
    now_epoch = int((now_dt or datetime.now()).timestamp())

    # Choose the newest run record between run.json and log fallback.
    last_attempt: dict[str, Any] | None = run_data
    log_attempt = log_info.get("last_attempt")
    if log_attempt and (
        not last_attempt
        or int(log_attempt.get("epoch") or 0) > int(last_attempt.get("epoch") or 0)
    ):
        last_attempt = log_attempt

    target_rows: list[dict[str, Any]] = []
    active_target_name = ""
    any_error = False
    any_present = False
    all_present_ok = True
    seen_active = False

    for tid, name, rel_src, rel_dst in TARGETS:
        src_path = home_dir / rel_src
        dst_path = resolved_target / rel_dst
        source_exists = src_path.is_dir()

        active_data = _read_json(targets_state_dir / f"{tid}.active.json")
        if active_data and not _process_alive(active_data.get("pid")) and not lock_held:
            active_data = None

        sync_data = _read_json(targets_state_dir / f"{tid}.sync.json")
        dry_data = _read_json(targets_state_dir / f"{tid}.dry.json")

        # Merge log fallback per-target or whole-run result when no state file exists yet.
        log_target = log_info.get("targets", {}).get(tid, {})
        if not sync_data and log_target.get("sync"):
            sync_data = log_target["sync"]
        if source_exists and log_info.get("last_real_done"):
            fallback_done = log_info["last_real_done"]
            sync_epoch = int((sync_data or {}).get("epoch") or 0)
            fb_epoch = int(fallback_done.get("epoch") or 0)
            if sync_data is None or fb_epoch > sync_epoch:
                sync_data = {
                    "id": tid,
                    "name": name,
                    "exit_code": fallback_done["exit_code"],
                    "dry_run": False,
                    "timestamp": fallback_done["timestamp"],
                    "epoch": fallback_done["epoch"],
                    "duration_sec": None,
                    "from_log_batch": True,
                }
        if not dry_data and log_target.get("dry"):
            dry_data = log_target["dry"]

        run_epoch = int((run_data or {}).get("epoch") or 0)
        run_is_dry = bool((run_data or {}).get("dry_run"))
        done_this_run = False
        if globally_syncing and run_active and run_epoch > 0:
            check_rec = dry_data if run_is_dry else sync_data
            if check_rec and int(check_rec.get("epoch") or 0) >= run_epoch:
                done_this_run = True

        t_state = "never"
        line_status = "Not yet run"
        exit_code: int | None = None
        last_sync_at = sync_data.get("timestamp", "") if sync_data else ""
        last_dry_at = dry_data.get("timestamp", "") if dry_data else ""
        duration_sec = sync_data.get("duration_sec") if sync_data else None
        short_time = format_short_time(last_sync_at, now_dt=now_dt)

        if active_data is not None:
            seen_active = True
            active_target_name = name
            t_state = "syncing"
            started_epoch = active_data.get("started_epoch")
            elapsed = max(0, now_epoch - int(started_epoch)) if isinstance(started_epoch, (int, float)) else None
            prefix = "Dry run" if active_data.get("dry_run") else "Syncing"
            line_status = f"{prefix}... ({elapsed}s)" if elapsed is not None else f"{prefix}..."
        elif not source_exists:
            t_state = "absent"
            line_status = "No local folder"
        else:
            any_present = True
            if globally_syncing and not done_this_run:
                if detected_pids and tid == "projects" and not seen_active:
                    active_target_name = name
                    t_state = "syncing"
                    line_status = "Syncing..."
                    seen_active = True
                else:
                    t_state = "queued"
                    line_status = "Queued"
                all_present_ok = False
            elif sync_data is not None:
                exit_code = int(sync_data.get("exit_code", 0))
                if exit_code == 0:
                    t_state = "ok"
                    line_status = f"OK (0) · {short_time}" if short_time else "OK (0)"
                else:
                    t_state = "error"
                    any_error = True
                    all_present_ok = False
                    line_status = f"Error ({exit_code}) · {short_time}" if short_time else f"Error ({exit_code})"
            elif dry_data is not None:
                dry_rc = int(dry_data.get("exit_code", 0))
                dry_time = format_short_time(last_dry_at, now_dt=now_dt)
                if dry_rc == 0:
                    t_state = "ready" if disk_mounted else "skipped"
                    line_status = f"Dry run (0) · {dry_time}" if dry_time else "Dry run (0)"
                else:
                    t_state = "error"
                    any_error = True
                    line_status = f"Dry error ({dry_rc}) · {dry_time}" if dry_time else f"Dry error ({dry_rc})"
                all_present_ok = False
            elif last_attempt and last_attempt.get("state") == "skipped":
                t_state = "skipped"
                skip_time = format_short_time(last_attempt.get("timestamp", ""), now_dt=now_dt)
                line_status = f"Skipped · {skip_time}" if skip_time else "Skipped (unmounted)"
                all_present_ok = False
            elif not disk_mounted:
                t_state = "skipped"
                line_status = "Disk unmounted"
                all_present_ok = False
            else:
                t_state = "never"
                line_status = "Not yet run"
                all_present_ok = False

        tip_lines = [
            f"{_shorten_home(src_path, home_dir)} → {dst_path}",
            f"Status: {line_status}",
        ]
        if last_sync_at:
            dur_note = f" ({duration_sec}s)" if duration_sec is not None else ""
            tip_lines.append(f"Last sync: {last_sync_at} · exit {sync_data.get('exit_code', 0)}{dur_note}")
        if last_dry_at and last_dry_at != last_sync_at:
            tip_lines.append(f"Last dry run: {last_dry_at} · exit {dry_data.get('exit_code', 0)}")
        if not source_exists:
            tip_lines.append("Optional folder is absent on this machine.")

        target_rows.append({
            "id": tid,
            "name": name,
            "source": str(src_path),
            "source_short": _shorten_home(src_path, home_dir),
            "dest": str(dst_path),
            "source_exists": source_exists,
            "state": t_state,
            "line_status": line_status,
            "exit_code": exit_code,
            "last_sync_at": last_sync_at,
            "last_dry_at": last_dry_at,
            "duration_sec": duration_sec,
            "tooltip": "\n".join(tip_lines),
        })

    # Determine overall bar icon state.
    if not script_exists and not log_info["exists"] and run_data is None:
        overall_state = "unconfigured"
        badge = "Not configured"
        summary = "sync-projects is not installed on this host"
    elif globally_syncing:
        overall_state = "syncing"
        badge = "Syncing"
        summary = f"Syncing {active_target_name}..." if active_target_name else "Rsync running..."
    elif same_disk or (last_attempt and last_attempt.get("state") == "refused" and not disk_mounted) or any_error:
        overall_state = "error"
        badge = "Error"
        if same_disk:
            summary = "Refused: target resolves to this disk"
        else:
            failed = [t["name"] for t in target_rows if t["state"] == "error"]
            summary = f"Failed: {', '.join(failed)}" if failed else "Last rsync failed"
    elif not disk_mounted:
        overall_state = "unmounted"
        badge = "Unmounted"
        summary = f"Backup disk not mounted ({resolved_target})"
    elif any_present and all_present_ok:
        overall_state = "ok"
        badge = "Synced"
        summary = "All targets synced"
    else:
        overall_state = "ready"
        badge = "Ready"
        summary = "Backup disk mounted (pending sync)"

    last_run_text = ""
    if last_attempt and last_attempt.get("timestamp"):
        attempt_state = last_attempt.get("state", "")
        ts_str = format_short_time(last_attempt["timestamp"], now_dt=now_dt)
        if attempt_state == "skipped":
            last_run_text = f"Last attempt: {ts_str} · skipped (disk unmounted)"
        elif attempt_state == "refused":
            last_run_text = f"Last attempt: {ts_str} · refused (same disk)"
        elif attempt_state == "syncing":
            last_run_text = f"Started: {ts_str}"
        else:
            rc = last_attempt.get("exit_code", 0)
            dry_tag = " · dry run" if last_attempt.get("dry_run") else ""
            last_run_text = f"Last run: {ts_str} · exit {rc}{dry_tag}"

    tooltip = [{"key": "Rsync Backup", "value": summary}]
    for row in target_rows:
        tooltip.append({"key": row["name"], "value": row["line_status"]})
    if last_run_text:
        tooltip.append({"key": "History", "value": last_run_text})
    tooltip.append({"key": "Action", "value": "Click to open status panel"})

    return {
        "available": True,
        "state": overall_state,
        "badge": badge,
        "summary": summary,
        "script_exists": script_exists,
        "script_path": str(resolved_script),
        "disk_mounted": disk_mounted,
        "same_disk": same_disk,
        "syncing": globally_syncing,
        "can_sync": script_exists and disk_mounted and not globally_syncing,
        "target_root": str(resolved_target),
        "log_path": str(log_path),
        "log_exists": log_path.is_file(),
        "last_run_text": last_run_text,
        "targets": target_rows,
        "tooltip": tooltip,
    }


def _trigger_sync(dry_run: bool = False) -> int:
    script = _resolve_script_path()
    if not (script.is_file() and os.access(script, os.X_OK)):
        print(json.dumps({"ok": False, "error": f"sync-projects not found at {script}"}))
        return 1
    cmd = [str(script)] + (["--dry-run"] if dry_run else [])
    subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    print(json.dumps({"ok": True, "started": True, "dry_run": dry_run}))
    return 0


def _open_log() -> int:
    xdg_cache = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    log_path = xdg_cache / "sync-projects.log"
    if not log_path.is_file():
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.touch()

    candidates: list[list[str]] = []
    term_env = os.environ.get("TERMINAL")
    if term_env and shutil.which(term_env):
        candidates.append([term_env, "-e", "less", "+G", str(log_path)])
    for kitty_bin in (shutil.which("kitty"), "/etc/profiles/per-user/thinky/bin/kitty", "/run/current-system/sw/bin/kitty"):
        if kitty_bin and os.path.isfile(kitty_bin) and os.access(kitty_bin, os.X_OK):
            candidates.append([kitty_bin, "--title", "sync-projects.log", "-e", "less", "+G", str(log_path)])
            break
    foot_bin = shutil.which("foot")
    if foot_bin:
        candidates.append([foot_bin, "--title=sync-projects.log", "less", "+G", str(log_path)])
    xdg_open = shutil.which("xdg-open")
    if xdg_open:
        candidates.append([xdg_open, str(log_path)])

    for cmd in candidates:
        try:
            subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return 0
        except OSError:
            continue
    print(f"No terminal or opener available for {log_path}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("watch")
    trigger_parser = commands.add_parser("trigger")
    trigger_parser.add_argument("--dry-run", action="store_true")
    commands.add_parser("open-log")
    args = parser.parse_args()

    if args.command == "status":
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "trigger":
        return _trigger_sync(dry_run=args.dry_run)
    if args.command == "open-log":
        return _open_log()

    previous = None
    while True:
        snapshot = build_snapshot()
        encoded = json.dumps(snapshot, sort_keys=True)
        if encoded != previous:
            print(encoded, flush=True)
            previous = encoded
        time.sleep(0.5 if snapshot.get("syncing") else 1.5)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
