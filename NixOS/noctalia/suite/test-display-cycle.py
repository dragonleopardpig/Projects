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
        self.tianma_internal["enabled"] = True
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

    def test_lid_closed_while_internal_enabled_forces_external_only(self):
        self.asus_external["enabled"] = True
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=True,
            existing_sections={},
        )
        self.assertEqual(action, "apply")
        self.assertIn("Laptop lid is closed", msg)
        self.assertTrue(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"].get("enabled") is False)
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertEqual(sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "]["position"], [0, 0])

    def test_full_cycle_rotation_when_lid_open(self):
        # External -> Laptop -> Extend -> External
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
        )
        self.assertEqual((action, msg), ("apply", "Laptop display"))
        self.assertIs(sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "].get("enabled"), False)
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])

        self.asus_external["enabled"] = False
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections=sections,
        )
        self.assertEqual((action, msg), ("apply", "Extend displays"))
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])

        self.asus_external["enabled"] = True
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections=sections,
        )
        self.assertEqual((action, msg), ("apply", "External displays"))
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertIs(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"].get("enabled"), False)

    def test_relayout_with_lid_closed(self):
        # Already external-only -> no-op on relayout
        action, _, _ = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=True,
            existing_sections={},
            requested_mode="relayout",
        )
        self.assertEqual(action, "none")

        # Laptop or Extend -> force external-only on lid close
        for ext_on in (False, True):
            self.asus_external["enabled"] = ext_on
            self.tianma_internal["enabled"] = True
            action, sections, msg = cycle.calculate_next_state(
                [self.asus_external, self.tianma_internal],
                lid_closed=True,
                existing_sections={},
                requested_mode="relayout",
            )
            self.assertEqual(action, "apply")
            self.assertIn("Laptop lid is closed", msg)
            self.assertIs(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"].get("enabled"), False)
            self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])

    def test_relayout_with_lid_open(self):
        # Any valid mode (External, Laptop, Extend) -> no-op on relayout
        for ext_on, int_on in ((True, False), (False, True), (True, True)):
            self.asus_external["enabled"] = ext_on
            self.tianma_internal["enabled"] = int_on
            action, _, _ = cycle.calculate_next_state(
                [self.asus_external, self.tianma_internal],
                lid_closed=False,
                existing_sections={},
                requested_mode="relayout",
            )
            self.assertEqual(action, "none")

        # All outputs disabled -> rescue to extend
        self.asus_external["enabled"] = False
        self.tianma_internal["enabled"] = False
        action, sections, msg = cycle.calculate_next_state(
            [self.asus_external, self.tianma_internal],
            lid_closed=False,
            existing_sections={},
            requested_mode="relayout",
        )
        self.assertEqual((action, msg), ("apply", "Extend displays"))
        self.assertNotIn("enabled", sections["ASUSTek COMPUTER INC VP327Q W2LMMU003887 "])
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])

    def test_undocked_recovery_re_enables_internal_display(self):
        # Single internal connected, disabled in live outputs
        self.tianma_internal["enabled"] = False
        for req in ("", "relayout"):
            action, sections, msg = cycle.calculate_next_state(
                [self.tianma_internal],
                lid_closed=False,
                existing_sections={
                    "ASUSTek COMPUTER INC VP327Q W2LMMU003887 ": {"position": [0, 0], "scale": 1.25},
                    "Tianma Microelectronics Ltd. TL160ADMP26 Unknown": {"position": [0, 1728], "scale": 1.0, "enabled": False},
                },
                requested_mode=req,
            )
            self.assertEqual((action, msg), ("apply", "Built-in display"))
            self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])
            self.assertEqual(sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"]["position"], [0, 0])
            self.assertIn("ASUSTek COMPUTER INC VP327Q W2LMMU003887 ", sections)

        # Even if live output appears enabled while existing_sections still disables it
        self.tianma_internal["enabled"] = True
        action, sections, msg = cycle.calculate_next_state(
            [self.tianma_internal],
            lid_closed=False,
            existing_sections={
                "Tianma Microelectronics Ltd. TL160ADMP26 Unknown": {"position": [0, 0], "scale": 1.0, "enabled": False},
            },
            requested_mode="relayout",
        )
        self.assertEqual((action, msg), ("apply", "Built-in display"))
        self.assertNotIn("enabled", sections["Tianma Microelectronics Ltd. TL160ADMP26 Unknown"])

        # Desktop-only (no internal) on relayout -> no-op (does not open panel on login)
        action, _, _ = cycle.calculate_next_state(
            [self.asus_external],
            lid_closed=False,
            existing_sections={},
            requested_mode="relayout",
        )
        self.assertEqual(action, "none")


if __name__ == "__main__":
    unittest.main()
