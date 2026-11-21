#!/usr/bin/env python3
"""Unit tests for scripts/backup-pool.py (the root side of the M90aPro backup).

    python3 tests/test-backup-pool.py [path/to/backup-pool.py]
"""

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).parent.parent / "scripts/backup-pool.py"
spec = importlib.util.spec_from_file_location("backup_pool", script)
bp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bp)

DEFAULTS = {"time": "12:30", "paused": False, "keep": {"daily": 7, "weekly": 4, "monthly": 6},
            "extra_paths": [], "extra_excludes": []}
TZ = dt.timezone(dt.timedelta(hours=8))


def at(day, hour, minute=0):
    return dt.datetime(2026, 11, day, hour, minute, tzinfo=TZ)


class Settings(unittest.TestCase):
    def test_no_file_means_defaults(self):
        s, errors = bp.effective_settings(DEFAULTS, None)
        self.assertEqual(s["time"], "12:30")
        self.assertEqual(s["keep"], {"daily": 7, "weekly": 4, "monthly": 6})
        self.assertEqual(errors, [])

    def test_user_values_override(self):
        s, errors = bp.effective_settings(DEFAULTS, {
            "time": "03:05", "paused": True, "keep": {"daily": 3, "monthly": 0},
            "extra_paths": ["/mnt/winapps", " /srv/data "], "extra_excludes": ["*.iso", ""]})
        self.assertEqual(errors, [])
        self.assertEqual(s["time"], "03:05")
        self.assertTrue(s["paused"])
        self.assertEqual(s["keep"], {"daily": 3, "weekly": 4, "monthly": 0})
        self.assertEqual(s["extra_paths"], ["/mnt/winapps", "/srv/data"])
        self.assertEqual(s["extra_excludes"], ["*.iso"])

    def test_invalid_fields_keep_the_default_and_are_reported(self):
        s, errors = bp.effective_settings(DEFAULTS, {
            "time": "25:00", "paused": "yes", "keep": {"daily": 0, "weekly": -1, "monthly": True},
            "extra_paths": ["relative/dir", "/ok"], "extra_excludes": "not a list"})
        self.assertEqual(s["time"], "12:30")
        self.assertFalse(s["paused"])
        self.assertEqual(s["keep"], {"daily": 7, "weekly": 4, "monthly": 6})  # daily >= 1
        self.assertEqual(s["extra_paths"], ["/ok"])
        self.assertEqual(s["extra_excludes"], [])
        self.assertEqual(len(errors), 7, errors)

    def test_not_an_object(self):
        s, errors = bp.effective_settings(DEFAULTS, ["x"])
        self.assertEqual(s["time"], "12:30")
        self.assertEqual(len(errors), 1)


class Due(unittest.TestCase):
    def settings(self, **over):
        s, _ = bp.effective_settings(DEFAULTS, over)
        return s

    def test_slots_across_midnight(self):
        self.assertEqual(bp.latest_slot(at(21, 13), "12:30"), at(21, 12, 30))
        self.assertEqual(bp.latest_slot(at(21, 9), "12:30"), at(20, 12, 30))
        self.assertEqual(bp.latest_slot(at(21, 0, 10), "23:50"), at(20, 23, 50))
        self.assertEqual(bp.next_slot(at(21, 13), "12:30"), at(22, 12, 30))

    def test_due_after_the_slot_and_done_once_backed_up(self):
        s = self.settings()
        self.assertEqual(bp.due_decision(at(21, 12, 45), s, {"last_success": at(20, 13).timestamp()},
                                         True, False), "start")
        self.assertEqual(bp.due_decision(at(21, 12, 45), s, {"last_success": at(21, 12, 40).timestamp()},
                                         True, False), "done")
        # before today's slot, yesterday's success counts
        self.assertEqual(bp.due_decision(at(21, 9), s, {"last_success": at(20, 13).timestamp()},
                                         True, False), "done")

    def test_catch_up_after_the_machine_was_off_or_the_disk_unplugged(self):
        s = self.settings()
        two_days_ago = {"last_success": at(19, 13).timestamp()}
        self.assertEqual(bp.due_decision(at(21, 8), s, two_days_ago, True, False), "start")
        self.assertEqual(bp.due_decision(at(21, 8), s, None, True, False), "start")  # never

    def test_reasons_not_to_start(self):
        s = self.settings()
        old = {"last_success": 0}
        self.assertEqual(bp.due_decision(at(21, 13), self.settings(paused=True), old, True, False), "paused")
        self.assertEqual(bp.due_decision(at(21, 13), s, old, False, False), "unplugged")
        self.assertEqual(bp.due_decision(at(21, 13), s, old, True, True), "running")

    def test_backoff_after_a_failed_or_stopped_run(self):
        s = self.settings()
        failed = {"last_success": 0, "last_attempt": at(21, 12, 50).timestamp(), "last_result": "exit-code"}
        self.assertEqual(bp.due_decision(at(21, 13), s, failed, True, False), "backoff")
        self.assertEqual(bp.due_decision(at(21, 14), s, failed, True, False), "start")
        stopped = dict(failed, last_result="stopped")
        self.assertEqual(bp.due_decision(at(21, 13), s, stopped, True, False), "backoff")


class Forget(unittest.TestCase):
    def test_keep_counts_and_one_group_per_host(self):
        s, _ = bp.effective_settings(DEFAULTS, {"keep": {"daily": 3, "weekly": 0, "monthly": 2}})
        args = bp.forget_args(s)
        self.assertEqual(args[:6], ["forget", "--prune", "--group-by", "host", "--retry-lock", "2m"])
        self.assertIn("--keep-daily", args)
        self.assertEqual(args[args.index("--keep-daily") + 1], "3")
        self.assertNotIn("--keep-weekly", args)  # 0 = none kept by week
        self.assertEqual(args[args.index("--keep-monthly") + 1], "2")


class Summary(unittest.TestCase):
    snaps = [
        {"time": "2026-11-20T12:31:00+08:00", "short_id": "aaaa1111", "paths": ["/home", "/persist"]},
        {"time": "2026-11-21T12:31:00+08:00", "short_id": "bbbb2222", "paths": ["/home", "/persist"],
         "summary": {"total_bytes_processed": 25 * 2**30}},
    ]

    def test_success(self):
        out = bp.build_summary(None, "success", 1000.0, self.snaps,
                               {"total_size": 14 * 2**30, "total_uncompressed_size": 21 * 2**30}, 5 * 2**40)
        self.assertEqual(out["last_success"], 1000.0)
        self.assertEqual(out["snapshots"], 2)
        self.assertEqual(out["latest"]["id"], "bbbb2222")
        self.assertEqual(out["latest"]["bytes"], 25 * 2**30)
        self.assertEqual(out["stored_bytes"], 14 * 2**30)
        self.assertEqual(out["disk_free_bytes"], 5 * 2**40)

    def test_a_failure_keeps_the_last_success_and_what_is_unknown(self):
        prev = {"last_success": 500.0, "snapshots": 2, "stored_bytes": 7}
        out = bp.build_summary(prev, "exit-code", 1000.0, None, None, None)
        self.assertEqual(out["last_success"], 500.0)
        self.assertEqual(out["last_result"], "exit-code")
        self.assertEqual(out["last_attempt"], 1000.0)
        self.assertEqual(out["snapshots"], 2)
        self.assertEqual(out["stored_bytes"], 7)

    def test_how_the_run_ended(self):
        # what systemd 260 hands ExecStopPost (checked with transient units)
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "success", "EXIT_CODE": "exited", "EXIT_STATUS": "0"}), "success")
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "success", "EXIT_CODE": "exited", "EXIT_STATUS": "3"}), "incomplete")
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "signal", "EXIT_CODE": "killed", "EXIT_STATUS": "TERM"}), "stopped")
        # with SuccessExitStatus=SIGTERM 130 a stop reports success
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "success", "EXIT_CODE": "killed", "EXIT_STATUS": "TERM"}), "stopped")
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "success", "EXIT_CODE": "exited", "EXIT_STATUS": "130"}), "stopped")
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "exit-code", "EXIT_CODE": "exited", "EXIT_STATUS": "130"}), "stopped")
        self.assertEqual(bp.run_result({"SERVICE_RESULT": "exit-code", "EXIT_CODE": "exited", "EXIT_STATUS": "1"}), "exit-code")
        self.assertEqual(bp.run_result({}), "unknown")

    def test_the_run_log(self):
        log = bp.parse_run_log([
            "no parent snapshot found, will read all files",
            "error: open /home/thinky/locked.db: permission denied",
            "Files:       196859 new,     0 changed,     0 unmodified",
            "Added to the repository: 21.519 GiB (14.046 GiB stored)",
            "processed 196859 files, 23.941 GiB in 2:49",
            "snapshot 4fd8ac02 saved",
        ])
        self.assertEqual(log["added"], "21.519 GiB (14.046 GiB stored)")
        self.assertEqual(log["processed"], "196859 files, 23.941 GiB in 2:49")
        self.assertEqual(log["snapshot"], "4fd8ac02")
        self.assertEqual(log["warnings"], 1)
        self.assertEqual(log["warning_lines"], ["open /home/thinky/locked.db: permission denied"])
        fatal = bp.parse_run_log(["Fatal: unable to open repository at /mnt/backup/restic/m90apro: no such file"])
        self.assertIn("unable to open repository", fatal["error"])
        out = bp.build_summary({"last_success": 5.0}, "exit-code", 10.0, None, None, None, fatal)
        self.assertIn("unable to open", out["last_error"])
        out = bp.build_summary(out, "success", 20.0, None, None, None, log)
        self.assertIsNone(out["last_error"])
        self.assertEqual(out["last_added"], "21.519 GiB (14.046 GiB stored)")


# ------------------------------------------------------------ the user's side --

CFG = {
    "unit": "restic-backups-pool.service", "browse_unit": "restic-browse-pool.service",
    "disk_label": "Seagate Linux-Data", "repository": "/mnt/backup/restic/m90apro",
    "paths": ["/home", "/persist"], "excludes": ["/home/*/.cache"], "defaults": DEFAULTS,
    "settings_file": "/nonexistent", "summary_file": "/nonexistent", "user": "thinky",
}
IDLE = {"restic-backups-pool.service": {"ActiveState": "inactive", "Result": "success"},
        "restic-browse-pool.service": {"ActiveState": "inactive"}}


def unit_states(backup="inactive", browse="inactive", **extra):
    return {"restic-backups-pool.service": dict({"ActiveState": backup}, **extra),
            "restic-browse-pool.service": {"ActiveState": browse}}


class Progress(unittest.TestCase):
    def test_restic_0_18_lines(self):
        # as restic 0.18.1 prints them with RESTIC_PROGRESS_FPS into the journal
        p = bp.parse_progress([
            "no parent snapshot found, will read all files",
            "[0:00] 1888 files, 96.736 MiB, 0 errors",
            "[0:05] 12.50%  1888 files 2.000 GiB, total 6834 files 16.000 GiB, 0 errors ETA 0:35",
            "/home/thinky/some/file.txt",
        ])
        self.assertEqual(p["phase"], "backing up")
        self.assertEqual(p["percent"], 12.5)
        self.assertEqual(p["eta"], "0:35")
        self.assertEqual(p["text"], "2.000 GiB of 16.000 GiB, 1888 files")

    def test_percent_from_the_totals_when_restic_prints_none(self):
        p = bp.parse_progress(["[0:00] 1888 files 96.736 MiB, total 6834 files 231.703 MiB, 2 errors"])
        self.assertAlmostEqual(p["percent"], 41.75, places=1)
        self.assertIn("2 unreadable", p["text"])

    def test_pruning_after_the_snapshot(self):
        p = bp.parse_progress(["[0:05] 99.00%  1 files 1.000 GiB, total 1 files 1.010 GiB, 0 errors ETA 0:01",
                               "snapshot 4fd8ac02 saved", "Applying Policy: keep 7 daily snapshots"])
        self.assertEqual(p["phase"], "pruning")
        self.assertIsNone(p["percent"])

    def test_sizes(self):
        self.assertEqual(bp.parse_size("1.5 KiB"), 1536)
        self.assertEqual(bp.parse_size("2 GiB"), 2 * 2**30)
        self.assertIsNone(bp.parse_size("lots"))
        self.assertEqual(bp.human_bytes(14 * 2**30), "14.0 GiB")
        self.assertEqual(bp.human_bytes(None), "—")


class Status(unittest.TestCase):
    now = at(21, 13)
    fresh = {"last_success": at(21, 12, 31).timestamp(), "last_attempt": at(21, 12, 31).timestamp(),
             "last_result": "success", "snapshots": 3, "stored_bytes": 14 * 2**30,
             "latest": {"time": "2026-11-21T12:31:00.123456789+08:00", "id": "bbbb2222", "bytes": 25 * 2**30}}

    def status(self, summary=None, units=IDLE, disk=True, journal=(), settings=None, now=None):
        return bp.build_status(CFG, settings, summary, units, disk, list(journal), now or self.now)

    def test_no_backup_on_this_host(self):
        s = bp.build_status(None, None, None, {}, False, [], self.now)
        self.assertFalse(s["available"])
        self.assertEqual(s["state"], "unavailable")

    def test_up_to_date(self):
        s = self.status(self.fresh)
        self.assertEqual(s["state"], "ok")
        self.assertEqual(s["summary"], "Last backup 29 min ago")
        self.assertEqual(s["next_text"], "tomorrow 12:30")
        self.assertEqual(s["latest_text"], "today 12:31")
        self.assertEqual(s["stored_text"], "14.0 GiB")
        self.assertTrue(s["can_run"] and s["can_browse"])
        self.assertFalse(s["can_stop"])

    def test_running_with_progress(self):
        t = self.now.timestamp()
        s = self.status(self.fresh, unit_states("activating"), journal=[
            (t - 3, "[1:05] 42.00%  10 files 4.200 GiB, total 20 files 10.000 GiB, 0 errors ETA 1:30")])
        self.assertEqual(s["state"], "running")
        self.assertEqual(s["percent"], 42.0)
        self.assertEqual(s["summary"], "Backing up 42%, 1:30 left")
        self.assertTrue(s["can_stop"])
        self.assertFalse(s["can_run"])

    def test_running_but_silent_for_too_long_is_stalled(self):
        t = self.now.timestamp()
        s = self.status(self.fresh, unit_states("activating"), journal=[
            (t - 900, "[1:05] 42.00%  10 files 4.200 GiB, total 20 files 10.000 GiB, 0 errors ETA 1:30")])
        self.assertEqual(s["state"], "stalled")
        self.assertIn("No progress for 15 min", s["summary"])

    def test_failed_until_the_next_success(self):
        failed = dict(self.fresh, last_attempt=at(21, 12, 50).timestamp(), last_result="exit-code",
                      last_error="unable to open repository")
        s = self.status(failed)
        self.assertEqual(s["state"], "failed")
        self.assertEqual(s["last_error"], "unable to open repository")
        self.assertEqual(s["summary"], "Last backup failed: unable to open repository")
        # a failure without restic's own message falls back to how systemd saw it
        s = self.status(dict(failed, last_error=None, last_result="signal"))
        self.assertEqual(s["last_error"], "it was killed")

    def test_a_failed_unit_whose_run_wrote_no_summary(self):
        units = unit_states("failed", Result="exit-code", InvocationID="new", InactiveEnterTimestamp="@1795300000")
        s = self.status(dict(self.fresh, invocation="old"), units)
        self.assertEqual(s["state"], "failed")
        self.assertEqual(s["last_error"], "restic stopped with an error")
        # the summary of that very run decides
        s = self.status(dict(self.fresh, invocation="new"), units)
        self.assertEqual(s["state"], "ok")

    def test_priorities(self):
        failed = dict(self.fresh, last_attempt=at(21, 12, 50).timestamp(), last_result="exit-code")
        self.assertEqual(self.status(failed, unit_states("activating"))["state"], "running")
        self.assertEqual(self.status(self.fresh, unit_states(browse="active"))["state"], "browsing")
        self.assertEqual(self.status(failed, settings={"paused": True})["state"], "failed")
        self.assertEqual(self.status(self.fresh, settings={"paused": True})["state"], "paused")
        self.assertEqual(self.status(self.fresh, disk=False)["state"], "unplugged")

    def test_unplugged_says_when_it_will_run(self):
        s = self.status(self.fresh, disk=False)
        self.assertEqual(s["next_text"], "tomorrow 12:30, if the disk is plugged in")
        self.assertEqual(s["summary"], "Seagate Linux-Data is not plugged in")
        self.assertFalse(s["can_run"])
        old = dict(self.fresh, last_success=at(19, 12, 31).timestamp())
        self.assertEqual(self.status(old, disk=False)["next_text"], "as soon as the disk is plugged in")

    def test_due_overdue_stopped_incomplete(self):
        yesterday = dict(self.fresh, last_success=at(20, 12, 31).timestamp(), last_attempt=at(20, 12, 31).timestamp())
        self.assertEqual(self.status(yesterday)["state"], "due")
        self.assertEqual(self.status(yesterday)["next_text"], "within 15 min")
        days = dict(yesterday, last_success=at(18, 12, 31).timestamp())
        self.assertEqual(self.status(days)["state"], "overdue")
        self.assertEqual(self.status(None)["state"], "overdue")
        self.assertEqual(self.status(None)["summary"], "No backup yet")
        stopped = dict(yesterday, last_attempt=at(21, 12, 40).timestamp(), last_result="stopped")
        self.assertEqual(self.status(stopped)["state"], "stopped")
        self.assertIn("retry", self.status(stopped)["next_text"])
        partial = dict(self.fresh, last_result="incomplete")
        self.assertEqual(self.status(partial)["state"], "incomplete")

    def test_the_users_time_and_errors_in_the_settings_file(self):
        s = self.status(self.fresh, settings={"time": "23:15", "keep": {"daily": "x"}})
        self.assertEqual(s["next_text"], "today 23:15")
        self.assertEqual(s["settings"]["time"], "23:15")
        self.assertEqual(len(s["settings_errors"]), 1)

    def test_tooltip(self):
        s = self.status(self.fresh)
        self.assertEqual(s["tooltip"][0], {"key": "Backup", "value": "Up to date"})
        self.assertIn({"key": "Next", "value": "tomorrow 12:30"}, s["tooltip"])

    def test_notifications_only_for_changes_for_the_worse(self):
        ok = self.status(self.fresh)
        failed = self.status(dict(self.fresh, last_attempt=at(21, 12, 50).timestamp(), last_result="exit-code",
                                  last_error="disk full"))
        self.assertEqual(bp.notifications(None, failed), [])           # first look: no noise
        self.assertEqual(bp.notifications(ok, ok), [])
        self.assertEqual(bp.notifications(ok, failed), [("critical", "Backup failed", "disk full")])
        self.assertEqual(bp.notifications(failed, failed), [])


class Form(unittest.TestCase):
    def test_the_panel_form_becomes_a_settings_file(self):
        raw, errors = bp.settings_from_form({
            "time": "3:05", "paused": "true", "keep_daily": "10", "keep_weekly": "0", "keep_monthly": " 12 ",
            "extra_paths": "~/VMs\n/srv/data/\n\n", "extra_excludes": "*.iso, *.qcow2"}, "/home/thinky")
        self.assertEqual(errors, [])
        self.assertEqual(raw["time"], "03:05")
        self.assertTrue(raw["paused"])
        self.assertEqual(raw["keep"], {"daily": 10, "weekly": 0, "monthly": 12})
        self.assertEqual(raw["extra_paths"], ["/home/thinky/VMs", "/srv/data"])
        self.assertEqual(raw["extra_excludes"], ["*.iso", "*.qcow2"])

    def test_what_does_not_parse_is_refused(self):
        _, errors = bp.settings_from_form({"time": "noon", "keep_daily": "0", "keep_weekly": "-1",
                                           "extra_paths": "relative"}, "/home/thinky")
        self.assertEqual(len(errors), 4, errors)


if __name__ == "__main__":
    unittest.main()
