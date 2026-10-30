"""Observe Scramble transfers independently of the desktop and publish live status."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from configparser import RawConfigParser, Error as ConfigError
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import time


MIGRATION = "scramble-consolidate.service"
SYNC = "scramble-private-sync.service"
TIMER = "scramble-private-sync.timer"
MOUNT = "scramble-cloud-mount.service"
DESKTOP = "scramble-desktop.service"
BOOT = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
PROPERTIES = ["Id", "LoadState", "ActiveState", "SubState", "Result", "MainPID",
              "ControlGroup", "ExecMainStatus", "ExecMainExitTimestampMonotonic"]


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def alive(pid):
    try:
        return int(pid) > 0 and Path(f"/proc/{int(pid)}/stat").read_text().rsplit(") ", 1)[1][0] != "Z"
    except (OSError, ValueError, IndexError):
        return False


def workers(unit):
    group = unit.get("ControlGroup", "")
    if not group:
        return []
    result = []
    try:
        pids = (Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs").read_text().split()
        for pid in pids:
            try:
                executable = (Path("/proc") / pid / "exe").resolve(strict=True).name
                if "rclone" in executable and alive(pid):
                    arguments = (Path("/proc") / pid / "cmdline").read_bytes().split(b"\0")
                    command = arguments[1].decode(errors="replace") if len(arguments) > 1 else ""
                    result.append({"pid": int(pid), "command": command})
            except OSError:
                continue
    except OSError:
        pass
    return result


def unit_snapshot(backend):
    command = ["systemctl", "--user", "show", "--no-pager", MIGRATION, SYNC,
               TIMER, MOUNT, DESKTOP, backend]
    for prop in PROPERTIES:
        command.extend(["-p", prop])
    result = subprocess.run(command, capture_output=True, text=True, timeout=4, check=True)
    units = {}
    for block in result.stdout.strip().split("\n\n"):
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if "Id" in values:
            units[values["Id"]] = values
    for name in (MIGRATION, SYNC):
        units[name]["workers"] = workers(units[name])
    return units


def active(unit):
    return unit.get("ActiveState") in {"active", "activating", "deactivating"}


def failed(unit):
    return (unit.get("ActiveState") == "failed" or unit.get("SubState") == "auto-restart"
            or unit.get("LoadState") in {"not-found", "bad-setting", "error"})


def mounted_paths():
    # Reading mountinfo never waits for an unresponsive FUSE filesystem.
    return {re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), line.split()[4])
            for line in Path("/proc/self/mountinfo").read_text().splitlines()}


def derive(units, backend, configured, ready, stopped, stopping, folder_ok,
           mounted, phase, probe, last_success, now):
    migration = units.get(MIGRATION, {})
    sync = units.get(SYNC, {})
    task = migration if active(migration) or not ready else sync
    transfers = task.get("workers", [])
    result = {"state": "ok", "label": "Ready", "summary": "Rclone is healthy; waiting for the next automatic sync",
              "workers": transfers, "task": MIGRATION if task is migration else SYNC,
              "last_success": last_success, "phase": phase, "connection": probe.get("ok"),
              "connection_checked": probe.get("checked"), "backend": backend,
              "backend_state": units.get(backend, {}).get("ActiveState", "unknown"),
              "mount_state": units.get(MOUNT, {}).get("ActiveState", "unknown"),
              "desktop_state": units.get(DESKTOP, {}).get("ActiveState", "unknown")}

    def status(state, label, summary):
        result.update(state=state, label=label, summary=summary)
        return result

    if stopping:
        return status("busy", "Stopping", "Scramble is stopping safely; waiting for active work")
    if stopped and not active(units.get(DESKTOP, {})) and not active(units.get(backend, {})):
        return status("stopped", "Stopped", "Scramble was stopped; launch Scramble Desktop to reconnect")
    if configured != "ready":
        return status("pending", "Setup", "Complete the Scramble login and import the original private crypt key")
    if failed(task):
        return status("error", "Sync failed", "Rclone transfer failed or is waiting to retry; use Sync Now to reconnect")
    connection_unit = units.get(backend, {})
    if failed(connection_unit) or not active(connection_unit) or not alive(connection_unit.get("MainPID", "0")):
        return status("error", "Disconnected", "The Scramble connection service is stopped")
    if probe.get("ok") is False:
        return status("error", "Offline", "The cloud connection check failed; local files remain available")
    if not folder_ok:
        return status("error", "Folder error", "Scramble Private must be the real writable offline directory")
    if failed(units.get(MOUNT, {})) or (ready and not mounted):
        return status("error", "Cloud unmounted", "The cloud browser is unavailable; use Sync Now to reconnect")
    if active(task):
        if not alive(task.get("MainPID", "0")):
            return status("error", "Worker stopped", "The sync coordinator has no live process")
        if transfers:
            command = transfers[0]["command"]
            label = {"check": "Verifying", "bisync": "Syncing", "copy": "Transferring"}.get(command, "Checking")
            if task is migration:
                count = re.search(r"uploading private files: (\d+/\d+)", phase)
                if count:
                    label = "Upload " + count[1]
            return status("busy", label, phase if task is migration and phase else "Rclone is running the private sync")
        return status("busy", "Preparing", phase or "The sync coordinator is preparing the next rclone transfer")
    if not ready:
        return status("pending", "Migration paused", phase or "Use Sync Now to resume the initial private migration")
    if sync.get("Result", "success") != "success" or sync.get("ExecMainStatus", "0") != "0":
        return status("error", "Sync failed", "The last rclone sync failed; use Sync Now to retry")
    if not active(units.get(TIMER, {})):
        return status("error", "Timer stopped", "Automatic rclone syncing is stopped; use Sync Now to reconnect")
    if not last_success:
        return status("pending", "First sync", "Waiting for the first successful private sync")
    if now - last_success > 900:
        return status("error", "Sync overdue", "No successful private sync in the last 15 minutes")
    if probe.get("ok") is None:
        return status("pending", "Connecting", "Checking the encrypted cloud connection")
    return result


class Notifications:
    def __init__(self):
        self.error_since = None
        self.announced_error = False
        self.announced_start = False

    def update(self, report, now):
        state = report["state"]
        if state == "error":
            if self.error_since is None:
                self.error_since = now
            if not self.announced_error and now - self.error_since >= 10:
                self.announced_error = True
                return "Scramble needs attention", report["summary"], "critical"
            return None
        self.error_since = None
        if state in {"pending", "stopped"} or report["label"] == "Stopping":
            self.announced_error = False
            if state == "stopped":
                self.announced_start = False
            return None
        if self.announced_error:
            self.announced_error = False
            self.announced_start = True
            return "Scramble is responding again", report["summary"], "normal"
        if not self.announced_start and report.get("connection") is True:
            self.announced_start = True
            return "Scramble monitor is active", report["summary"], "normal"
        return None


class Monitor:
    def __init__(self, home):
        self.home = Path(home)
        self.state = self.home / ".local/state/scramble"
        self.file = self.state / "health.json"
        self.backend = os.environ.get("SCRAMBLE_BACKEND", "scramble-desktop.service" if os.uname().nodename == "M90aPro" else "scramble-webdav.service")
        self.last_success = read_json(self.file).get("last_success")
        self.probe = {}
        self.future = None
        self.next_probe = 0
        self.notifications = Notifications()

    def configured(self):
        config = RawConfigParser()
        try:
            config.read(self.home / ".config/rclone/rclone.conf")
            if (config.get("scramble_private", "type", fallback="") == "crypt"
                    and config.get("scramble_private", "password", fallback="")
                    and config.has_section("scramble_drive")):
                return "ready"
        except (OSError, ConfigError):
            pass
        return "missing"

    def check_connection(self):
        command = ["rclone", "cat", "scramble_private:Current/RCLONE_TEST", "--config",
                   str(self.home / ".config/rclone/rclone.conf"), "--webdav-encoding", "Colon",
                   "--contimeout", "3s", "--timeout", "5s", "--retries", "1", "--low-level-retries", "1"]
        try:
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            ok = result.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        return {"ok": ok, "checked": time.time()}

    def snapshot(self, pool):
        now = time.time()
        units = unit_snapshot(self.backend)
        configured = self.configured()
        try:
            stopping = alive((self.state / "stopping").read_text().strip())
        except OSError:
            stopping = False
        stopped = (self.state / "stopped").exists()
        if self.future is not None and self.future.done():
            self.probe = self.future.result()
            self.future = None
            self.next_probe = time.monotonic() + 15
        if (self.future is None and time.monotonic() >= self.next_probe and configured == "ready"
                and active(units[self.backend]) and not stopped and not stopping):
            self.future = pool.submit(self.check_connection)
        sync = units[SYNC]
        last_us = int(sync.get("ExecMainExitTimestampMonotonic", "0"))
        if last_us and sync.get("Result") == "success" and sync.get("ExecMainStatus") == "0":
            self.last_success = now - max(0, time.monotonic() - last_us / 1_000_000)
        mounts = mounted_paths()
        folder = self.home / "Scramble Private"
        folder_ok = str(folder) not in mounts and not folder.is_symlink() and folder.is_dir()
        try:
            phase = (self.state / "consolidation/phase").read_text().strip()
        except OSError:
            phase = ""
        report = derive(units, self.backend, configured,
                        (self.home / ".config/rclone/scramble-private-v2-ready").exists(),
                        stopped, stopping, folder_ok, str(self.home / "Scramble Cloud") in mounts,
                        phase, self.probe, self.last_success, now)
        report.update(updated=now, updated_monotonic=time.monotonic(), boot_id=BOOT)
        sample = self.progress(report)
        report.update(sample)
        if not report["workers"]:
            report["speed"] = "0 B/s"
        return report

    def progress(self, report):
        if not report["workers"]:
            return {}
        try:
            result = subprocess.run([
                "journalctl", "--user", "--no-pager", "-b", "-u", report["task"], "-n", "5", "-o", "json",
                "--output-fields=MESSAGE,_PID,__MONOTONIC_TIMESTAMP",
            ], capture_output=True, text=True, timeout=3, check=True)
            pids = {str(worker["pid"]) for worker in report["workers"]}
            candidates = []
            for line in reversed(result.stdout.splitlines()):
                entry = json.loads(line)
                message = entry.get("MESSAGE", "").strip()
                match = re.search(r"\b([\d.]+\s*[KMGTPE]?i?B/s)\b", message, re.IGNORECASE)
                age = time.monotonic() - int(entry.get("__MONOTONIC_TIMESTAMP", "0")) / 1_000_000
                if match and "ETA" in message and 0 <= age <= 15:
                    current = entry.get("_PID") in pids
                    candidates.append({"progress": re.sub(r"^(?:INFO\+2|NOTICE|INFO):\s*", "", message) if current else "",
                                       "speed": match[1], "speed_sampled": time.time() - age,
                                       "speed_scope": "current" if current else "recent"})
                    if current:
                        return candidates[-1]
            if candidates:
                return candidates[0]
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return {}

    def publish(self, report):
        temporary = self.file.with_suffix(".tmp")
        temporary.write_text(json.dumps(report) + "\n")
        temporary.replace(self.file)
        notice = self.notifications.update(report, time.monotonic())
        if notice:
            title, message, urgency = notice
            try:
                subprocess.run(["notify-send", "--app-name=Scramble", "--icon=scramble-desktop",
                                "--urgency=" + urgency, "--expire-time=15000", title, message], timeout=3, check=False)
            except (OSError, subprocess.TimeoutExpired):
                pass

    def run(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state / "health.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with ThreadPoolExecutor(max_workers=1) as pool:
                while True:
                    started = time.monotonic()
                    try:
                        report = self.snapshot(pool)
                    except (OSError, ValueError, subprocess.SubprocessError) as error:
                        report = {"state": "error", "label": "Monitor error", "summary": "Scramble health checks could not run: " + str(error),
                                  "updated": time.time(), "updated_monotonic": time.monotonic(), "boot_id": BOOT,
                                  "workers": [], "last_success": self.last_success}
                    self.publish(report)
                    time.sleep(max(0.1, 5 - (time.monotonic() - started)))


def cached_status(home):
    report = read_json(Path(home) / ".local/state/scramble/health.json")
    if (report.get("boot_id") != BOOT
            or not 0 <= time.monotonic() - report.get("updated_monotonic", 0) < 20):
        return {"state": "error", "label": "Monitor stopped", "summary": "The Scramble health monitor is not responding; relaunch Scramble Desktop",
                "workers": [], "last_success": report.get("last_success")}
    return report


def display(report, mode):
    if mode == "json":
        print(json.dumps(report))
    elif mode == "brief":
        print(report["state"] + "|" + report["summary"].replace("|", "/").replace("\n", " "))
    else:
        print("Scramble: " + report["label"] + " — " + report["summary"])
        if report.get("workers"):
            print("Rclone transfer: running (PID " + ", ".join(str(worker["pid"]) for worker in report["workers"]) + ")")
        elif report["state"] == "ok":
            print("Rclone transfer: idle; automatic check every five minutes")
        else:
            print("Rclone transfer: no transfer process running")
        if report.get("progress"):
            print("Current transfer: " + report["progress"])
        if report.get("speed"):
            age = f" ({max(0, int(time.time() - report['speed_sampled']))} seconds ago)" if report.get("speed_sampled") else ""
            print("Sync speed: " + report["speed"] + age)
        checked = report.get("connection_checked")
        if checked:
            print("Encrypted cloud check: " + ("passed" if report["connection"] else "failed")
                  + f" ({max(0, int(time.time() - checked))} seconds ago)")
        if report.get("last_success"):
            print("Last successful sync: " + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(report["last_success"])))
        if report.get("backend_state"):
            print("Scramble connection service: " + report["backend_state"])
            print("Cloud mount: " + report["mount_state"])
        print("Offline folder: " + str(Path.home() / "Scramble Private"))
        print("Cloud view: " + str(Path.home() / "Scramble Cloud") + " (decrypted, read-only)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["monitor", "status"])
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--brief", action="store_true")
    modes.add_argument("--json", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    os.environ.pop("LD_LIBRARY_PATH", None)
    os.environ.pop("LD_PRELOAD", None)
    if args.command == "monitor":
        Monitor(Path.home()).run()
    else:
        display(cached_status(Path.home()), "json" if args.json else "brief" if args.brief else "full")


if __name__ == "__main__":
    main()
