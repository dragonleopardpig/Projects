#!/usr/bin/env python3
"""The M90aPro restic backup (hosts/M90aPro/backup.nix) and its bar icon.

Run by systemd, as root:
  backup-pool due        scheduler (every 15 min): start the backup if it is due
  backup-pool prepare    ExecStartPre: write the user's extra excludes, clear stale locks
  backup-pool paths      dynamicFilesFrom: print the user's extra folders that exist
  backup-pool forget     ExecStartPost: forget --prune with the user's keep counts
  backup-pool summary    ExecStopPost: write the summary the bar icon reads

Run by the user (the Noctalia plugin local/backup-status):
  backup-pool status | watch                 the state as JSON (watch: a line per change)
  backup-pool run | stop                     start / stop a backup now
  backup-pool browse-start | browse-stop     read-only view of every snapshot
  backup-pool open-log                       follow the backup's journal in a terminal
  backup-pool save-settings --json JSON | reset-settings | pick-folder [--initial DIR]

Everything the user may change (time, pause, retention, extra folders and
excludes) is read at run time from their settings file, falling back to the
defaults in /etc/backup-status/<name>.json, so editing it needs no rebuild.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

CONFIG = Path(os.environ.get("BACKUP_STATUS_CONFIG", "/etc/backup-status/pool.json"))
TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
KEEP_KINDS = ("daily", "weekly", "monthly")
BACKOFF_SECONDS = 3600          # after a failed run, wait this long before trying again
SCHEDULER_MINUTES = 15          # backup-pool-scheduler.timer
STALLED_SECONDS = 600           # running, but nothing in the journal for this long
OVERDUE_SECONDS = 26 * 3600     # last success older than a day and a bit
REMIND_SECONDS = 3 * 86400      # desktop reminder, once a day, after this long
SUCCESS_RESULTS = ("success", "incomplete")
ACTIVE_STATES = ("activating", "active", "deactivating", "reloading")


# --------------------------------------------------------------- settings --

def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def effective_settings(defaults: dict[str, Any], raw: Any) -> tuple[dict[str, Any], list[str]]:
    """The user's settings over the defaults; invalid fields keep the default."""
    errors: list[str] = []
    out = {
        "paused": bool(defaults.get("paused", False)),
        "time": str(defaults.get("time", "12:30")),
        "keep": {k: int(defaults.get("keep", {}).get(k, d)) for k, d in zip(KEEP_KINDS, (7, 4, 6), strict=True)},
        "extra_paths": list(defaults.get("extra_paths", [])),
        "extra_excludes": list(defaults.get("extra_excludes", [])),
    }
    if raw is None:
        return out, errors
    if not isinstance(raw, dict):
        return out, ["settings file is not a JSON object"]
    if "paused" in raw:
        if isinstance(raw["paused"], bool):
            out["paused"] = raw["paused"]
        else:
            errors.append("paused must be true or false")
    if "time" in raw:
        if isinstance(raw["time"], str) and TIME_RE.match(raw["time"].strip()):
            out["time"] = raw["time"].strip()
        else:
            errors.append(f"time {raw['time']!r} is not HH:MM (00:00-23:59)")
    keep = raw.get("keep")
    if keep is not None:
        if not isinstance(keep, dict):
            errors.append("keep must be an object")
        else:
            for kind in KEEP_KINDS:
                if kind not in keep:
                    continue
                v = keep[kind]
                low = 1 if kind == "daily" else 0
                if isinstance(v, int) and not isinstance(v, bool) and low <= v <= 999:
                    out["keep"][kind] = v
                else:
                    errors.append(f"keep {kind} must be a whole number {low}-999")
    for key in ("extra_paths", "extra_excludes"):
        if key not in raw:
            continue
        items = raw[key]
        if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
            errors.append(f"{key} must be a list of text")
            continue
        clean = [i.strip() for i in items if i.strip() and "\n" not in i]
        if key == "extra_paths":
            bad = [p for p in clean if not p.startswith("/")]
            if bad:
                errors.append(f"extra folders must be absolute paths: {', '.join(bad)}")
            clean = [p for p in clean if p.startswith("/")]
        out[key] = clean
    return out, errors


def load_config() -> dict[str, Any] | None:
    cfg = load_json(CONFIG)
    return cfg if isinstance(cfg, dict) else None


def load_settings(cfg: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    return effective_settings(cfg.get("defaults", {}), load_json(Path(cfg["settings_file"])))


# ------------------------------------------------------------------- due --

def latest_slot(now: dt.datetime, hhmm: str) -> dt.datetime:
    """The most recent moment, at or before now, when the daily backup was due."""
    m = TIME_RE.match(hhmm)
    hour, minute = (int(m.group(1)), int(m.group(2))) if m else (12, 30)
    slot = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if slot > now:
        slot -= dt.timedelta(days=1)
    return slot


def next_slot(now: dt.datetime, hhmm: str) -> dt.datetime:
    return latest_slot(now, hhmm) + dt.timedelta(days=1)


def due_decision(now: dt.datetime, settings: dict[str, Any], summary: dict[str, Any] | None,
                 disk_present: bool, running: bool) -> str:
    """'start', or why not: paused / unplugged / running / backoff / done.

    A browse session does not block the backup: both only read-lock the
    repository (pruning waits for, or skips, an open browse).
    """
    if settings["paused"]:
        return "paused"
    if not disk_present:
        return "unplugged"
    if running:
        return "running"
    summary = summary or {}
    slot = latest_slot(now, settings["time"]).timestamp()
    last_success = float(summary.get("last_success") or 0)
    if last_success >= slot:
        return "done"
    last_attempt = float(summary.get("last_attempt") or 0)
    if summary.get("last_result") not in (None, *SUCCESS_RESULTS) and now.timestamp() - last_attempt < BACKOFF_SECONDS:
        return "backoff"
    return "start"


def unit_active(unit: str) -> bool:
    """Running, starting or stopping.  Not `systemctl is-active`: a oneshot backup
    is "activating" for its whole run, which is-active counts as not active."""
    res = subprocess.run(["systemctl", "show", "-p", "ActiveState", "--value", unit],
                         capture_output=True, text=True, check=False)
    return res.stdout.strip() in ACTIVE_STATES


def cmd_due(cfg: dict[str, Any]) -> int:
    settings, errors = load_settings(cfg)
    for e in errors:
        print(f"settings: {e} (default used)")
    decision = due_decision(
        dt.datetime.now().astimezone(), settings, load_json(Path(cfg["summary_file"])),
        disk_present=os.path.exists(cfg["disk_device"]), running=unit_active(cfg["unit"]),
    )
    print(f"backup {decision}")
    if decision == "start":
        subprocess.run(["systemctl", "start", "--no-block", cfg["unit"]], check=True)
    return 0


# ---------------------------------------------------- prepare / paths / forget --

def cmd_prepare(cfg: dict[str, Any]) -> int:
    settings, _ = load_settings(cfg)
    path = Path(cfg["excludes_file"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{p}\n" for p in settings["extra_excludes"]), encoding="utf-8")
    # A backup killed by Stop or a power cut leaves its lock behind; unlock only
    # removes locks whose process is gone.
    subprocess.run([cfg["restic"], "unlock"], check=False)
    return 0


def cmd_paths(cfg: dict[str, Any]) -> int:
    settings, _ = load_settings(cfg)
    for p in settings["extra_paths"]:
        if os.path.exists(p):
            print(p)
        else:
            print(f"backup-pool: extra folder {p} does not exist, skipped", file=sys.stderr)
    return 0


def forget_args(settings: dict[str, Any]) -> list[str]:
    # One group for the whole host: changing the extra folders must not leave
    # the old snapshots in a group of their own that is never pruned.
    args = ["forget", "--prune", "--group-by", "host", "--retry-lock", "2m"]
    for kind in KEEP_KINDS:
        n = settings["keep"][kind]
        if n > 0:
            args += [f"--keep-{kind}", str(n)]
    return args


def cmd_forget(cfg: dict[str, Any]) -> int:
    # The snapshot is saved either way; old ones are removed next run when not now.
    if unit_active(cfg["browse_unit"]):
        # Browse holds a lock that pruning would wait on for minutes.
        ok, note = False, "Browse was open"
    else:
        settings, _ = load_settings(cfg)
        res = subprocess.run([cfg["restic"], *forget_args(settings)], check=False)
        ok, note = res.returncode == 0, f"restic forget exited {res.returncode}"
    if not ok:
        print(f"backup-pool: old snapshots not removed ({note}); retried next run")
    path = Path(cfg["summary_file"])
    summary = load_json(path) or {}
    summary.update(last_prune=time.time(), last_prune_ok=ok, last_prune_note=None if ok else note)
    write_json_atomic(path, summary)
    return 0


# ----------------------------------------------------------------- summary --

def run_result(env: Any) -> str:
    """How the run ended, from what systemd hands ExecStopPost.

    restic exits 3 when the snapshot was saved but some files could not be read;
    Stop or a shutdown ends it with SIGTERM, or with 130 when restic catches the
    signal itself.  The unit counts all of these as success (SuccessExitStatus),
    so a Stop does not leave it "failed"; this tells them apart.
    """
    result = env.get("SERVICE_RESULT", "unknown")
    status = env.get("EXIT_STATUS", "")
    if status in ("TERM", "INT", "130"):
        return "stopped"
    if result == "success":
        return "incomplete" if status == "3" else "success"
    return result


SIZE_RE = r"[\d.]+ (?:B|KiB|MiB|GiB|TiB)"


def parse_run_log(lines: list[str]) -> dict[str, Any]:
    """What a run printed: what it added, how much it read, what went wrong."""
    out: dict[str, Any] = {"warnings": 0, "warning_lines": []}
    for line in lines:
        line = line.rstrip()
        if m := re.match(r"^Added to the repository: (.+)$", line):
            out["added"] = m.group(1)
        elif m := re.match(rf"^processed (\d+) files, ({SIZE_RE}) in ([\d:]+)", line):
            out["processed"] = f"{m.group(1)} files, {m.group(2)} in {m.group(3)}"
        elif m := re.match(r"^snapshot ([0-9a-f]+) saved", line):
            out["snapshot"] = m.group(1)
        elif m := re.match(r"^Fatal: (.+)$", line):
            out["error"] = m.group(1)
        elif line.startswith("error: ") or re.match(r"^\S.*: (permission denied|no such file or directory)$", line):
            out["warnings"] += 1
            if len(out["warning_lines"]) < 3:
                out["warning_lines"].append(line.removeprefix("error: "))
    return out


def build_summary(previous: dict[str, Any] | None, result: str, now: float,
                  snapshots: list[dict[str, Any]] | None, stats: dict[str, Any] | None,
                  disk_free: int | None, run_log: dict[str, Any] | None = None) -> dict[str, Any]:
    out = dict(previous or {})
    out["last_attempt"] = now
    out["last_result"] = result
    if result in SUCCESS_RESULTS:
        out["last_success"] = now
    log = run_log or {}
    out["last_error"] = None if result in SUCCESS_RESULTS else log.get("error")
    out["last_warnings"] = log.get("warnings", 0)
    out["last_warning_lines"] = log.get("warning_lines", [])
    if result in SUCCESS_RESULTS:
        out["last_added"] = log.get("added")
        out["last_processed"] = log.get("processed")
    if snapshots is not None:
        out["snapshots"] = len(snapshots)
        if snapshots:
            latest = max(snapshots, key=lambda s: s.get("time", ""))
            out["latest"] = {
                "time": latest.get("time"),
                "id": latest.get("short_id") or str(latest.get("id", ""))[:8],
                "paths": latest.get("paths", []),
                "bytes": (latest.get("summary") or {}).get("total_bytes_processed"),
            }
        else:
            out["latest"] = None
    if stats is not None:
        out["stored_bytes"] = stats.get("total_size")
        out["uncompressed_bytes"] = stats.get("total_uncompressed_size")
    if disk_free is not None:
        out["disk_free_bytes"] = disk_free
    return out


def restic_json(cfg: dict[str, Any], *args: str) -> Any:
    try:
        res = subprocess.run([cfg["restic"], "--no-lock", *args, "--json"],
                             capture_output=True, text=True, timeout=240, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except ValueError:
        return None


def write_json_atomic(path: Path, data: Any, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def invocation_log(invocation: str) -> list[str]:
    if not invocation:
        return []
    try:
        res = subprocess.run(["journalctl", f"_SYSTEMD_INVOCATION_ID={invocation}", "-o", "cat", "--no-pager"],
                             capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return res.stdout.splitlines()


def cmd_summary(cfg: dict[str, Any]) -> int:
    result = run_result(os.environ)
    path = Path(cfg["summary_file"])
    disk_free, snapshots, stats = None, None, None
    # Only while the disk is there: touching the mount point would wait on the automount.
    if os.path.exists(cfg["disk_device"]):
        try:
            st = os.statvfs(cfg["mount_point"])
            disk_free = st.f_bavail * st.f_frsize
        except OSError:
            pass
        snapshots = restic_json(cfg, "snapshots")
        stats = restic_json(cfg, "stats", "--mode", "raw-data")
    invocation = os.environ.get("INVOCATION_ID", "")
    summary = build_summary(load_json(path), result, time.time(), snapshots, stats, disk_free,
                            parse_run_log(invocation_log(invocation)))
    summary["invocation"] = invocation  # which run this describes (the icon compares it with the unit's)
    write_json_atomic(path, summary)
    return 0


# ====================================================== the user's side ==

def parse_size(text: str) -> float | None:
    m = re.match(r"^([\d.]+) (B|KiB|MiB|GiB|TiB)$", text.strip())
    if not m:
        return None
    return float(m.group(1)) * 1024 ** ("B", "KiB", "MiB", "GiB", "TiB").index(m.group(2))


PROGRESS_RE = re.compile(
    r"^\[(?P<elapsed>[\d:]+)\]\s+(?:(?P<pct>[\d.]+)%\s+)?(?P<files>\d+) files,? (?P<bytes>" + SIZE_RE + r")"
    r"(?:, total (?P<tfiles>\d+) files (?P<tbytes>" + SIZE_RE + r"))?, (?P<errors>\d+) errors"
    r"(?: ETA (?P<eta>[\d:]+))?")


def parse_progress(messages: list[str]) -> dict[str, Any]:
    """Where a running backup is, from its journal lines (oldest first)."""
    out: dict[str, Any] = {"phase": "starting", "percent": None, "eta": None, "elapsed": None, "text": ""}
    for msg in messages:
        if m := PROGRESS_RE.match(msg):
            out["phase"] = "backing up"
            pct = m.group("pct")
            if pct is None and m.group("tbytes"):
                done, total = parse_size(m.group("bytes")), parse_size(m.group("tbytes"))
                pct = f"{min(100.0, 100.0 * done / total):.2f}" if done is not None and total else None
            out["percent"] = float(pct) if pct is not None else None
            out["eta"] = m.group("eta")
            out["elapsed"] = m.group("elapsed")
            total = f" of {m.group('tbytes')}" if m.group("tbytes") else ""
            out["text"] = f"{m.group('bytes')}{total}, {m.group('files')} files"
            if m.group("errors") != "0":
                out["text"] += f", {m.group('errors')} unreadable"
        elif re.match(r"^snapshot [0-9a-f]+ saved", msg) or msg.startswith("Applying Policy"):
            out.update(phase="pruning", percent=None, eta=None, text="Removing old snapshots")
        elif msg.startswith("Fatal: "):
            out["text"] = msg
    return out


def human_bytes(n: Any) -> str:
    if not isinstance(n, (int, float)):
        return "—"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return "—"


def when_text(ts: float | None, now: dt.datetime) -> str:
    """'today 12:31', 'yesterday 12:31', 'Mon 12:31', '3 Nov 12:31', 'never'."""
    if not ts:
        return "never"
    t = dt.datetime.fromtimestamp(ts, tz=now.tzinfo)
    days = (now.date() - t.date()).days
    hhmm = t.strftime("%H:%M")
    if days == 0:
        return f"today {hhmm}"
    if days == 1:
        return f"yesterday {hhmm}"
    if days == -1:
        return f"tomorrow {hhmm}"
    if 1 < days < 7:
        return f"{t.strftime('%a')} {hhmm}"
    return f"{t.day} {t.strftime('%b')} {hhmm}"


def ago_text(seconds: float) -> str:
    if seconds < 90:
        return "just now"
    if seconds < 5400:
        return f"{int(seconds // 60)} min ago"
    if seconds < 2 * 86400:
        return f"{int(seconds // 3600)} h ago"
    return f"{int(seconds // 86400)} days ago"


RESULT_TEXT = {
    "exit-code": "restic stopped with an error",
    "signal": "it was killed",
    "timeout": "it timed out",
    "core-dump": "restic crashed",
    "watchdog": "it hung",
    "resources": "it could not start",
    "start-limit-hit": "it was started too often",
}

STATE_TEXT = {  # state: the badge (the plugin picks glyph and colour)
    "running": "Backing up",
    "stalled": "Stalled",
    "browsing": "Browsing",
    "failed": "Failed",
    "paused": "Paused",
    "unplugged": "Disk unplugged",
    "stopped": "Stopped",
    "incomplete": "Done, with warnings",
    "overdue": "Overdue",
    "due": "Due",
    "ok": "Up to date",
    "unavailable": "No backup",
}


def build_status(cfg: dict[str, Any] | None, settings_raw: Any, summary: dict[str, Any] | None,
                 units: dict[str, dict[str, str]], disk_present: bool,
                 journal: list[tuple[float, str]], now: dt.datetime) -> dict[str, Any]:
    """The bar's snapshot.  `journal` is the running backup's (time, line), oldest first."""
    if cfg is None:
        return {"available": False, "state": "unavailable", "badge": STATE_TEXT["unavailable"],
                "summary": "No backup is set up on this computer", "tooltip": []}
    settings, errors = effective_settings(cfg.get("defaults", {}), settings_raw)
    summary = summary or {}
    unit = units.get(cfg["unit"], {})
    browse = units.get(cfg["browse_unit"], {})
    running = unit.get("ActiveState") in ACTIVE_STATES
    browsing = browse.get("ActiveState") in ACTIVE_STATES
    ts_now = now.timestamp()
    last_success = float(summary.get("last_success") or 0) or None
    last_result = summary.get("last_result")
    last_attempt = float(summary.get("last_attempt") or 0) or None
    # A run that failed without writing the summary (an older run's) still shows as failed.
    if (not running and unit.get("ActiveState") == "failed"
            and summary.get("invocation") != unit.get("InvocationID")):
        last_result = unit.get("Result", "failed")
        last_attempt = _unit_ts(unit, "InactiveEnterTimestamp") or ts_now
        summary = dict(summary, last_error=None)

    progress = parse_progress([m for _, m in journal]) if running else None
    silent_for = ts_now - journal[-1][0] if running and journal else 0
    if running and not journal:
        silent_for = ts_now - (_unit_ts(unit, "InactiveExitTimestamp") or ts_now)
    if running and unit.get("ActiveState") == "deactivating":
        progress.update(phase="finishing", percent=None, eta=None, text="Writing the summary")

    decision = due_decision(now, settings, summary, disk_present, running)
    age = ts_now - last_success if last_success else None
    if running:
        state = "stalled" if silent_for > STALLED_SECONDS else "running"
    elif browsing:
        state = "browsing"
    elif last_result not in (None, *SUCCESS_RESULTS, "stopped") and (last_attempt or 0) >= (last_success or 0):
        state = "failed"
    elif settings["paused"]:
        state = "paused"
    elif not disk_present:
        state = "unplugged"
    elif last_result == "stopped" and (last_attempt or 0) >= (last_success or 0):
        state = "stopped"
    elif decision == "start":
        state = "overdue" if age is None or age > OVERDUE_SECONDS else "due"
    elif last_result == "incomplete":
        state = "incomplete"
    else:
        state = "ok"

    # When the next backup happens.
    if running:
        next_text = "running now"
    elif settings["paused"]:
        next_text = "paused (Run now still works)"
    elif decision == "start":
        next_text = f"within {SCHEDULER_MINUTES} min"
    elif decision == "unplugged" and last_success and last_success >= latest_slot(now, settings["time"]).timestamp():
        next_text = f"{when_text(next_slot(now, settings['time']).timestamp(), now)}, if the disk is plugged in"
    elif decision == "unplugged":
        next_text = "as soon as the disk is plugged in"
    elif decision == "backoff":
        next_text = f"retry {when_text((last_attempt or ts_now) + BACKOFF_SECONDS, now)}"
    else:
        next_text = when_text(next_slot(now, settings["time"]).timestamp(), now)

    failure = None
    if state == "failed":
        failure = summary.get("last_error") or RESULT_TEXT.get(str(last_result), f"it ended: {last_result}")

    if state in ("running", "stalled"):
        pct = progress["percent"]
        line = progress["phase"].capitalize()
        if pct is not None:
            line += f" {pct:.0f}%"
        if progress["eta"]:
            line += f", {progress['eta']} left"
        if state == "stalled":
            line = f"No progress for {int(silent_for // 60)} min ({progress['phase']})"
    elif state == "failed":
        line = f"Last backup failed: {failure}"
    elif state == "browsing":
        line = "Backups open read-only in the file manager"
    elif state == "unplugged":
        line = f"{cfg.get('disk_label', 'The backup disk')} is not plugged in"
    elif state == "stopped":
        line = "The last backup was stopped before it finished"
    elif state == "paused":
        line = "Daily backup is paused"
    else:
        line = f"Last backup {ago_text(age)}" if age is not None else "No backup yet"

    snapshots = summary.get("snapshots")
    latest = summary.get("latest") or {}
    tooltip = [{"key": "Backup", "value": STATE_TEXT[state]}]
    if state in ("running", "stalled"):
        tooltip.append({"key": "Now", "value": line})
        if progress["text"]:
            tooltip.append({"key": "Done", "value": progress["text"]})
    elif state == "failed":
        tooltip.append({"key": "Error", "value": failure})
    tooltip.append({"key": "Last backup", "value": when_text(last_success, now)})
    tooltip.append({"key": "Next", "value": next_text})
    if not disk_present and state != "unplugged":
        tooltip.append({"key": "Disk", "value": "unplugged"})

    return {
        "available": True,
        "state": state,
        "badge": STATE_TEXT[state],
        "summary": line,
        "tooltip": tooltip,
        "running": running,
        "browsing": browsing,
        "phase": progress["phase"] if progress else None,
        "percent": progress["percent"] if progress else None,
        "eta": progress["eta"] if progress else None,
        "progress_text": progress["text"] if progress else "",
        "disk_present": disk_present,
        "disk_label": cfg.get("disk_label", ""),
        "repository": cfg.get("repository", ""),
        "paths": cfg.get("paths", []),
        "excludes": cfg.get("excludes", []),
        "last_success_text": when_text(last_success, now),
        "last_result": last_result,
        "last_error": failure,
        "last_added": summary.get("last_added"),
        "last_processed": summary.get("last_processed"),
        "last_warnings": summary.get("last_warnings", 0),
        "last_warning_lines": summary.get("last_warning_lines", []),
        "prune_failed": summary.get("last_prune_ok") is False,
        "prune_note": summary.get("last_prune_note"),
        "next_text": next_text,
        "snapshots": snapshots,
        "latest_text": when_text(_iso_ts(latest.get("time")), now) if latest.get("time") else "—",
        "latest_size_text": human_bytes(latest.get("bytes")),
        "stored_text": human_bytes(summary.get("stored_bytes")),
        "disk_free_text": human_bytes(summary.get("disk_free_bytes")),
        "settings": settings,
        "settings_errors": errors,
        "defaults": cfg.get("defaults", {}),
        "can_run": disk_present and not running,
        "can_stop": running,
        "can_browse": disk_present and bool(snapshots),
    }


def _unit_ts(unit: dict[str, str], key: str) -> float:
    v = unit.get(key, "")
    try:
        return float(v.lstrip("@")) if v and v not in ("n/a", "0") else 0.0
    except ValueError:
        return 0.0


def _iso_ts(text: Any) -> float | None:
    if not isinstance(text, str):
        return None
    try:
        # restic writes nanoseconds; fromisoformat takes up to microseconds
        text = re.sub(r"(\.\d{6})\d+", r"\1", text).replace("Z", "+00:00")
        return dt.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


# --------------------------------------------------------- user: reading --

UNIT_PROPS = "Id,ActiveState,SubState,Result,InvocationID,InactiveExitTimestamp,InactiveEnterTimestamp"


def query_units(names: list[str]) -> dict[str, dict[str, str]]:
    try:
        res = subprocess.run(["systemctl", "show", *names, "-p", UNIT_PROPS, "--timestamp=unix"],
                             capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    units: dict[str, dict[str, str]] = {}
    cur: dict[str, str] = {}
    for line in res.stdout.splitlines() + [""]:
        if not line.strip():
            if cur.get("Id"):
                units[cur["Id"]] = cur
            cur = {}
        elif "=" in line:
            k, v = line.split("=", 1)
            cur[k] = v
    return units


def query_journal(invocation: str, lines: int = 40) -> list[tuple[float, str]]:
    if not invocation:
        return []
    try:
        res = subprocess.run(["journalctl", f"_SYSTEMD_INVOCATION_ID={invocation}", "-o", "json",
                              "-n", str(lines), "--no-pager"],
                             capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    for raw in res.stdout.splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        msg = entry.get("MESSAGE")
        if isinstance(msg, list):  # non-UTF-8 file names arrive as bytes
            msg = bytes(msg).decode("utf-8", "replace")
        if isinstance(msg, str):
            out.append((int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1e6, msg))
    return out


def current_status(cfg: dict[str, Any] | None = None) -> dict[str, Any]:
    cfg = cfg if cfg is not None else load_config()
    now = dt.datetime.now().astimezone()
    if cfg is None:
        return build_status(None, None, None, {}, False, [], now)
    units = query_units([cfg["unit"], cfg["browse_unit"]])
    unit = units.get(cfg["unit"], {})
    journal = query_journal(unit.get("InvocationID", "")) if unit.get("ActiveState") in ACTIVE_STATES else []
    return build_status(cfg, load_json(Path(cfg["settings_file"])), load_json(Path(cfg["summary_file"])),
                        units, os.path.exists(cfg["disk_device"]), journal, now)


def notifications(prev: dict[str, Any] | None, cur: dict[str, Any]) -> list[tuple[str, str, str]]:
    """(urgency, title, body) to send when the state changes for the worse."""
    if prev is None or not cur.get("available"):
        return []
    out = []
    if cur["state"] == "failed" and prev.get("state") != "failed":
        out.append(("critical", "Backup failed", cur.get("last_error") or "see the log"))
    if cur["state"] == "stalled" and prev.get("state") != "stalled":
        out.append(("normal", "Backup stalled", cur["summary"]))
    if prev.get("disk_present") is False and cur.get("disk_present") and cur["state"] in ("overdue", "due"):
        out.append(("low", "Backup disk plugged in", f"The backup starts {cur['next_text']}"))
    return out


def notify(urgency: str, title: str, body: str) -> None:
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Backup", "-u", urgency, "-i", "drive-harddisk", title, body],
                       check=False, timeout=5)


def cmd_watch(cfg: dict[str, Any] | None) -> int:
    previous_line, previous, reminded = None, None, None
    while True:
        cur = current_status(cfg if cfg is not None else load_config())
        for n in notifications(previous, cur):
            notify(*n)
        # A daily reminder while the last success is days old and nothing is set to fix it.
        today = dt.date.today()
        if cur.get("state") in ("overdue", "unplugged", "failed", "stopped") and reminded != today:
            summary = load_json(Path(cfg["summary_file"])) if cfg else None
            last = float((summary or {}).get("last_success") or 0)
            if last and time.time() - last > REMIND_SECONDS:
                notify("normal", "No backup for days", f"Last backup {cur['last_success_text']}: {cur['summary']}")
                reminded = today
        line = json.dumps(cur, sort_keys=True)
        if line != previous_line:
            print(line, flush=True)
            previous_line = line
        previous = cur
        time.sleep(1.5)


# --------------------------------------------------------- user: actions --

def _systemctl(*args: str) -> tuple[bool, str]:
    try:
        res = subprocess.run(["systemctl", *args], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    return res.returncode == 0, (res.stderr or res.stdout).strip()


def _finish(cfg: dict[str, Any], ok: bool, error: str = "") -> int:
    snap = current_status(cfg)
    if not ok:
        snap["action_error"] = error or "failed"
    print(json.dumps(snap))
    return 0 if ok else 1


def cmd_run(cfg: dict[str, Any]) -> int:
    if not os.path.exists(cfg["disk_device"]):
        return _finish(cfg, False, f"{cfg.get('disk_label', 'The backup disk')} is not plugged in")
    ok, err = _systemctl("start", "--no-block", cfg["unit"])
    return _finish(cfg, ok, err)


def cmd_stop(cfg: dict[str, Any]) -> int:
    ok, err = _systemctl("stop", "--no-block", cfg["unit"])
    return _finish(cfg, ok, err)


def browse_target(cfg: dict[str, Any]) -> Path:
    latest = Path(cfg["browse_dir"]) / "snapshots" / "latest"
    home = latest / "home" / cfg.get("user", "")
    return home if cfg.get("user") and home.is_dir() else latest


def cmd_browse_start(cfg: dict[str, Any], wait: float = 60.0, open_it: bool = True) -> int:
    if not os.path.exists(cfg["disk_device"]):
        return _finish(cfg, False, f"{cfg.get('disk_label', 'The backup disk')} is not plugged in")
    ok, err = _systemctl("start", cfg["browse_unit"])
    if not ok:
        return _finish(cfg, False, err)
    # restic reads the index before the snapshots appear.
    deadline = time.monotonic() + wait
    latest = Path(cfg["browse_dir"]) / "snapshots" / "latest"
    while not latest.exists() and time.monotonic() < deadline:
        if not unit_active(cfg["browse_unit"]):
            return _finish(cfg, False, "the browse view stopped; see the log")
        time.sleep(0.5)
    if not latest.exists():
        return _finish(cfg, False, "the snapshots did not appear in time")
    if open_it:
        try:
            subprocess.Popen(["xdg-open", str(browse_target(cfg))], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            pass  # no file manager here: the view is still open at browse_dir
    return _finish(cfg, True)


def cmd_browse_stop(cfg: dict[str, Any]) -> int:
    ok, err = _systemctl("stop", cfg["browse_unit"])
    return _finish(cfg, ok, err)


def cmd_open_log(cfg: dict[str, Any]) -> int:
    follow = ["journalctl", "-u", cfg["unit"], "-u", cfg["browse_unit"], "-u",
              cfg["unit"].replace("restic-backups-", "backup-").replace(".service", "-scheduler.service"),
              "-n", "300", "-f"]
    candidates: list[list[str]] = []
    term = os.environ.get("TERMINAL")
    if term and shutil.which(term):
        candidates.append([term, "-e", *follow])
    for kitty in (shutil.which("kitty"), f"/etc/profiles/per-user/{os.environ.get('USER', '')}/bin/kitty"):
        if kitty and os.access(kitty, os.X_OK):
            candidates.append([kitty, "--title", "Backup log", *follow])
            break
    if shutil.which("foot"):
        candidates.append(["foot", "--title=Backup log", *follow])
    for cmd in candidates:
        try:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            return 0
        except OSError:
            continue
    return 1


def settings_from_form(form: dict[str, Any], home: str) -> tuple[dict[str, Any], list[str]]:
    """The panel's form (text fields) as a settings file; errors for what does not parse."""
    errors: list[str] = []
    raw: dict[str, Any] = {}
    if "paused" in form:
        raw["paused"] = form["paused"] in (True, "true")
    if "time" in form:
        t = str(form["time"]).strip()
        if re.match(r"^\d:\d\d$", t):
            t = "0" + t
        raw["time"] = t
    keep: dict[str, Any] = {}
    for kind in KEEP_KINDS:
        if f"keep_{kind}" in form:
            v = str(form[f"keep_{kind}"]).strip()
            if re.fullmatch(r"\d{1,3}", v):
                keep[kind] = int(v)
            else:
                errors.append(f"keep {kind}: {v!r} is not a whole number")
    if keep:
        raw["keep"] = keep

    def lines(key: str) -> list[str]:
        value = form.get(key, "")
        items = value if isinstance(value, list) else str(value).replace(",", "\n").splitlines()
        return [i.strip() for i in items if str(i).strip()]

    if "extra_paths" in form:
        paths = []
        for p in lines("extra_paths"):
            if p == "~" or p.startswith("~/"):
                p = home + p[1:]   # the backup runs as root: ~ would be /root
            paths.append(p.rstrip("/") or "/")
        raw["extra_paths"] = paths
    if "extra_excludes" in form:
        raw["extra_excludes"] = lines("extra_excludes")
    _, invalid = effective_settings({}, raw)
    return raw, errors + invalid


def cmd_save_settings(cfg: dict[str, Any], payload: str) -> int:
    try:
        form = json.loads(payload)
    except ValueError:
        return _finish(cfg, False, "the settings are not valid JSON")
    if not isinstance(form, dict):
        return _finish(cfg, False, "the settings are not an object")
    raw, errors = settings_from_form(form, str(Path.home()))
    if errors:
        return _finish(cfg, False, "; ".join(errors))
    path = Path(cfg["settings_file"])
    current = load_json(path)
    merged = dict(current) if isinstance(current, dict) else {}
    merged.update(raw)
    write_json_atomic(path, merged)
    return _finish(cfg, True)


def cmd_reset_settings(cfg: dict[str, Any]) -> int:
    try:
        Path(cfg["settings_file"]).unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        return _finish(cfg, False, str(exc))
    return _finish(cfg, True)


def cmd_pick_folder(initial: str) -> int:
    zenity = shutil.which("zenity")
    if not zenity:
        return 1
    start = os.path.expanduser(initial or "~")
    cmd = [zenity, "--file-selection", "--directory", "--title=Folder to back up"]
    if os.path.isdir(start):
        cmd.append(f"--filename={start.rstrip('/')}/")
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode == 0 and res.stdout.strip():
        print(res.stdout.strip())
        return 0
    return 1


# ------------------------------------------------------------------- main --

ROOT_COMMANDS = {"due": cmd_due, "prepare": cmd_prepare, "paths": cmd_paths,
                 "forget": cmd_forget, "summary": cmd_summary}


def main(argv: list[str]) -> int:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    parser = argparse.ArgumentParser(prog="backup-pool", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in (*ROOT_COMMANDS, "status", "watch", "run", "stop", "browse-start", "browse-stop",
                 "open-log", "reset-settings"):
        sub.add_parser(name)
    sub.add_parser("save-settings").add_argument("--json", required=True)
    sub.add_parser("pick-folder").add_argument("--initial", default="")
    args = parser.parse_args(argv[1:])

    if args.command == "pick-folder":
        return cmd_pick_folder(args.initial)
    cfg = load_config()
    if args.command == "status":
        print(json.dumps(current_status(cfg)))
        return 0
    if args.command == "watch":
        return cmd_watch(cfg)
    if cfg is None:
        print(f"backup-pool: no backup set up here ({CONFIG} missing)", file=sys.stderr)
        return 1
    if args.command in ROOT_COMMANDS:
        return ROOT_COMMANDS[args.command](cfg)
    if args.command == "save-settings":
        return cmd_save_settings(cfg, args.json)
    return {"run": cmd_run, "stop": cmd_stop, "browse-start": cmd_browse_start,
            "browse-stop": cmd_browse_stop, "open-log": cmd_open_log,
            "reset-settings": cmd_reset_settings}[args.command](cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
