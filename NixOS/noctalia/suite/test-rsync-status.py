#!/usr/bin/env python3
"""Unit tests for Noctalia rsync-status helper, configuration CRUD, and rsync runner."""

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
        self.cfg_dir = root / "config/sync-projects"
        self.state = root / "state/sync-projects"
        self.cache = root / "cache"
        self.runtime = root / "runtime"
        self.target = root / "external/nixos/home/thinky"
        self.script = self.home / ".local/bin/sync-projects"

        for directory in (
            self.home / "Projects",
            self.home / "Documents/Scramble Public",
            self.cfg_dir,
            self.state / "targets",
            self.cache,
            self.runtime,
            self.script.parent,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        self.script.write_text('#!/usr/bin/env bash\nTARGET="' + str(self.target) + '"\n', encoding="utf-8")
        self.script.chmod(0o755)
        self.paths = rsync_status._resolve_paths(
            home=self.home,
            config_dir=self.cfg_dir,
            state_dir=self.state,
            cache_dir=self.cache,
            runtime_dir=self.runtime,
            script_path=self.script,
        )

    def _snapshot(self, **kwargs):
        return rsync_status.build_snapshot(
            home=self.home,
            config_dir=self.cfg_dir,
            state_dir=self.state,
            cache_dir=self.cache,
            runtime_dir=self.runtime,
            script_path=self.script,
            target_root=self.target,
            now_dt=NOW,
            live_pids=kwargs.pop("live_pids", []),
            **kwargs,
        )

    def test_fresh_host_without_script_or_log_starts_unconfigured(self):
        self.script.unlink()
        snap = self._snapshot()
        self.assertTrue(snap["available"])
        self.assertEqual(snap["state"], "unconfigured")
        self.assertFalse(snap["configured"])
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
        self.assertEqual(snap["last_run_text"], "Last attempt: 14:51 · skipped (disk unmounted)")

        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["state"], "ok")
        self.assertEqual(by_id["projects"]["line_status"], "OK (0) · Nov 19 16:22")
        self.assertEqual(by_id["scramble-references"]["state"], "absent")

    def test_mounted_disk_and_structured_target_states(self):
        (self.target / "Projects").mkdir(parents=True)
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
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["projects"]["line_status"], "Syncing... (10s)")
        self.assertEqual(by_id["scramble-public"]["state"], "queued")

        (self.state / "run.json").write_text(
            json.dumps({"state": "syncing", "pid": 99999999, "dry_run": False, "timestamp": "2026-11-20 15:29:50", "epoch": run_epoch}),
            encoding="utf-8",
        )
        (self.state / "targets/projects.active.json").write_text(
            json.dumps({"id": "projects", "pid": 99999999, "dry_run": False, "started_at": "2026-11-20 15:29:50", "started_epoch": run_epoch}),
            encoding="utf-8",
        )
        self.assertFalse(self._snapshot()["syncing"])

    def test_crud_targets_and_settings(self):
        rsync_status.save_target({
            "name": "Notes",
            "source": str(self.home / "Notes"),
            "dest": "Notes",
            "enabled": True,
            "delete": False,
            "excludes": "*.bak, tmp/",
        }, paths=self.paths)
        cfg = rsync_status.load_or_seed_config(self.paths)
        notes = next(t for t in cfg["targets"] if t["id"] == "notes")
        self.assertFalse(notes["delete"])
        self.assertEqual(notes["excludes"], ["*.bak", "tmp/"])

        rsync_status.move_target("notes", "up", paths=self.paths)
        cfg = rsync_status.load_or_seed_config(self.paths)
        self.assertEqual(cfg["targets"][-2]["id"], "notes")

        rsync_status.toggle_target("notes", paths=self.paths)
        snap = self._snapshot()
        by_id = {row["id"]: row for row in snap["targets"]}
        self.assertEqual(by_id["notes"]["state"], "disabled")

        rsync_status.save_settings({"target_root": "/mnt/usb/backup", "excludes": ".git/\n*.log"}, paths=self.paths)
        cfg = rsync_status.load_or_seed_config(self.paths)
        self.assertEqual(cfg["target_root"], "/mnt/usb/backup")
        self.assertEqual(cfg["excludes"], [".git/", "*.log"])

        rsync_status.delete_target("notes", paths=self.paths)
        cfg = rsync_status.load_or_seed_config(self.paths)
        self.assertFalse(any(t["id"] == "notes" for t in cfg["targets"]))

    def test_run_sync_uses_config_targets_and_excludes(self):
        (self.home / "Projects/keep.txt").write_text("keep\n")
        (self.home / "Projects/skip.bak").write_text("skip\n")
        (self.target / "Projects").mkdir(parents=True)
        rsync_status.save_settings({"target_root": str(self.target), "excludes": ["*.bak"]}, paths=self.paths)
        # Mock subprocess.run for rsync inside sandbox if rsync isn't needed, or run real rsync if present.
        with patch.object(rsync_status.subprocess, "run") as mock_run:
            mock_run.return_value.returncode = 0
            rc = rsync_status.run_sync(
                dry_run=False,
                target_id="projects",
                home=self.home,
                config_dir=self.cfg_dir,
                state_dir=self.state,
                cache_dir=self.cache,
                runtime_dir=self.runtime,
                script_path=self.script,
                same_disk_guard=False,
            )
            self.assertEqual(rc, 0)
            called_cmd = mock_run.call_args[0][0]
            self.assertIn("--delete", called_cmd)
            self.assertIn("--exclude=*.bak", called_cmd)


if __name__ == "__main__":
    unittest.main()
