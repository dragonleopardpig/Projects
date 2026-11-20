"""Unit tests for Noctalia rclone-status helper."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    SCRIPT_PATH = Path(sys.argv.pop(1))
else:
    SCRIPT_PATH = Path(__file__).with_name("rclone-status.py")


def load_module():
    spec = importlib.util.spec_from_file_location("rclone_status_helper", SCRIPT_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class RcloneStatusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir(parents=True)
        self.proc = Path(self.tmp.name) / "proc"
        self.proc.mkdir(parents=True)
        self.mounts_file = Path(self.tmp.name) / "mounts"
        self.conf = self.home / ".config/rclone/rclone.conf"
        self.conf.parent.mkdir(parents=True)
        self.gui_bin = self.home / "rclone-control"
        self.gui_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.gui_bin.chmod(0o755)

        self.env_patch = {
            "RCLONE_STATUS_HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "RCLONE_CONFIG": str(self.conf),
            "RCLONE_STATUS_PROC_ROOT": str(self.proc),
            "RCLONE_STATUS_MOUNTS_FILE": str(self.mounts_file),
            "RCLONE_STATUS_SKIP_SYSTEMD": "1",
            "RCLONE_CONTROL_BIN": str(self.gui_bin),
        }
        self._old_env = {k: os.environ.get(k) for k in self.env_patch}
        os.environ.update(self.env_patch)

    def tearDown(self) -> None:
        for k, v in self._old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def test_empty_config_reports_unconfigured(self) -> None:
        self.mounts_file.write_text("", encoding="utf-8")
        snap = self.mod.build_snapshot()
        self.assertEqual(snap["state"], "unconfigured")
        self.assertTrue(snap["gui_available"])
        self.assertEqual(snap["remotes"], [])

    def test_remotes_custom_mount_and_active_transfer(self) -> None:
        self.conf.write_text(
            "[gdrive]\ntype = drive\n\n[vault]\ntype = crypt\nremote = gdrive:Secret\n",
            encoding="utf-8",
        )
        mount_dir = self.home / "GDrive"
        self.mounts_file.write_text(
            f"gdrive: {mount_dir} fuse.rclone rw,nosuid,nodev 0 0\n",
            encoding="utf-8",
        )
        # Simulated mounted rclone process and an active rclone copy job
        p1 = self.proc / "999991"
        p1.mkdir()
        (p1 / "cmdline").write_bytes(b"rclone\0mount\0gdrive:\0" + str(mount_dir).encode() + b"\0--vfs-cache-mode=full\0")

        snap = self.mod.build_snapshot()
        self.assertEqual(snap["state"], "mounted")
        self.assertEqual(snap["badge"], "1 Mounted")
        self.assertEqual(len(snap["remotes"]), 2)
        self.assertTrue(next(r for r in snap["remotes"] if r["name"] == "gdrive")["mounted"])
        self.assertEqual(len(snap["mounts"]), 1)
        self.assertEqual(snap["mounts"][0]["mountpoint"], str(mount_dir))

        p2 = self.proc / "999992"
        p2.mkdir()
        (p2 / "cmdline").write_bytes(b"rclone\0copy\0/tmp/a\0vault:Backup\0")
        snap2 = self.mod.build_snapshot()
        self.assertEqual(snap2["state"], "syncing")
        self.assertEqual(len(snap2["active_jobs"]), 1)
        self.assertEqual(snap2["active_jobs"][0]["op"], "copy")


if __name__ == "__main__":
    unittest.main()
