#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("winapps_apps", Path(__file__).with_name("winapps-apps.py"))
apps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apps)


class ShortcutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.applications = root / "applications"
        self.applications.mkdir()
        self.data = root / "winapps"
        icon = root / "windows.svg"
        icon.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
        for name, value in {
            "DATA": self.data, "APPLICATIONS": self.applications,
            "STATE": root / "state/shortcuts.json", "VISIBILITY": root / "state/visibility.json",
            "DEFAULT_ICON": icon, "COMMAND": "/nix/store/test-winapps/bin/winapps",
        }.items():
            replace = patch.object(apps, name, value)
            replace.start()
            self.addCleanup(replace.stop)
        commands = patch.object(apps.shutil, "which", return_value=None)
        commands.start()
        self.addCleanup(commands.stop)

    def native(self, key, name, executable, filename=None):
        directory = self.data / "apps" / key
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "info").write_text(apps.info_text(name, executable))
        desktop = self.applications / (filename or key + ".desktop")
        desktop.write_text(
            "[Desktop Entry]\nType=Application\n"
            f"Name={name}\nExec=/nix/store/old-winapps/bin/winapps {key} %F\n"
            "MimeType=application/test;\n"
            "[Desktop Action Edit]\nName=Edit\nExec=editor\n"
        )
        return desktop

    def test_unticking_hides_existing_office_and_preserves_metadata(self):
        desktop = self.native("excel-o365", "Microsoft Excel", r"C:\Office\EXCEL.EXE")
        catalog = [{"name": "Excel", "app_id": "Microsoft.Office.EXCEL.EXE.15"}]
        apps.apply_selection(catalog, set())
        self.assertIn("NoDisplay=true\n[Desktop Action Edit]", desktop.read_text())
        self.assertIn("MimeType=application/test;", desktop.read_text())
        self.assertTrue((self.data / "apps/excel-o365/info").exists())
        self.assertFalse(apps.existing_shortcuts()[desktop.name]["visible"])
        apps.apply_selection(catalog, {catalog[0]["app_id"]})
        self.assertTrue(apps.existing_shortcuts()[desktop.name]["visible"])
        self.assertFalse(apps.STATE.exists())

    def test_hidden_choices_survive_a_launcher_rewrite(self):
        desktop = self.native("word-o365", "Word", r"C:\Office\WINWORD.EXE")
        original = desktop.read_text()
        apps.apply_selection([], set())
        desktop.write_text(original)
        apps.sync_visibility()
        self.assertFalse(apps.existing_shortcuts()[desktop.name]["visible"])

    def test_hide_all_covers_unscanned_apps_and_duplicate_entries(self):
        first = self.native("cmd", "Command Prompt", r"C:\Windows\cmd.exe")
        second = self.native("cmd", "Command Prompt", r"C:\Windows\cmd.exe", "old-cmd.desktop")
        apps.apply_selection([], set())
        for desktop in (first, second):
            self.assertIn("NoDisplay=true", desktop.read_text())
        self.assertEqual(len(json.loads(apps.VISIBILITY.read_text())), 2)

    def test_windows_linux_and_managed_desktop_entries_are_not_changed(self):
        windows = self.native("windows", "Windows", r"C:\Windows\explorer.exe")
        native_linux = self.applications / "linux.desktop"
        native_linux.write_text("[Desktop Entry]\nName=Microsoft Tool\nExec=linux-tool\n")
        symlink = self.applications / "symlink.desktop"
        symlink.symlink_to(windows)
        malformed = self.applications / "malformed.desktop"
        malformed.write_text("invalid unrelated desktop file")
        originals = {path: path.read_text() for path in (windows, native_linux, malformed)}
        apps.apply_selection([], set())
        for path, contents in originals.items():
            self.assertEqual(path.read_text(), contents)
        self.assertTrue(symlink.is_symlink())

    def test_classic_outlook_does_not_capture_the_packaged_outlook_choice(self):
        self.native("outlook-o365", "Microsoft Outlook", r"C:\Office\OUTLOOK.EXE")
        catalog = [
            {"name": "Outlook", "app_id": "Microsoft.OutlookForWindows_xyz!Outlook"},
            {"name": "Outlook (classic)", "app_id": "Microsoft.Office.OUTLOOK.EXE.15"},
        ]
        choices = apps.selection_apps(catalog, apps.existing_shortcuts())
        self.assertEqual(choices[0]["shortcuts"], [])
        self.assertEqual(choices[1]["shortcuts"], ["outlook-o365.desktop"])

    def test_new_picker_shortcuts_still_install_and_remove(self):
        app = {"name": "Microsoft Teams", "app_id": "MSTeams_xyz!MSTeams"}
        apps.apply_selection([app], {app["app_id"]})
        key = apps.app_key(app["app_id"])
        desktop = self.applications / f"winapps-{key}.desktop"
        self.assertTrue(desktop.exists())
        self.assertEqual(apps.existing_shortcuts(), {})
        apps.apply_selection([app], set())
        self.assertFalse(desktop.exists())
        self.assertEqual(apps.load_state(), {})

    def test_checklist_represents_existing_shortcuts_and_applies_unticking(self):
        desktop = self.native("access", "Access", r"C:\Office\MSACCESS.EXE")
        catalog = {"apps": [{"name": "Access", "app_id": "Microsoft.Office.MSACCESS.EXE.15"}]}
        with patch.object(apps, "load_catalog", return_value=catalog), patch.object(
            apps.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")
        ) as run:
            apps.gui()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("Existing WinApps shortcut", arguments)
        self.assertIn("TRUE", arguments)
        self.assertFalse(apps.existing_shortcuts()[desktop.name]["visible"])


if __name__ == "__main__":
    unittest.main()
