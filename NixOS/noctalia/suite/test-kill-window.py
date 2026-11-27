#!/usr/bin/env python3
"""Unit tests for Noctalia interactive kill-window helper."""

import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("kill-window.py")
spec = importlib.util.spec_from_file_location("kill_window", script)
kw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kw)


class KillWindowTests(unittest.TestCase):
    def setUp(self):
        self.outputs = [
            {
                "name": "DP-1",
                "enabled": True,
                "position": {"x": 0, "y": 0},
                "logical_size": {"width": 1920, "height": 1080},
            },
            {
                "name": "HDMI-A-1",
                "enabled": True,
                "position": {"x": 1920, "y": 0},
                "logical_size": {"width": 1920, "height": 1080},
            },
            {
                "name": "eDP-1",
                "enabled": False,
                "position": {"x": 0, "y": 0},
                "logical_size": {"width": 0, "height": 0},
            },
        ]

    def test_filters_hidden_disabled_zero_and_clips_multi_monitor(self):
        windows = [
            {
                "id": "hidden-ws",
                "output": "DP-1",
                "visible": False,
                "tab_hidden": False,
                "x": 10,
                "y": 50,
                "w": 500,
                "h": 500,
            },
            {
                "id": "hidden-tab",
                "output": "DP-1",
                "visible": True,
                "tab_hidden": True,
                "x": 10,
                "y": 50,
                "w": 500,
                "h": 500,
            },
            {
                "id": "disabled-out",
                "output": "eDP-1",
                "visible": True,
                "tab_hidden": False,
                "x": 0,
                "y": 0,
                "w": 800,
                "h": 600,
            },
            {
                "id": "offscreen",
                "output": "DP-1",
                "visible": True,
                "tab_hidden": False,
                "x": 2000,
                "y": 50,
                "w": 400,
                "h": 400,
            },
            {
                "id": "clipped-hdmi",
                "output": "HDMI-A-1",
                "visible": True,
                "tab_hidden": False,
                "x": 1800,
                "y": 42,
                "w": 1000,
                "h": 1200,
            },
        ]

        entries = kw.build_slurp_entries(windows, self.outputs)
        self.assertEqual(len(entries), 1)
        self.assertEqual(
            entries[0],
            {"id": "clipped-hdmi", "output": "HDMI-A-1", "x": 1920, "y": 42, "w": 880, "h": 1038},
        )

    def test_fullscreen_occludes_same_output_but_preserves_other_output(self):
        windows = [
            {
                "id": "dp1-tiled",
                "output": "DP-1",
                "visible": True,
                "fullscreen": False,
                "floating": False,
                "x": 10,
                "y": 50,
                "w": 800,
                "h": 800,
            },
            {
                "id": "dp1-float",
                "output": "DP-1",
                "visible": True,
                "fullscreen": False,
                "floating": True,
                "x": 200,
                "y": 200,
                "w": 400,
                "h": 400,
            },
            {
                "id": "dp1-fs",
                "output": "DP-1",
                "visible": True,
                "fullscreen": True,
                "floating": True,
                "x": 0,
                "y": 0,
                "w": 1920,
                "h": 1080,
            },
            {
                "id": "hdmi-tiled",
                "output": "HDMI-A-1",
                "visible": True,
                "fullscreen": False,
                "floating": False,
                "x": 1930,
                "y": 50,
                "w": 900,
                "h": 900,
            },
        ]

        entries = kw.build_slurp_entries(windows, self.outputs)
        self.assertEqual({e["id"] for e in entries}, {"dp1-fs", "hdmi-tiled"})

    def test_stacking_order_and_full_occlusion_pruning(self):
        windows = [
            {
                "id": "pinned-top",
                "output": "DP-1",
                "visible": True,
                "pinned": True,
                "floating": True,
                "focused": False,
                "active": False,
                "x": 100,
                "y": 100,
                "w": 300,
                "h": 300,
            },
            {
                "id": "tiled-occluded",
                "output": "DP-1",
                "visible": True,
                "pinned": False,
                "floating": False,
                "focused": False,
                "active": False,
                "x": 120,
                "y": 120,
                "w": 200,
                "h": 200,
            },
            {
                "id": "tiled-visible",
                "output": "DP-1",
                "visible": True,
                "pinned": False,
                "floating": False,
                "focused": False,
                "active": False,
                "x": 10,
                "y": 50,
                "w": 900,
                "h": 900,
            },
            {
                "id": "float-focused",
                "output": "DP-1",
                "visible": True,
                "pinned": False,
                "floating": True,
                "focused": True,
                "active": True,
                "x": 400,
                "y": 400,
                "w": 300,
                "h": 300,
            },
            {
                "id": "float-unfocused",
                "output": "DP-1",
                "visible": True,
                "pinned": False,
                "floating": True,
                "focused": False,
                "active": False,
                "x": 500,
                "y": 500,
                "w": 300,
                "h": 300,
            },
        ]

        entries = kw.build_slurp_entries(windows, self.outputs)
        self.assertEqual(
            [e["id"] for e in entries],
            ["tiled-visible", "float-unfocused", "float-focused", "pinned-top"],
        )

    def test_protected_names_and_pids(self):
        for name in (
            "umbriel",
            ".umbriel-wrapped",
            "noctalia",
            ".noctalia-wrapped",
            "xwayland-satellite",
            "Xwayland",
            "systemd",
            "dbus-daemon",
            "pipewire",
        ):
            self.assertTrue(kw.is_protected_name(name), f"{name} should be protected")

        for name in ("python3.13", "xfreerdp", ".firefox-wrapped", ".kitty-wrapped", "sioyek"):
            self.assertFalse(kw.is_protected_name(name), f"{name} should not be protected")

        self.assertTrue(kw.is_protected_pid(None))
        self.assertTrue(kw.is_protected_pid(0))
        self.assertTrue(kw.is_protected_pid(1))
        self.assertTrue(kw.is_protected_pid(-5))
        self.assertTrue(kw.is_protected_pid(os.getpid()))
        self.assertTrue(kw.is_protected_pid(os.getppid()))

        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            self.assertFalse(kw.is_protected_pid(proc.pid))
        finally:
            proc.kill()
            proc.wait()

    def test_parse_proc_stat_with_spaces_and_parens(self):
        fake = "12345 (Web Content (1)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 100"
        parsed = kw.parse_proc_stat(fake)
        self.assertEqual(parsed, ("S", "987654"))

    def test_terminate_pid_sigterm_and_sigkill_escalation(self):
        normal = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            outcome = kw.terminate_pid(normal.pid, timeout=0.6, poll_interval=0.02)
            self.assertEqual(outcome, "sigterm")
            rc = normal.wait(timeout=1)
            self.assertEqual(rc, -signal.SIGTERM)
        finally:
            if normal.poll() is None:
                normal.kill()
                normal.wait()

        frozen = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(frozen.stdout.readline().strip(), "ready")
            outcome = kw.terminate_pid(frozen.pid, timeout=0.15, poll_interval=0.02)
            self.assertEqual(outcome, "sigkill")
            rc = frozen.wait(timeout=1)
            self.assertEqual(rc, -signal.SIGKILL)
        finally:
            if frozen.stdout is not None:
                frozen.stdout.close()
            if frozen.poll() is None:
                frozen.kill()
                frozen.wait()


if __name__ == "__main__":
    unittest.main()
