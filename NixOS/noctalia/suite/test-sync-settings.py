#!/usr/bin/env python3
"""Regression checks for the rebuild hook that previously erased bar opacity."""

from contextlib import redirect_stderr
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import tomlkit

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("sync-settings.py")
spec = importlib.util.spec_from_file_location("sync_settings", script)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SettingsSyncTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name)
        self.settings = self.state / "noctalia/settings.toml"
        self.settings.parent.mkdir()
        self.environment = patch.dict(os.environ, {"NOCTALIA_STATE_HOME": str(self.state)})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_only_widget_order_is_removed(self):
        original = '''# GUI preferences
[bar.main]
background_opacity = 0.8 # keep my transparency
thickness = 32
margin_top = 4
radius = 12
start = ["launcher", "workspaces"]
center = [
  "active_window",
]
end = ["clock", "session"]

[bar.main.monitor."DP-1"]
background_opacity = 0.6
end = ["clock"]

[bar.secondary]
start = ["launcher"]

[lockscreen]
widgets = [{ type = "password", y = 0.8 }]

[plugins.example]
text = """A plugin string that resembles a TOML header:
[bar.main]
keep this text"""
'''
        self.settings.write_text(original)
        self.settings.chmod(0o600)
        expected = tomlkit.parse(original).unwrap()
        for key in ("start", "center", "end"):
            del expected["bar"]["main"][key]
        self.assertTrue(sync.prune_declarative_overrides())
        saved = self.settings.read_text()
        self.assertEqual(tomlkit.parse(saved).unwrap(), expected)
        self.assertIn("# keep my transparency", saved)
        self.assertIn("# GUI preferences", saved)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)
        previous_stat = self.settings.stat()
        self.assertFalse(sync.prune_declarative_overrides())
        self.assertEqual(self.settings.read_text(), saved)
        self.assertEqual(self.settings.stat().st_mtime_ns, previous_stat.st_mtime_ns)
        self.assertEqual(list(self.settings.parent.iterdir()), [self.settings])

    def test_valid_toml_key_styles(self):
        for original in (
            '["bar"."main"]\nbackground_opacity = 0.8\ncenter = ["clock"]\n',
            'bar.main.background_opacity = 0.8\nbar.main.end = ["clock"]\n',
            'bar = {main = {background_opacity = 0.8, start = ["clock"]}}\n',
        ):
            with self.subTest(original=original):
                self.settings.write_text(original)
                self.assertTrue(sync.prune_declarative_overrides())
                self.assertEqual(tomlkit.parse(self.settings.read_text()).unwrap(),
                                 {"bar": {"main": {"background_opacity": 0.8}}})

    def test_no_widget_overrides_is_a_noop(self):
        for original in ('[bar.main]\nbackground_opacity = 0.8\n',
                         '[dock]\nbackground_opacity = 0.8\n',
                         'bar = "not a table"\n'):
            with self.subTest(original=original):
                self.settings.write_text(original)
                self.assertFalse(sync.prune_declarative_overrides())
                self.assertEqual(self.settings.read_text(), original)

    def test_missing_state_is_a_noop(self):
        self.assertFalse(sync.prune_declarative_overrides())
        self.assertFalse(self.settings.exists())

    def test_invalid_toml_is_preserved(self):
        original = '[bar.main]\nbackground_opacity = 0.8\nend = ["clock"\n'
        self.settings.write_text(original)
        with redirect_stderr(io.StringIO()) as errors:
            self.assertFalse(sync.prune_declarative_overrides())
        self.assertIn("unchanged", errors.getvalue())
        self.assertEqual(self.settings.read_text(), original)

    def test_failed_replace_leaves_original_intact(self):
        original = '[bar.main]\nbackground_opacity = 0.8\ncenter = ["clock"]\n'
        self.settings.write_text(original)
        with patch.object(Path, "replace", side_effect=OSError("read-only filesystem")):
            with redirect_stderr(io.StringIO()):
                self.assertFalse(sync.prune_declarative_overrides())
        self.assertEqual(self.settings.read_text(), original)
        self.assertEqual(list(self.settings.parent.iterdir()), [self.settings])

    def test_concurrent_gui_save_is_preserved(self):
        self.settings.write_text('[bar.main]\nbackground_opacity = 0.8\ncenter = ["clock"]\n')
        newer = '[bar.main]\nbackground_opacity = 0.7\n'
        serialize = tomlkit.dumps

        def gui_save(document):
            self.settings.write_text(newer)
            return serialize(document)

        with patch.object(tomlkit, "dumps", side_effect=gui_save):
            with redirect_stderr(io.StringIO()):
                self.assertFalse(sync.prune_declarative_overrides())
        self.assertEqual(self.settings.read_text(), newer)
        self.assertEqual(list(self.settings.parent.iterdir()), [self.settings])

    def test_xdg_state_home_is_respected(self):
        original = '[bar.main]\nbackground_opacity = 0.8\nend = ["clock"]\n'
        self.settings.write_text(original)
        self.settings.parent.rename(self.state / "noctalia-suite")
        profile = self.state / "noctalia-suite"
        (profile / "noctalia").mkdir()
        (profile / "settings.toml").rename(profile / "noctalia/settings.toml")
        with patch.dict(os.environ, {"NOCTALIA_STATE_HOME": "", "XDG_STATE_HOME": str(self.state)}):
            self.assertTrue(sync.prune_declarative_overrides())
        self.assertEqual(tomlkit.parse((profile / "noctalia/settings.toml").read_text()).unwrap(),
                         {"bar": {"main": {"background_opacity": 0.8}}})


if __name__ == "__main__":
    unittest.main()
