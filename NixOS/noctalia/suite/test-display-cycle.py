#!/usr/bin/env python3
"""Unit tests for Noctalia display cycle logic."""

import importlib.util
from pathlib import Path
import sys
import unittest

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("display-cycle.py")
spec = importlib.util.spec_from_file_location("display_cycle", script)
cycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cycle)


class DisplayCycleTests(unittest.TestCase):
    def setUp(self):
        self.asus_external = {
            "name": "HDMI-A-1",
            "config_name": "ASUSTek COMPUTER INC VP327Q W2LMMU003887 ",
            "enabled": True,
            "focused": True,
            "scale": 1.25,
            "modes": [{"width": 3840, "height": 2160, "preferred": True}],
        }
        self.tianma_internal = {
            "name": "eDP-1",
            "config_name": "Tianma Microelectronics Ltd. TL160ADMP26 Unknown",
            "enabled": False,
            "focused": False,
            "scale": 1.0,
            "modes": [{"width": 2560, "height": 1600, "preferred": True}],
        }

    def test_single_display_toggles_panel(self):
        action, _, _ = cycle.calculate_next_state(
            [self.tianma_internal], lid_closed=False, existing_sections={}
        )
        self.assertEqual(action, "toggle_panel")

    def test_lid_closed_prevents_cycling_to_laptop(self):
        action, _, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=True,
            existing_sections={},
        )
        self.assertEqual(action, "lid_closed_warning")
        self.assertIn("Laptop lid is closed", msg)

    def test_cycle_from_external_to_laptop_when_lid_open(self):
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={"ASUSTek COMPUTER INC VP327Q W2LMMU003887 ": {"scale": 1.25}},
        )
        self.assertEqual(action, "apply")
        self.assertEqual(msg, "Laptop display")
        self.assertTrue(sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "].get("enabled") is False)
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])
        self.assertEqual(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]["position"], [0, 0])

    def test_cycle_from_laptop_to_extend(self):
        self.asus_external["enabled"] = False
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
        )
        self.assertEqual(action, "apply")
        self.assertEqual(msg, "Extend displays")
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])
        self.assertEqual(sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]["position"], [0, 0])
        # External is 2160 / 1.25 = 1728 height, so internal is at [0, 1728]
        self.assertEqual(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]["position"], [0, 1728])

    def test_cycle_from_extend_to_external(self):
        self.asus_external["enabled"] = True
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
        )
        self.assertEqual(action, "apply")
        self.assertEqual(msg, "External displays")
        self.assertTrue(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"].get("enabled") is False)
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertEqual(sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]["position"], [0, 0])

    def test_explicit_mode_requested(self):
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
            requested_mode="extend",
        )
        self.assertEqual(action, "apply")
        self.assertEqual(msg, "Extend displays")

    def test_input_action_returned(self):
        action, _, _ = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
            requested_mode="input",
        )
        self.assertEqual(action, "input")

    def test_render_outputs_toml(self):
        sections = {
            "ASUSTek COMPUTER INC VP327Q W2LMMU003887 ": {"position": [0, 0], "scale": 1.25},
            "Tianma Microelectronics Ltd. TL160ADMP26 Unknown": {"enabled": False},
        }
        rendered = cycle.render_outputs_toml(sections)
        self.assertIn('[output."ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]', rendered)
        self.assertIn("position = [0, 0]", rendered)
        self.assertIn("scale = 1.25", rendered)
        self.assertIn('[output."Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]', rendered)
        self.assertIn("enabled = false", rendered)


if __name__ == "__main__":
    unittest.main()
