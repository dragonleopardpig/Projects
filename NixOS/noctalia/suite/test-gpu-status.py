#!/usr/bin/env python3
"""Unit tests for Noctalia GPU & active monitor status helper."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("gpu-status.py")
spec = importlib.util.spec_from_file_location("gpu_status", script)
gpu_status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpu_status)


class GpuStatusTests(unittest.TestCase):
    def _setup_hybrid_sysfs(self, root: Path) -> tuple[Path, Path, Path]:
        drm = root / "drm"
        nv_proc = root / "nvidia_gpus"
        lid_dir = root / "lid" / "LID0"
        lid_dir.mkdir(parents=True)
        (lid_dir / "state").write_text("state:      open\n", encoding="utf-8")

        # card1: NVIDIA RTX 5070 Ti driving HDMI-A-1
        c1 = drm / "card1" / "device"
        (c1 / "drm" / "renderD128").mkdir(parents=True)
        (c1 / "vendor").write_text("0x10de\n", encoding="utf-8")
        (c1 / "boot_vga").write_text("0\n", encoding="utf-8")
        (c1 / "uevent").write_text("DRIVER=nvidia\nPCI_SLOT_NAME=0000:01:00.0\n", encoding="utf-8")
        c1_hdmi = drm / "card1-HDMI-A-1"
        c1_hdmi.mkdir(parents=True)
        (c1_hdmi / "status").write_text("connected\n", encoding="utf-8")
        (nv_proc / "0000:01:00.0").mkdir(parents=True)
        (nv_proc / "0000:01:00.0" / "information").write_text(
            "Model: \t\t NVIDIA GeForce RTX 5070 Ti Laptop GPU\n", encoding="utf-8"
        )

        # card2: Intel i915 driving eDP-1
        c2 = drm / "card2" / "device"
        (c2 / "drm" / "renderD129").mkdir(parents=True)
        (c2 / "vendor").write_text("0x8086\n", encoding="utf-8")
        (c2 / "boot_vga").write_text("1\n", encoding="utf-8")
        (c2 / "uevent").write_text("DRIVER=i915\nPCI_SLOT_NAME=0000:00:02.0\n", encoding="utf-8")
        c2_edp = drm / "card2-eDP-1"
        c2_edp.mkdir(parents=True)
        (c2_edp / "status").write_text("connected\n", encoding="utf-8")

        return drm, nv_proc, lid_dir / "state"

    def _outputs(self, hdmi_on: bool, edp_on: bool) -> list[dict]:
        return [
            {
                "name": "HDMI-A-1",
                "enabled": hdmi_on,
                "focused": hdmi_on,
                "modes": [{"width": 3840, "height": 2160, "refresh_mhz": 60000, "current": True}],
            },
            {
                "name": "eDP-1",
                "enabled": edp_on,
                "focused": edp_on and not hdmi_on,
                "modes": [{"width": 2560, "height": 1600, "refresh_mhz": 240000, "current": True}],
            },
        ]

    def test_clamshell_nvidia_direct_external(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm, nv_proc, lid = self._setup_hybrid_sysfs(Path(tmp))
            lid.write_text("state:      closed\n", encoding="utf-8")
            snap = gpu_status.build_snapshot(
                self._outputs(hdmi_on=True, edp_on=False),
                drm_sysfs=str(drm),
                nvidia_proc=str(nv_proc),
                lid_glob=str(lid),
                wlr_render="/dev/dri/renderD128",
                wlr_drm="/dev/dri/card1:/dev/dri/card2",
            )
            self.assertTrue(snap["available"])
            self.assertEqual(snap["state"], "nvidia")
            self.assertEqual(snap["text"], "NV · HDMI-A-1")
            self.assertEqual(snap["renderer"]["model"], "NVIDIA GeForce RTX 5070 Ti Laptop GPU")
            self.assertIn("Direct", snap["tooltip"][1]["value"])

    def test_intel_direct_laptop_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm, nv_proc, lid = self._setup_hybrid_sysfs(Path(tmp))
            snap = gpu_status.build_snapshot(
                self._outputs(hdmi_on=False, edp_on=True),
                drm_sysfs=str(drm),
                nvidia_proc=str(nv_proc),
                lid_glob=str(lid),
                wlr_render="/dev/dri/renderD129",
                wlr_drm="/dev/dri/card2:/dev/dri/card1",
            )
            self.assertEqual(snap["state"], "intel")
            self.assertEqual(snap["text"], "Intel · eDP-1")

    def test_intel_hybrid_external_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm, nv_proc, lid = self._setup_hybrid_sysfs(Path(tmp))
            snap = gpu_status.build_snapshot(
                self._outputs(hdmi_on=True, edp_on=False),
                drm_sysfs=str(drm),
                nvidia_proc=str(nv_proc),
                lid_glob=str(lid),
                wlr_render="/dev/dri/renderD129",
                wlr_drm="/dev/dri/card2:/dev/dri/card1",
            )
            self.assertEqual(snap["state"], "hybrid")
            self.assertEqual(snap["text"], "Intel→NV · HDMI-A-1")
            hdmi_row = next(r for r in snap["tooltip"] if r["key"].startswith("HDMI-A-1"))
            self.assertIn("Cross-GPU copy", hdmi_row["value"])

    def test_intel_hybrid_extend_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm, nv_proc, lid = self._setup_hybrid_sysfs(Path(tmp))
            snap = gpu_status.build_snapshot(
                self._outputs(hdmi_on=True, edp_on=True),
                drm_sysfs=str(drm),
                nvidia_proc=str(nv_proc),
                lid_glob=str(lid),
                wlr_render="/dev/dri/renderD129",
                wlr_drm="/dev/dri/card2:/dev/dri/card1",
            )
            self.assertEqual(snap["state"], "hybrid")
            self.assertEqual(snap["text"], "Intel · eDP-1 + NV:HDMI-A-1")

    def test_empty_outputs_unavailable(self):
        snap = gpu_status.build_snapshot([])
        self.assertFalse(snap["available"])
        self.assertEqual(snap["state"], "idle")


if __name__ == "__main__":
    unittest.main()
