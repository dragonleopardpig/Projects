#!/usr/bin/env python3
"""Stream active renderer GPU and per-monitor scanout state for Noctalia Suite."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

VENDOR_NAMES = {
    "0x10de": ("NVIDIA", "NV"),
    "0x8086": ("Intel", "Intel"),
    "0x1002": ("AMD", "AMD"),
}

DRIVER_VENDORS = {
    "nvidia": ("NVIDIA", "NV"),
    "nouveau": ("NVIDIA", "NV"),
    "i915": ("Intel", "Intel"),
    "xe": ("Intel", "Intel"),
    "amdgpu": ("AMD", "AMD"),
    "radeon": ("AMD", "AMD"),
}


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def _umbriel_env_from_proc(wayland_display: str | None = None) -> tuple[str, str]:
    uid = os.getuid()
    if wayland_display is None:
        wayland_display = os.environ.get("WAYLAND_DISPLAY", "")
    for proc_dir in glob.glob("/proc/[0-9]*"):
        try:
            st = os.stat(proc_dir)
            if st.st_uid != uid:
                continue
            comm = _read_text(Path(proc_dir, "comm"))
            if "umbriel" not in comm:
                continue
            raw = Path(proc_dir, "environ").read_bytes()
        except OSError:
            continue
        env_map: dict[str, str] = {}
        for entry in raw.split(b"\x00"):
            if b"=" in entry:
                k, v = entry.split(b"=", 1)
                env_map[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        if wayland_display and env_map.get("WAYLAND_DISPLAY") != wayland_display:
            continue
        render = env_map.get("WLR_RENDER_DRM_DEVICE", "")
        devices = env_map.get("WLR_DRM_DEVICES", "")
        if render or devices:
            return render, devices
    return "", ""


def resolve_drm_env(
    wlr_render: str | None = None,
    wlr_drm: str | None = None,
) -> tuple[str, str]:
    render = wlr_render if wlr_render is not None else os.environ.get("WLR_RENDER_DRM_DEVICE", "")
    devices = wlr_drm if wlr_drm is not None else os.environ.get("WLR_DRM_DEVICES", "")
    if wlr_render is None and wlr_drm is None and not render and not devices:
        render, devices = _umbriel_env_from_proc()
    return render.strip(), devices.strip()


def _vendor_info(vendor_hex: str, driver: str) -> tuple[str, str]:
    key = vendor_hex.lower()
    if key in VENDOR_NAMES:
        return VENDOR_NAMES[key]
    drv = driver.lower()
    if drv in DRIVER_VENDORS:
        return DRIVER_VENDORS[drv]
    label = driver or "GPU"
    return label, label


def _nvidia_model(pci_slot: str, nvidia_proc: str) -> str:
    if not pci_slot or not nvidia_proc:
        return ""
    info_path = Path(nvidia_proc, pci_slot, "information")
    text = _read_text(info_path)
    if not text:
        return ""
    m = re.search(r"^Model:\s*(.+)$", text, re.MULTILINE)
    return re.sub(r"\s+", " ", m.group(1)).strip() if m else ""


def read_drm_topology(
    drm_sysfs: str = "/sys/class/drm",
    nvidia_proc: str = "/proc/driver/nvidia/gpus",
) -> tuple[dict[str, dict], dict[str, dict]]:
    """Return (cards_by_name, connectors_by_name) from sysfs."""
    cards: dict[str, dict] = {}
    connectors: dict[str, dict] = {}

    for card_path_str in sorted(glob.glob(os.path.join(drm_sysfs, "card[0-9]*"))):
        card_path = Path(card_path_str)
        card_name = card_path.name
        if not re.fullmatch(r"card[0-9]+", card_name):
            continue

        render_paths = sorted(glob.glob(os.path.join(card_path_str, "device", "drm", "renderD[0-9]*")))
        if not render_paths:
            continue
        render_name = Path(render_paths[0]).name

        device_dir = card_path / "device"
        driver_link = device_dir / "driver"
        try:
            driver = Path(os.path.realpath(driver_link)).name if driver_link.exists() else ""
        except OSError:
            driver = ""

        vendor_hex = _read_text(device_dir / "vendor")
        vendor, short_vendor = _vendor_info(vendor_hex, driver)

        pci_slot = ""
        uevent = _read_text(device_dir / "uevent")
        m_slot = re.search(r"^PCI_SLOT_NAME=(.+)$", uevent, re.MULTILINE)
        if m_slot:
            pci_slot = m_slot.group(1).strip()
        elif device_dir.exists():
            try:
                pci_slot = Path(os.path.realpath(device_dir)).name
            except OSError:
                pci_slot = ""

        model = ""
        if vendor == "NVIDIA":
            model = _nvidia_model(pci_slot, nvidia_proc)
        if not model:
            model = f"{vendor} Graphics" if vendor in ("Intel", "AMD") else vendor

        boot_vga = _read_text(device_dir / "boot_vga") == "1"

        card_info = {
            "card": card_name,
            "render": render_name,
            "driver": driver or "unknown",
            "vendor": vendor,
            "short": short_vendor,
            "model": model,
            "pci_slot": pci_slot,
            "boot_vga": boot_vga,
        }
        cards[card_name] = card_info

        for status_path_str in sorted(glob.glob(os.path.join(drm_sysfs, f"{card_name}-*", "status"))):
            conn_dir = Path(status_path_str).parent
            conn_short = conn_dir.name[len(card_name) + 1 :]
            status = _read_text(Path(status_path_str))
            existing = connectors.get(conn_short)
            if existing is None or (status == "connected" and existing.get("status") != "connected"):
                connectors[conn_short] = {**card_info, "status": status}

    return cards, connectors


def resolve_primary_card(
    cards: dict[str, dict],
    wlr_render: str,
    wlr_drm: str,
) -> dict | None:
    if not cards:
        return None
    if wlr_render:
        render_name = os.path.basename(wlr_render.strip())
        for info in cards.values():
            if info["render"] == render_name:
                return info
    if wlr_drm:
        first = next((part.strip() for part in wlr_drm.split(":") if part.strip()), "")
        first_name = os.path.basename(first)
        if first_name in cards:
            return cards[first_name]
    boot_cards = [c for c in cards.values() if c.get("boot_vga")]
    if boot_cards:
        return boot_cards[0]
    return next(iter(cards.values()))


def _format_mode(output: dict) -> str:
    modes = output.get("modes") or []
    cur = next((m for m in modes if m.get("current")), None)
    if not cur and modes:
        cur = next((m for m in modes if m.get("preferred")), modes[0])
    if not cur:
        return ""
    w = cur.get("width", 0)
    h = cur.get("height", 0)
    hz = int(round((cur.get("refresh_mhz", 0) or 0) / 1000))
    if w and h and hz:
        return f"{w}x{h}@{hz}Hz"
    if w and h:
        return f"{w}x{h}"
    return ""


def _read_lid_state(lid_glob: str = "/proc/acpi/button/lid/*/state") -> str:
    for path in glob.glob(lid_glob):
        text = _read_text(Path(path)).lower()
        if "closed" in text:
            return "Closed"
        if "open" in text:
            return "Open"
    return ""


def build_snapshot(
    outputs: list[dict],
    drm_sysfs: str = "/sys/class/drm",
    nvidia_proc: str = "/proc/driver/nvidia/gpus",
    lid_glob: str = "/proc/acpi/button/lid/*/state",
    wlr_render: str | None = None,
    wlr_drm: str | None = None,
) -> dict:
    if not outputs:
        return {"available": False, "state": "idle", "glyph": "cpu", "text": "", "tooltip": []}

    cards, connectors = read_drm_topology(drm_sysfs=drm_sysfs, nvidia_proc=nvidia_proc)
    render_env, drm_env = resolve_drm_env(wlr_render=wlr_render, wlr_drm=wlr_drm)
    primary = resolve_primary_card(cards, render_env, drm_env)

    renderer_card = primary["card"] if primary else ""
    renderer_short = primary["short"] if primary else "GPU"
    renderer_vendor = primary["vendor"] if primary else "GPU"
    renderer_model = primary["model"] if primary else "GPU"
    renderer_render = primary["render"] if primary else ""

    monitors: list[dict] = []
    for out in outputs:
        name = out.get("name", "")
        enabled = bool(out.get("enabled", False))
        focused = bool(out.get("focused", False))
        mode_str = _format_mode(out)
        conn = connectors.get(name)
        scanout_card = conn["card"] if conn else ""
        scanout_short = conn["short"] if conn else "?"
        scanout_vendor = conn["vendor"] if conn else "Unknown"
        cross_gpu = bool(primary and conn and scanout_card != renderer_card)
        monitors.append({
            "name": name,
            "enabled": enabled,
            "focused": focused,
            "mode": mode_str,
            "scanout_card": scanout_card,
            "scanout_short": scanout_short,
            "scanout_vendor": scanout_vendor,
            "cross_gpu": cross_gpu,
        })

    active = [m for m in monitors if m["enabled"]]
    any_cross_gpu = any(m["cross_gpu"] for m in active)

    if not active:
        state = "idle"
        text = f"{renderer_short} · Off"
    elif any_cross_gpu:
        state = "hybrid"
        ordered = sorted(active, key=lambda item: (item["cross_gpu"], item["name"]))
        if len(ordered) == 1 and ordered[0]["cross_gpu"]:
            text = f"{renderer_short}→{ordered[0]['scanout_short']} · {ordered[0]['name']}"
        else:
            parts = [
                f"{m['scanout_short']}:{m['name']}" if m["cross_gpu"] else m["name"]
                for m in ordered
            ]
            text = f"{renderer_short} · {' + '.join(parts)}"
    else:
        v_low = renderer_vendor.lower()
        state = v_low if v_low in ("nvidia", "intel", "amd") else "other"
        names = " + ".join(m["name"] for m in active)
        text = f"{renderer_short} · {names}"

    tooltip: list[dict[str, str]] = []
    if primary:
        tooltip.append({
            "key": "Renderer",
            "value": f"{renderer_model} ({renderer_card} · {renderer_render})",
        })
    for m in sorted(monitors, key=lambda item: (not item["enabled"], item["name"])):
        flag = "[ON]" if m["enabled"] else "[OFF]"
        details = [f"{m['scanout_vendor']} ({m['scanout_card'] or '?'})"]
        if m["mode"]:
            details.append(m["mode"])
        if m["enabled"] and m["scanout_card"]:
            details.append("Cross-GPU copy" if m["cross_gpu"] else "Direct")
        tooltip.append({
            "key": f"{m['name']} {flag}",
            "value": " · ".join(details),
        })

    lid_state = _read_lid_state(lid_glob)
    if lid_state:
        tooltip.append({"key": "Lid", "value": lid_state})

    return {
        "available": True,
        "state": state,
        "glyph": "cpu",
        "text": text,
        "renderer": primary,
        "monitors": monitors,
        "tooltip": tooltip,
    }


def query_outputs() -> list[dict]:
    try:
        res = subprocess.run(["umbriel", "outputs", "--json"], capture_output=True, text=True, check=True)
        data = json.loads(res.stdout)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def watch() -> int:
    last_line = ""
    while True:
        proc = None
        try:
            proc = subprocess.Popen(
                ["umbriel", "subscribe", "outputs"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            for raw in proc.stdout:
                line = raw.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                outputs = msg.get("data")
                if not isinstance(outputs, list):
                    outputs = query_outputs()
                snap = build_snapshot(outputs)
                encoded = json.dumps(snap, sort_keys=True)
                if encoded != last_line:
                    print(encoded, flush=True)
                    last_line = encoded
        except Exception:
            pass
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    proc.kill()

        offline = json.dumps(build_snapshot([]), sort_keys=True)
        if offline != last_line:
            print(offline, flush=True)
            last_line = offline
        time.sleep(1.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "watch"), nargs="?", default="status")
    args = parser.parse_args()
    if args.command == "status":
        print(json.dumps(build_snapshot(query_outputs()), sort_keys=True))
        return 0
    return watch()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
