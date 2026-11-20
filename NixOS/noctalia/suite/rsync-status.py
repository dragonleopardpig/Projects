#!/usr/bin/env python3
"""Inspect, configure, run, stream, and control rsync targets for Noctalia Suite."""

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
import tempfile
import time
from typing import Any

DEFAULT_EXCLUDES: list[str] = [
    ".devenv/",
    ".direnv/",
    "node_modules/",
    ".venv/",
    "__pycache__/",
    ".pytest_cache/",
    ".ruff_cache/",
    ".mypy_cache/",
    "/*/target/",
    ".filen.trash.local/",
    "cad_cache/",
    "/Kraken-Optical-Simulator/attachment/References/",
]

_DONE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) done \(rsync status (\d+)\)\s*$")
_START_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) start( \(dry run\))?\s*$")
_SKIP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (skipped|refused): (.+)\s*$")
_TARGET_DONE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) target \[([a-z0-9_-]+)\]: done \(status (\d+), (\d+)s(, dry run)?\)\s*$"
)
_TARGET_LINE_RE = re.compile(r'^TARGET="([^"]+)"')


def _default_target_root(home: Path, script_path: Path | None = None) -> str:
    user = os.environ.get("USER") or getpass.getuser()
    default_target = f"/run/media/{user}/nixos/home/{user}"
    if script_path and script_path.is_file():
        try:
            for line in script_path.read_text(encoding="utf-8", errors="replace").splitlines():
                m = _TARGET_LINE_RE.match(line.strip())
                if m:
                    raw = (
                        m.group(1)
                        .replace("${USER_NAME}", user)
                        .replace("${USER:-thinky}", user)
                        .replace("${USER}", user)
                    )
                    if "$" not in raw:
                        return raw
        except OSError:
            pass
    return default_target


def default_targets(home: Path) -> list[dict[str, Any]]:
    """Return the built-in sync-projects targets."""
    return [
        {
            "id": "projects",
            "name": "Projects",
            "source": str(home / "Projects"),
            "dest": "Projects",
            "enabled": True,
            "delete": True,
            "excludes": [],
        },
        {
            "id": "scramble-public",
            "name": "Scramble Public",
            "source": str(home / "Documents/Scramble Public"),
            "dest": "Documents/Scramble Public",
            "enabled": True,
            "delete": True,
            "excludes": [],
        },
        {
            "id": "scramble-references",
            "name": "Scramble References",
            "source": str(home / "Documents/Scramble References"),
            "dest": "Documents/Scramble References",
            "enabled": True,
            "delete": True,
            "excludes": [],
        },
        {
            "id": "trident-optics-attachment",
            "name": "trident-optics-attachment",
            "source": str(home / "Scramble Private/trident-optics-attachment"),
            "dest": "Scramble Private/trident-optics-attachment",
            "enabled": True,
            "delete": True,
            "excludes": [],
        },
    ]


def default_config(home: Path, script_path: Path | None = None) -> dict[str, Any]:
    return {
        "version": 1,
        "target_root": _default_target_root(home, script_path),
        "excludes": list(DEFAULT_EXCLUDES),
        "targets": default_targets(home),
    }


def _slugify(value: str, fallback: str = "target") -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "-", value.lower()).strip("-")
    return slug or fallback


def _atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            tmp = Path(stream.name)
            json.dump(data, stream, indent=2)
            stream.write("\n")
        tmp.replace(path)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError, TypeError):
        return None


def _normalize_config(raw: dict[str, Any], home: Path, script_path: Path | None = None) -> dict[str, Any]:
    base = default_config(home, script_path)
    target_root = str(raw.get("target_root") or base["target_root"]).strip()
    excludes_raw = raw.get("excludes")
    excludes = [str(x).strip() for x in excludes_raw if str(x).strip()] if isinstance(excludes_raw, list) else base["excludes"]

    targets: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    raw_targets = raw.get("targets")
    if isinstance(raw_targets, list):
        for item in raw_targets:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "").strip()
            source = str(item.get("source") or "").strip()
            dest = str(item.get("dest") or "").strip()
            if not name and source:
                name = Path(source).name or source
            if not name or not source or not dest:
                continue
            tid = _slugify(str(item.get("id") or name))
            while tid in seen_ids:
                tid = f"{tid}-2"
            seen_ids.add(tid)
            item_excludes_raw = item.get("excludes")
            item_excludes = (
                [str(x).strip() for x in item_excludes_raw if str(x).strip()]
                if isinstance(item_excludes_raw, list)
                else []
            )
            targets.append({
                "id": tid,
                "name": name,
                "source": source,
                "dest": dest,
                "enabled": bool(item.get("enabled", True)),
                "delete": bool(item.get("delete", True)),
                "excludes": item_excludes,
            })
    return {
        "version": 1,
        "target_root": target_root,
        "excludes": excludes,
        "targets": targets,
    }


def _resolve_paths(
    home: Path | None = None,
    config_dir: Path | None = None,
    state_dir: Path | None = None,
    cache_dir: Path | None = None,
    runtime_dir: Path | None = None,
    script_path: Path | None = None,
) -> dict[str, Path]:
    home_dir = home or Path.home()
    xdg_config = Path(os.environ.get("XDG_CONFIG_HOME") or (home_dir / ".config"))
    xdg_state = Path(os.environ.get("XDG_STATE_HOME") or (home_dir / ".local/state"))
    xdg_cache = Path(os.environ.get("XDG_CACHE_HOME") or (home_dir / ".cache"))
    xdg_runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")

    resolved_config = config_dir or (xdg_config / "sync-projects")
    resolved_state = state_dir or (xdg_state / "sync-projects")
    resolved_cache = cache_dir or xdg_cache
    resolved_runtime = runtime_dir or xdg_runtime
    if script_path is not None:
        resolved_script = script_path
    else:
        override = os.environ.get("SYNC_PROJECTS_BIN")
        local_bin = home_dir / ".local/bin/sync-projects"
        found = shutil.which("sync-projects")
        resolved_script = Path(override) if override else (local_bin if local_bin.exists() else (Path(found) if found else local_bin))

    return {
        "home": home_dir,
        "config_file": resolved_config / "config.json",
        "state_dir": resolved_state,
        "targets_dir": resolved_state / "targets",
        "run_file": resolved_state / "run.json",
        "log_file": resolved_cache / "sync-projects.log",
        "lock_file": resolved_runtime / "sync-projects.lock",
        "script_path": resolved_script,
    }


def load_or_seed_config(paths: dict[str, Path], seed_if_missing: bool = True) -> dict[str, Any]:
    cfg_file = paths["config_file"]
    existing = _read_json(cfg_file)
    if existing is not None:
        return _normalize_config(existing, paths["home"], paths["script_path"])
    has_legacy = (
        paths["script_path"].is_file()
        or paths["log_file"].is_file()
        or paths["run_file"].is_file()
    )
    cfg = default_config(paths["home"], paths["script_path"])
    if not has_legacy:
        cfg["targets"] = []
    if seed_if_missing and has_legacy:
        try:
            _atomic_write_json(cfg_file, cfg)
        except OSError:
            pass
    return cfg


def _expand_user_path(raw: str, home: Path) -> Path:
    if raw == "~":
        return home
    if raw.startswith("~/"):
        return home / raw[2:]
    return Path(raw)


def _is_remote_spec(dest: str) -> bool:
    if dest.startswith(("rsync://", "/")):
        return False
    first_colon = dest.find(":")
    first_slash = dest.find("/")
    return first_colon > 0 and (first_slash == -1 or first_colon < first_slash)


def _resolve_dest(dest: str, target_root: Path, home: Path) -> tuple[str, bool, Path | None]:
    """Return (dest_arg, uses_target_root, local_dest_path)."""
    if _is_remote_spec(dest):
        return dest, False, None
    if dest.startswith("/") or dest.startswith("~/") or dest == "~":
        p = _expand_user_path(dest, home)
        try:
            under_root = p == target_root or target_root in p.parents
        except ValueError:
            under_root = False
        return str(p), under_root, p
    p = target_root / dest
    return str(p), True, p


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
    pids: list[int] = []
    uid = os.getuid()
    my_pid = os.getpid()
    marker = str(target_root)
    for proc_dir in Path("/proc").glob("[0-9]*"):
        try:
            pid = int(proc_dir.name)
            if pid == my_pid or proc_dir.stat().st_uid != uid:
                continue
            raw = (proc_dir / "cmdline").read_bytes()
            if not raw:
                continue
            args = [arg.decode("utf-8", "replace") for arg in raw.split(b"\0") if arg]
            if not args:
                continue
            exe_name = os.path.basename(args[0])
            cmd = " ".join(args)
            is_rsync = "rsync" in exe_name and (marker in cmd or "--delete" in cmd or "sync-projects" in cmd)
            is_wrapper = ("sync-projects" in cmd or "noctalia-rsync-status run" in cmd) and "watch" not in cmd
            if (is_rsync or is_wrapper) and _process_alive(pid):
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


def _parse_timestamp_epoch(timestamp: str) -> int | None:
    if not timestamp:
        return None
    try:
        return int(datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S").timestamp())
    except ValueError:
        return None


def format_short_time(timestamp: str, now_dt: datetime | None = None) -> str:
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
    result: dict[str, Any] = {
        "exists": log_path.is_file(),
        "last_attempt": None,
        "last_real_done": None,
        "last_dry_done": None,
        "targets": {},
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
        lines = lines[1:]

    pending_dry = False
    for line in lines:
        m_start = _START_RE.match(line)
        if m_start:
            pending_dry = bool(m_start.group(2))
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
            bucket["dry" if entry["dry_run"] else "sync"] = entry
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
            result["last_dry_done" if pending_dry else "last_real_done"] = entry
            pending_dry = False
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
    return result


def _shorten_home(path: Path, home: Path) -> str:
    try:
        rel = path.relative_to(home)
        return "~" if str(rel) == "." else f"~/{rel}"
    except ValueError:
        return str(path)


def _check_mount(home: Path, target_root: Path) -> tuple[bool, bool]:
    """Return (disk_mounted, same_disk) safely."""
    if not target_root.exists():
        return False, False
    # For the default /run/media/<user>/nixos/home/<user> target, require Projects or a separate mounted volume.
    if not target_root.is_dir():
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
    config_dir: Path | None = None,
    state_dir: Path | None = None,
    cache_dir: Path | None = None,
    runtime_dir: Path | None = None,
    script_path: Path | None = None,
    target_root: Path | None = None,
    now_dt: datetime | None = None,
    live_pids: list[int] | None = None,
) -> dict[str, Any]:
    paths = _resolve_paths(
        home=home,
        config_dir=config_dir,
        state_dir=state_dir,
        cache_dir=cache_dir,
        runtime_dir=runtime_dir,
        script_path=script_path,
    )
    home_dir = paths["home"]
    cfg = load_or_seed_config(paths, seed_if_missing=True)
    resolved_target = target_root or _expand_user_path(cfg["target_root"], home_dir)

    log_path = paths["log_file"]
    lock_path = paths["lock_file"]
    targets_state_dir = paths["targets_dir"]
    run_data = _read_json(paths["run_file"])
    log_info = parse_log_tail(log_path)

    disk_mounted, same_disk = _check_mount(home_dir, resolved_target)
    lock_held = _is_lock_held(lock_path)
    detected_pids = live_pids if live_pids is not None else _find_live_rsync_pids(resolved_target)

    run_active = False
    if run_data and run_data.get("state") == "syncing":
        run_active = _process_alive(run_data.get("pid")) or lock_held or bool(detected_pids)
    globally_syncing = run_active or lock_held or bool(detected_pids)
    now_epoch = int((now_dt or datetime.now()).timestamp())

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
    any_enabled_present = False
    all_enabled_ok = True
    any_can_run_now = False
    seen_active = False

    run_epoch = int((run_data or {}).get("epoch") or 0)
    run_is_dry = bool((run_data or {}).get("dry_run"))

    for t in cfg["targets"]:
        tid = t["id"]
        name = t["name"]
        src_path = _expand_user_path(t["source"], home_dir)
        dest_arg, uses_root, local_dst = _resolve_dest(t["dest"], resolved_target, home_dir)
        source_exists = src_path.is_dir()
        enabled = bool(t.get("enabled", True))
        delete_flag = bool(t.get("delete", True))

        active_data = _read_json(targets_state_dir / f"{tid}.active.json")
        if active_data and not _process_alive(active_data.get("pid")) and not lock_held:
            active_data = None

        sync_data = _read_json(targets_state_dir / f"{tid}.sync.json")
        dry_data = _read_json(targets_state_dir / f"{tid}.dry.json")

        log_target = log_info.get("targets", {}).get(tid, {})
        if not sync_data and log_target.get("sync"):
            sync_data = log_target["sync"]
        if source_exists and log_info.get("last_real_done") and tid in {"projects", "scramble-public", "scramble-references", "trident-optics-attachment"}:
            fb = log_info["last_real_done"]
            if sync_data is None or int(fb.get("epoch") or 0) > int(sync_data.get("epoch") or 0):
                sync_data = {
                    "id": tid,
                    "name": name,
                    "exit_code": fb["exit_code"],
                    "dry_run": False,
                    "timestamp": fb["timestamp"],
                    "epoch": fb["epoch"],
                    "duration_sec": None,
                    "from_log_batch": True,
                }
        if not dry_data and log_target.get("dry"):
            dry_data = log_target["dry"]

        done_this_run = False
        if globally_syncing and run_active and run_epoch > 0:
            check_rec = dry_data if run_is_dry else sync_data
            if check_rec and int(check_rec.get("epoch") or 0) >= run_epoch:
                done_this_run = True

        # Determine if this individual target can run right now.
        if not source_exists:
            target_can_run = False
        elif _is_remote_spec(t["dest"]):
            target_can_run = not globally_syncing
        elif uses_root:
            target_can_run = disk_mounted and not globally_syncing
        else:
            # Custom local path: require parent exists and not same device as source.
            target_can_run = local_dst is not None and (local_dst.exists() or local_dst.parent.exists()) and not globally_syncing
            if target_can_run and local_dst is not None and local_dst.exists():
                try:
                    if src_path.stat().st_dev == local_dst.stat().st_dev and src_path.resolve() == local_dst.resolve():
                        target_can_run = False
                except OSError:
                    target_can_run = False

        if enabled and target_can_run:
            any_can_run_now = True

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
        elif not enabled:
            t_state = "disabled"
            line_status = "Disabled"
        elif not source_exists:
            t_state = "absent"
            line_status = "No local folder"
        else:
            any_enabled_present = True
            if globally_syncing and not done_this_run:
                if detected_pids and tid == cfg["targets"][0]["id"] and not seen_active:
                    active_target_name = name
                    t_state = "syncing"
                    line_status = "Syncing..."
                    seen_active = True
                else:
                    t_state = "queued"
                    line_status = "Queued"
                all_enabled_ok = False
            elif sync_data is not None:
                exit_code = int(sync_data.get("exit_code", 0))
                if exit_code == 0:
                    t_state = "ok"
                    line_status = f"OK (0) · {short_time}" if short_time else "OK (0)"
                else:
                    t_state = "error"
                    any_error = True
                    all_enabled_ok = False
                    line_status = f"Error ({exit_code}) · {short_time}" if short_time else f"Error ({exit_code})"
            elif dry_data is not None:
                dry_rc = int(dry_data.get("exit_code", 0))
                dry_time = format_short_time(last_dry_at, now_dt=now_dt)
                if dry_rc == 0:
                    t_state = "ready" if target_can_run else "skipped"
                    line_status = f"Dry run (0) · {dry_time}" if dry_time else "Dry run (0)"
                else:
                    t_state = "error"
                    any_error = True
                    line_status = f"Dry error ({dry_rc}) · {dry_time}" if dry_time else f"Dry error ({dry_rc})"
                all_enabled_ok = False
            elif uses_root and not disk_mounted:
                t_state = "skipped"
                if last_attempt and last_attempt.get("state") == "skipped":
                    skip_time = format_short_time(last_attempt.get("timestamp", ""), now_dt=now_dt)
                    line_status = f"Skipped · {skip_time}" if skip_time else "Disk unmounted"
                else:
                    line_status = "Disk unmounted"
                all_enabled_ok = False
            else:
                t_state = "never"
                line_status = "Not yet run"
                all_enabled_ok = False

        tip_lines = [
            f"{_shorten_home(src_path, home_dir)} → {dest_arg}",
            f"Status: {line_status} · Mirror(--delete): {'On' if delete_flag else 'Off'}",
        ]
        if last_sync_at:
            dur_note = f" ({duration_sec}s)" if duration_sec is not None else ""
            tip_lines.append(f"Last sync: {last_sync_at} · exit {sync_data.get('exit_code', 0)}{dur_note}")
        if last_dry_at and last_dry_at != last_sync_at:
            tip_lines.append(f"Last dry run: {last_dry_at} · exit {dry_data.get('exit_code', 0)}")
        if not source_exists:
            tip_lines.append("Source directory does not exist locally.")

        target_rows.append({
            "id": tid,
            "name": name,
            "source": t["source"],
            "source_short": _shorten_home(src_path, home_dir),
            "dest": t["dest"],
            "dest_resolved": dest_arg,
            "uses_root": uses_root,
            "enabled": enabled,
            "delete": delete_flag,
            "excludes": t.get("excludes", []),
            "source_exists": source_exists,
            "can_run": target_can_run,
            "state": t_state,
            "line_status": line_status,
            "exit_code": exit_code,
            "last_sync_at": last_sync_at,
            "last_dry_at": last_dry_at,
            "duration_sec": duration_sec,
            "tooltip": "\n".join(tip_lines),
        })

    if not cfg["targets"]:
        overall_state = "unconfigured"
        badge = "No targets"
        summary = "Add rsync folder pairs inside the dropdown"
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
            failed = [row["name"] for row in target_rows if row["state"] == "error"]
            summary = f"Failed: {', '.join(failed)}" if failed else "Last rsync failed"
    elif not disk_mounted and all(row["uses_root"] for row in target_rows if row["enabled"] and row["source_exists"]):
        overall_state = "unmounted"
        badge = "Unmounted"
        summary = f"Backup disk not mounted ({resolved_target})"
    elif any_enabled_present and all_enabled_ok:
        overall_state = "ok"
        badge = "Synced"
        summary = "All enabled targets synced"
    else:
        overall_state = "ready"
        badge = "Ready"
        summary = "Ready to sync"

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
    tooltip.append({"key": "Action", "value": "Click to view / configure rsync"})

    return {
        "available": True,
        "state": overall_state,
        "badge": badge,
        "summary": summary,
        "configured": bool(cfg["targets"]),
        "disk_mounted": disk_mounted,
        "same_disk": same_disk,
        "syncing": globally_syncing,
        "can_sync": any_can_run_now,
        "target_root": str(resolved_target),
        "target_root_raw": cfg["target_root"],
        "excludes": cfg["excludes"],
        "config_path": str(paths["config_file"]),
        "log_path": str(log_path),
        "log_exists": log_path.is_file(),
        "last_run_text": last_run_text,
        "targets": target_rows,
        "tooltip": tooltip,
    }


def _append_log(log_file: Path, msg: str) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with log_file.open("a", encoding="utf-8") as stream:
        stream.write(f"{ts} {msg}\n")


def run_sync(
    dry_run: bool = False,
    target_id: str | None = None,
    home: Path | None = None,
    config_dir: Path | None = None,
    state_dir: Path | None = None,
    cache_dir: Path | None = None,
    runtime_dir: Path | None = None,
    script_path: Path | None = None,
    same_disk_guard: bool = True,
) -> int:
    """Execute rsync for all enabled targets (or a specific target_id)."""
    paths = _resolve_paths(home, config_dir, state_dir, cache_dir, runtime_dir, script_path)
    home_dir = paths["home"]
    cfg = load_or_seed_config(paths, seed_if_missing=True)
    target_root = _expand_user_path(cfg["target_root"], home_dir)

    selected = [t for t in cfg["targets"] if (t["id"] == target_id if target_id else t.get("enabled", True))]
    if target_id and not selected:
        _append_log(paths["log_file"], f"skipped: unknown target '{target_id}'")
        return 1
    if not selected:
        _append_log(paths["log_file"], "skipped: no enabled rsync targets")
        return 0

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    now_epoch = int(time.time())

    # Check target_root mount if any selected target uses target_root.
    uses_any_root = any(_resolve_dest(t["dest"], target_root, home_dir)[1] for t in selected)
    if uses_any_root:
        if not target_root.exists() or not target_root.is_dir():
            _atomic_write_json(paths["run_file"], {
                "state": "skipped", "reason": "disk_unmounted", "exit_code": 0,
                "dry_run": dry_run, "pid": os.getpid(), "target": str(target_root),
                "timestamp": now_str, "epoch": now_epoch,
            })
            _append_log(paths["log_file"], f"skipped: the other disk is not mounted at {target_root}")
            return 0
        if same_disk_guard:
            try:
                if home_dir.stat().st_dev == target_root.stat().st_dev:
                    _atomic_write_json(paths["run_file"], {
                        "state": "refused", "reason": "same_disk", "exit_code": 1,
                        "dry_run": dry_run, "pid": os.getpid(), "target": str(target_root),
                        "timestamp": now_str, "epoch": now_epoch,
                    })
                    _append_log(paths["log_file"], f"refused: {target_root} is on this disk")
                    return 1
            except OSError:
                pass

    paths["lock_file"].parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(paths["lock_file"], os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        run_started_epoch = int(time.time())
        run_started_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        _atomic_write_json(paths["run_file"], {
            "state": "syncing", "reason": "", "exit_code": 0, "dry_run": dry_run,
            "pid": os.getpid(), "target": str(target_root),
            "timestamp": run_started_str, "epoch": run_started_epoch,
        })
        _append_log(paths["log_file"], "start (dry run)" if dry_run else "start")

        overall_rc = 0
        for t in selected:
            tid = t["id"]
            name = t["name"]
            src = _expand_user_path(t["source"], home_dir)
            dest_arg, uses_root, local_dst = _resolve_dest(t["dest"], target_root, home_dir)
            if not src.is_dir():
                _append_log(paths["log_file"], f"target [{tid}]: skipped (source missing)")
                continue

            if local_dst is not None:
                if same_disk_guard and local_dst.exists():
                    try:
                        if src.resolve() == local_dst.resolve() or (not uses_root and src.stat().st_dev == local_dst.stat().st_dev):
                            _append_log(paths["log_file"], f"target [{tid}]: refused (same disk/path)")
                            if overall_rc == 0:
                                overall_rc = 1
                            continue
                    except OSError:
                        pass
                if not dry_run:
                    local_dst.mkdir(parents=True, exist_ok=True)
                elif not local_dst.exists() and not local_dst.parent.exists():
                    ts_skip = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    _append_log(paths["log_file"], f"(dry run) would make {local_dst} and copy all of it there")
                    _atomic_write_json(paths["targets_dir"] / f"{tid}.dry.json", {
                        "id": tid, "name": name, "exit_code": 0, "dry_run": True,
                        "timestamp": ts_skip, "epoch": int(time.time()), "duration_sec": 0,
                        "note": "destination missing",
                    })
                    continue

            active_file = paths["targets_dir"] / f"{tid}.active.json"
            t0 = int(time.time())
            _atomic_write_json(active_file, {
                "id": tid, "name": name, "pid": os.getpid(), "dry_run": dry_run,
                "started_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "started_epoch": t0,
            })

            cmd = ["rsync", "-a"]
            if t.get("delete", True):
                cmd.append("--delete")
            if dry_run:
                cmd.extend(["--dry-run", "--itemize-changes"])
            for pattern in [*cfg["excludes"], *t.get("excludes", [])]:
                if pattern:
                    cmd.append(f"--exclude={pattern}")
            cmd.extend([f"{src}/", f"{dest_arg}/" if not dest_arg.endswith("/") else dest_arg])

            rc = 0
            try:
                paths["log_file"].parent.mkdir(parents=True, exist_ok=True)
                with paths["log_file"].open("a", encoding="utf-8") as log_stream:
                    proc = subprocess.run(cmd, stdout=log_stream, stderr=subprocess.STDOUT, check=False)
                    rc = proc.returncode
            finally:
                active_file.unlink(missing_ok=True)

            t1 = int(time.time())
            dur = max(0, t1 - t0)
            ts_done = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            rec = {
                "id": tid, "name": name, "exit_code": rc, "dry_run": dry_run,
                "timestamp": ts_done, "epoch": t1, "duration_sec": dur,
            }
            out_file = paths["targets_dir"] / (f"{tid}.dry.json" if dry_run else f"{tid}.sync.json")
            _atomic_write_json(out_file, rec)
            _append_log(paths["log_file"], f"target [{tid}]: done (status {rc}, {dur}s{', dry run' if dry_run else ''})")
            if rc != 0 and overall_rc == 0:
                overall_rc = rc

        run_end_epoch = int(time.time())
        run_end_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        _atomic_write_json(paths["run_file"], {
            "state": "ok" if overall_rc == 0 else "error",
            "reason": "", "exit_code": overall_rc, "dry_run": dry_run,
            "pid": os.getpid(), "target": str(target_root),
            "timestamp": run_end_str, "epoch": run_end_epoch,
            "duration_sec": max(0, run_end_epoch - run_started_epoch),
        })
        _append_log(paths["log_file"], f"done (rsync status {overall_rc})")
        return overall_rc
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def save_target(payload: dict[str, Any], paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = load_or_seed_config(resolved, seed_if_missing=True)
    name = str(payload.get("name") or "").strip()
    source = str(payload.get("source") or "").strip()
    dest = str(payload.get("dest") or "").strip()
    if not source:
        raise ValueError("Source path is required")
    if not dest:
        dest = Path(source).name
    if not name:
        name = Path(source).name or source

    orig_id = str(payload.get("orig_id") or "").strip()
    raw_ex = payload.get("excludes", [])
    if isinstance(raw_ex, str):
        excludes = [line.strip() for line in re.split(r"[\n,]+", raw_ex) if line.strip()]
    elif isinstance(raw_ex, list):
        excludes = [str(x).strip() for x in raw_ex if str(x).strip()]
    else:
        excludes = []

    target_entry = {
        "id": orig_id or _slugify(name),
        "name": name,
        "source": source,
        "dest": dest,
        "enabled": bool(payload.get("enabled", True)),
        "delete": bool(payload.get("delete", True)),
        "excludes": excludes,
    }

    updated = False
    if orig_id:
        for idx, existing in enumerate(cfg["targets"]):
            if existing["id"] == orig_id:
                cfg["targets"][idx] = target_entry
                updated = True
                break
    if not updated:
        existing_ids = {t["id"] for t in cfg["targets"]}
        candidate = target_entry["id"]
        suffix = 2
        while candidate in existing_ids:
            candidate = f"{target_entry['id']}-{suffix}"
            suffix += 1
        target_entry["id"] = candidate
        cfg["targets"].append(target_entry)

    _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def delete_target(target_id: str, paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = load_or_seed_config(resolved, seed_if_missing=True)
    cfg["targets"] = [t for t in cfg["targets"] if t["id"] != target_id]
    _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def move_target(target_id: str, direction: str, paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = load_or_seed_config(resolved, seed_if_missing=True)
    targets = cfg["targets"]
    idx = next((i for i, t in enumerate(targets) if t["id"] == target_id), None)
    if idx is not None:
        swap = idx - 1 if direction == "up" else idx + 1
        if 0 <= swap < len(targets):
            targets[idx], targets[swap] = targets[swap], targets[idx]
            _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def toggle_target(target_id: str, paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = load_or_seed_config(resolved, seed_if_missing=True)
    for t in cfg["targets"]:
        if t["id"] == target_id:
            t["enabled"] = not bool(t.get("enabled", True))
            break
    _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def save_settings(payload: dict[str, Any], paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = load_or_seed_config(resolved, seed_if_missing=True)
    if "target_root" in payload and str(payload["target_root"]).strip():
        cfg["target_root"] = str(payload["target_root"]).strip()
    if "excludes" in payload:
        raw_ex = payload["excludes"]
        if isinstance(raw_ex, str):
            cfg["excludes"] = [line.strip() for line in re.split(r"[\n,]+", raw_ex) if line.strip()]
        elif isinstance(raw_ex, list):
            cfg["excludes"] = [str(x).strip() for x in raw_ex if str(x).strip()]
    _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def reset_defaults(paths: dict[str, Path] | None = None) -> dict[str, Any]:
    resolved = paths or _resolve_paths()
    cfg = default_config(resolved["home"], resolved["script_path"])
    _atomic_write_json(resolved["config_file"], cfg)
    return cfg


def _trigger_sync(dry_run: bool = False, target_id: str | None = None) -> int:
    exe = sys.argv[0]
    cmd = [sys.executable, exe, "run"]
    if dry_run:
        cmd.append("--dry-run")
    if target_id:
        cmd.extend(["--target", target_id])
    subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    print(json.dumps({"ok": True, "started": True, "dry_run": dry_run, "target": target_id or ""}))
    return 0


def _pick_folder(initial: str = "") -> int:
    start_dir = str(_expand_user_path(initial or "~", Path.home()))
    zenity = shutil.which("zenity")
    if zenity:
        cmd = [zenity, "--file-selection", "--directory", "--title=Select Folder"]
        if os.path.isdir(start_dir):
            cmd.append(f"--filename={start_dir.rstrip('/')}/")
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode == 0 and res.stdout.strip():
            print(res.stdout.strip())
            return 0
        return 1
    return 1


def _open_log() -> int:
    paths = _resolve_paths()
    log_path = paths["log_file"]
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
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return 0
        except OSError:
            continue
    return 1


def _open_rclone() -> int:
    for candidate in (shutil.which("rclone-control"), "/run/current-system/sw/bin/rclone-control", str(Path.home() / ".local/bin/rclone-control")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            subprocess.Popen([candidate], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("watch")

    run_p = commands.add_parser("run")
    run_p.add_argument("--dry-run", action="store_true")
    run_p.add_argument("--target", default="")

    trig_p = commands.add_parser("trigger")
    trig_p.add_argument("--dry-run", action="store_true")
    trig_p.add_argument("--target", default="")

    save_t = commands.add_parser("save-target")
    save_t.add_argument("--json", required=True)

    del_t = commands.add_parser("delete-target")
    del_t.add_argument("--id", required=True)

    move_t = commands.add_parser("move-target")
    move_t.add_argument("--id", required=True)
    move_t.add_argument("--dir", choices=("up", "down"), required=True)

    tog_t = commands.add_parser("toggle-target")
    tog_t.add_argument("--id", required=True)

    save_s = commands.add_parser("save-settings")
    save_s.add_argument("--json", required=True)

    commands.add_parser("reset-defaults")

    pick_p = commands.add_parser("pick-folder")
    pick_p.add_argument("--initial", default="")

    commands.add_parser("open-log")
    commands.add_parser("open-rclone")
    args = parser.parse_args()

    if args.command == "status":
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "run":
        return run_sync(dry_run=args.dry_run, target_id=args.target or None)
    if args.command == "trigger":
        return _trigger_sync(dry_run=args.dry_run, target_id=args.target or None)
    if args.command == "save-target":
        try:
            save_target(json.loads(args.json))
        except Exception as err:
            print(json.dumps({"ok": False, "error": str(err)}), file=sys.stderr)
            return 1
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "delete-target":
        delete_target(args.id)
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "move-target":
        move_target(args.id, args.dir)
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "toggle-target":
        toggle_target(args.id)
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "save-settings":
        save_settings(json.loads(args.json))
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "reset-defaults":
        reset_defaults()
        print(json.dumps(build_snapshot()))
        return 0
    if args.command == "pick-folder":
        return _pick_folder(args.initial)
    if args.command == "open-log":
        return _open_log()
    if args.command == "open-rclone":
        return _open_rclone()

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
