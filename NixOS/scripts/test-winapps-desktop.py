#!/usr/bin/env python3
"""Check session selection and viewer reuse without launching a VM or GUI."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("winapps_memory", Path(__file__).with_name("winapps-memory.py"))
winapps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(winapps)


class DesktopTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(winapps.os.environ, {
            "XDG_CURRENT_DESKTOP": "umbriel", "UMBRIEL_SOCKET": "/private/umbriel.sock",
            "HYPRLAND_INSTANCE_SIGNATURE": "stale-hyprland-session",
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        commands = patch.object(winapps.shutil, "which", side_effect=lambda name: "/bin/" + name)
        commands.start()
        self.addCleanup(commands.stop)

    def test_active_compositor_wins_when_both_are_installed(self):
        self.assertEqual(winapps.desktop_backend(), "umbriel")
        winapps.os.environ["XDG_CURRENT_DESKTOP"] = "Hyprland"
        self.assertEqual(winapps.desktop_backend(), "hyprland")

    def test_installed_command_does_not_identify_a_running_desktop(self):
        winapps.os.environ.pop("UMBRIEL_SOCKET")
        self.assertIsNone(winapps.desktop_backend())
        winapps.os.environ["XDG_CURRENT_DESKTOP"] = "sway"
        self.assertIsNone(winapps.desktop_backend())

    def test_umbriel_query_uses_app_id(self):
        result = subprocess.CompletedProcess([], 0, '[{"app_id":"kitty"},{"app_id":"Microsoft Windows","id":"abcd"}]')
        with patch.object(winapps.subprocess, "run", return_value=result) as run:
            self.assertEqual(winapps.windows_viewers(), [{"app_id": "Microsoft Windows", "id": "abcd"}])
            self.assertEqual(run.call_args.args[0], ["umbriel", "windows", "--json"])

    def test_fullscreen_is_set_without_toggling_an_existing_fullscreen_viewer(self):
        viewer = {"id": "abcd", "fullscreen": True, "workspace": "HDMI-A-1:7", "visible": True}
        inventory = '[{"id":"HDMI-A-1:7","index":2,"output":"HDMI-A-1"}]'
        def response(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, inventory if command[1] == "workspaces" else "")
        with patch.object(winapps, "windows_viewers", return_value=[viewer]), patch.object(
            winapps.subprocess, "run", side_effect=response
        ) as run:
            winapps.focus_windows(viewer, True)
            self.assertEqual([call.args[0] for call in run.call_args_list], [
                ["umbriel", "workspaces", "--json"],
                ["umbriel", "msg", "workspace-switch:2/HDMI-A-1"],
                ["umbriel", "msg", "window-focus:abcd"],
            ])
            winapps.focus_windows(viewer, False)
            self.assertEqual(run.call_args.args[0], ["umbriel", "msg", "window-toggle-fullscreen"])

    def test_hidden_viewer_is_not_reported_as_ready(self):
        viewer = {"id": "abcd", "workspace": "HDMI-A-1:7", "visible": False}
        inventory = '[{"id":"HDMI-A-1:7","index":2,"output":"HDMI-A-1"}]'
        def response(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, inventory if command[1] == "workspaces" else "")
        with patch.object(winapps, "windows_viewers", return_value=[viewer]), patch.object(
            winapps.subprocess, "run", side_effect=response
        ), self.assertRaisesRegex(ValueError, "not visible"):
            winapps.focus_windows(viewer, False)

    def test_reopening_an_existing_viewer_does_not_start_another_connection(self):
        viewer = {"id": "abcd", "fullscreen": False}
        with patch.object(winapps, "validate_settings", return_value=(4, 4, 100, False)), patch.object(
            winapps, "windows_viewers", return_value=[viewer]
        ), patch.object(winapps, "container_state", return_value="running"), patch.object(
            winapps, "focus_windows"
        ) as focus, patch.object(winapps.subprocess, "Popen") as launch:
            message = winapps.open_windows(selection=(4, 4, 100, False))
            self.assertIn("Reused", message)
            focus.assert_called_once_with(viewer, False)
            launch.assert_not_called()

    def test_umbriel_enters_fullscreen_after_mapping_instead_of_using_freerdp_f(self):
        viewer = {"id": "abcd", "fullscreen": False}
        for backend, client_fullscreen in (("umbriel", "0"), ("hyprland", "1")):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory() as directory, patch.object(
                winapps, "LAUNCH_LOG", Path(directory) / "launch.log"
            ), patch.object(winapps, "desktop_backend", return_value=backend), patch.object(
                winapps, "validate_settings", return_value=(4, 4, 125, True)
            ), patch.object(winapps, "windows_viewers", side_effect=[[], [viewer]]), patch.object(
                winapps, "focus_windows"
            ) as focus, patch.object(winapps.subprocess, "Popen") as launch:
                self.assertIn("ready", winapps.open_windows(selection=(4, 4, 125, True)))
                environment = launch.call_args.kwargs["env"]
                self.assertEqual(environment["WINAPPS_FULLSCREEN"], client_fullscreen)
                self.assertEqual(environment["WINAPPS_DESKTOP_SCALE"], "125")
                focus.assert_called_once_with(viewer, True)

    def test_hyprland_focus_behavior_is_preserved(self):
        winapps.os.environ["XDG_CURRENT_DESKTOP"] = "Hyprland"
        result = subprocess.CompletedProcess([], 0, "ok\nok\n")
        with patch.object(winapps.subprocess, "run", return_value=result) as run:
            winapps.focus_windows({"address": "0x1234"}, True)
            self.assertEqual(run.call_args.args[0][0], "hyprctl")
            self.assertIn("fullscreenstate 2 2 set", run.call_args.args[0][2])


if __name__ == "__main__":
    unittest.main()
