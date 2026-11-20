#!/usr/bin/env python3
"""Unit tests for Noctalia rsync-status helper."""

from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    script = Path(sys.argv.pop(1))
else:
    script = Path(__file__).with_name("rsync-status.py")
spec = importlib.util.spec_from_file_location("rsync_status", script)
rsync_status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rsync_status)

NOW = datetime(2026, 11, 20, 15, 30, 0)


class RsyncStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.state = root / "state/sync-projects"
        self.cache = root / "cache"
        self.runtime = root / "runtime"
        self.target = root / "external/nixos/home/thinky"
        self.script = self.home / ".local/bin/sync-projects"

        for directory in (
            self.home / "Projects",
            self.home / "Documents/Scramble Public",
            self.state / "targets",
            self.cache,
            self.runtime,
            self.script.parent,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        self.script.write_text('#!/usr/bin/env bash\nTARGET="' + str(self.target) + '"\n', encoding="utf-8")
        self.script.chmod(0o755)

    def _snapshot(self, **kwargs):
        return rsync_status.build_snapshot(
            home=self.home,
            state_dir=self.state,
            cache_dir=self.cache,
            runtime_dir=self.runtime,
            script_path=self.script,
            target_root=self.target,
            now_dt=NOW,
            live_pids=kwargs.pop("live_pids", []),
            **kwargs,
        )

    def test_unconfigured_host_without_script_or_log(self):
        self.script.unlink()
        snap = self._snapshot()
        self.assertTrue(snap["available"])
        self.assertEqual(snap["state"], "unconfigured")
        self.assertFalse(snap["script_exists"])
        self.assertFalse(snap["can_sync"])

    def test_legacy_log_fallback_when_disk_unmounted(self):
        (self.cache / "sync-projects.log").write_text(
            "2026-11-19 16:22:20 start\n"
            "2026-11-19 16:22:20 done (rsync status 0)\n"
            "2026-11-20 14:51:03 skipped: the other disk is not mounted\n",
            encoding="utf-8",
        )
        snap = self._snapshot()
        self.assertEqual(snap["state"], "unmounted")
        self.assertFalse(snap["disk_mounted"])
        self.assertFalse(snap["can_sync"])
        self.assertEqual(snap["last_run_text"], "Last attempt: 14:51 · skipped (disk unmounted)")

        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["state"], "ok")
        self.assertEqual(by_id["projects"]["line_status"], "OK (0) · Nov 19 16:22")
        self.assertEqual(by_id["scramble-public"]["state"], "ok")
        self.assertEqual(by_id["scramble-references"]["state"], "absent")
        self.assertEqual(by_id["scramble-references"]["line_status"], "No local folder")
        self.assertEqual(by_id["trident-optics-attachment"]["state"], "absent")

    def test_mounted_disk_and_structured_target_states(self):
        (self.target / "Projects").mkdir(parents=True)
        # Ensure target reports a distinct device ID from home for this test.
        with patch.object(rsync_status, "_check_mount", return_value=(True, False)):
            (self.state / "targets/projects.sync.json").write_text(
                json.dumps({"id": "projects", "exit_code": 0, "timestamp": "2026-11-20 15:25:00", "epoch": 1, "duration_sec": 3}),
                encoding="utf-8",
            )
            (self.state / "targets/scramble-public.sync.json").write_text(
                json.dumps({"id": "scramble-public", "exit_code": 0, "timestamp": "2026-11-20 15:25:04", "epoch": 2, "duration_sec": 1}),
                encoding="utf-8",
            )
            snap = self._snapshot()
        self.assertEqual(snap["state"], "ok")
        self.assertTrue(snap["disk_mounted"])
        self.assertTrue(snap["can_sync"])
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["line_status"], "OK (0) · 15:25")
        self.assertEqual(by_id["scramble-public"]["line_status"], "OK (0) · 15:25")

    def test_error_persists_even_when_disk_unmounted(self):
        (self.state / "targets/projects.sync.json").write_text(
            json.dumps({"id": "projects", "exit_code": 0, "timestamp": "2026-11-20 15:00:00", "epoch": 1, "duration_sec": 2}),
            encoding="utf-8",
        )
        (self.state / "targets/scramble-public.sync.json").write_text(
            json.dumps({"id": "scramble-public", "exit_code": 23, "timestamp": "2026-11-20 15:00:05", "epoch": 2, "duration_sec": 1}),
            encoding="utf-8",
        )
        snap = self._snapshot()
        self.assertEqual(snap["state"], "error")
        self.assertIn("Scramble Public", snap["summary"])
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["scramble-public"]["state"], "error")
        self.assertEqual(by_id["scramble-public"]["line_status"], "Error (23) · 15:00")

    def test_active_sync_and_stale_pid_handling(self):
        run_epoch = int(datetime(2026, 11, 20, 15, 29, 50).timestamp())
        (self.state / "run.json").write_text(
            json.dumps({"state": "syncing", "pid": os.getpid(), "dry_run": False, "timestamp": "2026-11-20 15:29:50", "epoch": run_epoch}),
            encoding="utf-8",
        )
        (self.state / "targets/projects.active.json").write_text(
            json.dumps({"id": "projects", "pid": os.getpid(), "dry_run": False, "started_at": "2026-11-20 15:29:50", "started_epoch": run_epoch}),
            encoding="utf-8",
        )
        snap = self._snapshot()
        self.assertEqual(snap["state"], "syncing")
        self.assertTrue(snap["syncing"])
        self.assertFalse(snap["can_sync"])
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["state"], "syncing")
        self.assertEqual(by_id["projects"]["line_status"], "Syncing... (10s)")
        self.assertEqual(by_id["scramble-public"]["state"], "queued")

        # Dead PID in active.json must not remain stuck in syncing.
        (self.state / "run.json").write_text(
            json.dumps({"state": "syncing", "pid": 99999999, "dry_run": False, "timestamp": "2026-11-20 15:29:50", "epoch": run_epoch}),
            encoding="utf-8",
        )
        (self.state / "targets/projects.active.json").write_text(
            json.dumps({"id": "projects", "pid": 99999999, "dry_run": False, "started_at": "2026-11-20 15:29:50", "started_epoch": run_epoch}),
            encoding="utf-8",
        )
        stale_snap = self._snapshot()
        self.assertFalse(stale_snap["syncing"])
        self.assertNotEqual(stale_snap["state"], "syncing")

    def test_dry_run_does_not_overwrite_real_sync(self):
        (self.cache / "sync-projects.log").write_text(
            "2026-11-19 16:00:00 start\n"
            "2026-11-19 16:00:02 done (rsync status 0)\n"
            "2026-11-20 15:10:00 start (dry run)\n"
            "2026-11-20 15:10:01 done (rsync status 0)\n",
            encoding="utf-8",
        )
        snap = self._snapshot()
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["state"], "ok")
        self.assertEqual(by_id["projects"]["line_status"], "OK (0) · Nov 19 16:00")
        self.assertEqual(snap["last_run_text"], "Last run: 15:10 · exit 0 · dry run")

    def test_same_disk_reports_error(self):
        (self.target / "Projects").mkdir(parents=True)
        snap = self._snapshot()
        self.assertTrue(snap["same_disk"])
        self.assertFalse(snap["disk_mounted"])
        self.assertEqual(snap["state"], "error")


if __name__ == "__main__":
    unittest.main()
