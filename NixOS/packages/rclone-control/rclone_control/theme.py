"""Theme resolution matching Noctalia Suite palettes (OLO-Neon dark & light)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any

DEFAULT_PALETTE: dict[str, dict[str, Any]] = {
    "dark": {
        "primary": "#00F5C8",
        "on_primary": "#00251F",
        "secondary": "#77F9E0",
        "on_secondary": "#032C25",
        "tertiary": "#61E8FF",
        "on_tertiary": "#002932",
        "error": "#FF6B87",
        "on_error": "#370018",
        "surface": "#080D19",
        "on_surface": "#E9FFF8",
        "surface_container": "#121C2E",
        "on_surface_variant": "#A6BDC9",
        "outline_variant": "#2A4757",
        "hover": "#164A43",
        "on_hover": "#C8FFF0",
        "accent": "#FF149E",
    },
    "light": {
        "primary": "#007B65",
        "on_primary": "#F1FFFA",
        "secondary": "#006B60",
        "on_secondary": "#F1FFFA",
        "tertiary": "#006A80",
        "on_tertiary": "#F1FFFA",
        "error": "#B7274B",
        "on_error": "#FFFFFF",
        "surface": "#EDF9F5",
        "on_surface": "#102B2B",
        "surface_container": "#DDEEE8",
        "on_surface_variant": "#405F5B",
        "outline_variant": "#90B4AA",
        "hover": "#BDEBDF",
        "on_hover": "#123E35",
        "accent": "#A60064",
    },
}


def detect_theme_mode() -> str:
    """Detect active Noctalia dark/light mode."""
    try:
        res = subprocess.run(
            ["noctalia", "msg", "theme-mode-get"],
            capture_output=True, text=True, timeout=0.6, check=False,
        )
        out = res.stdout.strip().lower()
        if out in ("dark", "light"):
            return out
    except OSError:
        pass

    state_home = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local/state"))
    settings_toml = state_home / "noctalia-suite/noctalia/settings.toml"
    if settings_toml.is_file():
        try:
            text = settings_toml.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'^\s*shell_mode\s*=\s*"(dark|light)"', text, re.MULTILINE)
            if m:
                return m.group(1)
        except OSError:
            pass
    return "dark"


def load_palette(mode: str | None = None) -> tuple[str, dict[str, str]]:
    resolved_mode = mode if mode in ("dark", "light") else detect_theme_mode()
    palette = dict(DEFAULT_PALETTE[resolved_mode])

    cfg_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    palette_file = cfg_home / "noctalia-suite/noctalia/palettes/OLO-Neon.json"
    if palette_file.is_file():
        try:
            raw = json.loads(palette_file.read_text(encoding="utf-8"))
            variant = raw.get(resolved_mode)
            if isinstance(variant, dict):
                for key, val in variant.items():
                    if isinstance(val, str) and val.startswith("#"):
                        palette[key] = val
        except (OSError, ValueError, TypeError):
            pass
    return resolved_mode, palette


def build_qss(mode: str | None = None) -> tuple[str, dict[str, str], str]:
    resolved_mode, p = load_palette(mode)
    raised = "#18253C" if resolved_mode == "dark" else "#CFE6DE"
    input_bg = "#0C1424" if resolved_mode == "dark" else "#FFFFFF"

    qss = f"""
    QMainWindow, QDialog {{
        background-color: {p['surface']};
        color: {p['on_surface']};
        font-family: "Inter", sans-serif;
        font-size: 13px;
    }}
    QWidget {{
        color: {p['on_surface']};
    }}
    QFrame#CardFrame, QGroupBox {{
        background-color: {p['surface_container']};
        border: 1px solid {p['outline_variant']};
        border-radius: 10px;
        margin-top: 8px;
        padding: 8px;
    }}
    QGroupBox::title {{
        subcontrol-origin: margin;
        left: 12px;
        padding: 0 6px;
        color: {p['primary']};
        font-weight: bold;
    }}
    QTabWidget::pane {{
        border: 1px solid {p['outline_variant']};
        background-color: {p['surface']};
        border-radius: 10px;
        top: -1px;
    }}
    QTabBar::tab {{
        background-color: {p['surface_container']};
        color: {p['on_surface_variant']};
        border: 1px solid {p['outline_variant']};
        border-bottom: none;
        border-top-left-radius: 8px;
        border-top-right-radius: 8px;
        padding: 8px 16px;
        margin-right: 4px;
        font-weight: 600;
    }}
    QTabBar::tab:selected {{
        background-color: {raised};
        color: {p['primary']};
        border-color: {p['primary']};
    }}
    QTabBar::tab:hover:!selected {{
        background-color: {p['hover']};
        color: {p['on_hover']};
    }}
    QPushButton {{
        background-color: {p['surface_container']};
        color: {p['on_surface']};
        border: 1px solid {p['outline_variant']};
        border-radius: 7px;
        padding: 6px 12px;
        font-weight: 600;
    }}
    QPushButton:hover {{
        background-color: {p['hover']};
        color: {p['on_hover']};
        border-color: {p['primary']};
    }}
    QPushButton:disabled {{
        opacity: 0.45;
        color: {p['on_surface_variant']};
    }}
    QPushButton#PrimaryButton {{
        background-color: {p['primary']};
        color: {p['on_primary']};
        border: 1px solid {p['primary']};
    }}
    QPushButton#PrimaryButton:hover {{
        background-color: {p['secondary']};
        color: {p['on_secondary']};
    }}
    QPushButton#DangerButton {{
        background-color: {p['error']};
        color: {p['on_error']};
        border: 1px solid {p['error']};
    }}
    QLineEdit, QPlainTextEdit, QTextEdit, QComboBox, QSpinBox {{
        background-color: {input_bg};
        color: {p['on_surface']};
        border: 1px solid {p['outline_variant']};
        border-radius: 7px;
        padding: 5px 8px;
        selection-background-color: {p['primary']};
        selection-color: {p['on_primary']};
    }}
    QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QComboBox:focus, QSpinBox:focus {{
        border: 1px solid {p['primary']};
    }}
    QComboBox::drop-down {{
        border: none;
        width: 24px;
    }}
    QComboBox QAbstractItemView {{
        background-color: {p['surface_container']};
        color: {p['on_surface']};
        border: 1px solid {p['primary']};
        selection-background-color: {p['hover']};
        selection-color: {p['on_hover']};
    }}
    QTreeWidget, QTableWidget {{
        background-color: {p['surface_container']};
        alternate-background-color: {raised};
        color: {p['on_surface']};
        border: 1px solid {p['outline_variant']};
        border-radius: 8px;
        gridline-color: {p['outline_variant']};
        outline: none;
    }}
    QTreeWidget::item, QTableWidget::item {{
        padding: 4px 6px;
    }}
    QTreeWidget::item:selected, QTableWidget::item:selected {{
        background-color: {p['hover']};
        color: {p['on_hover']};
    }}
    QHeaderView::section {{
        background-color: {raised};
        color: {p['tertiary']};
        border: none;
        border-bottom: 1px solid {p['outline_variant']};
        padding: 6px 8px;
        font-weight: 700;
    }}
    QProgressBar {{
        background-color: {input_bg};
        border: 1px solid {p['outline_variant']};
        border-radius: 6px;
        text-align: center;
        color: {p['on_surface']};
        min-height: 16px;
    }}
    QProgressBar::chunk {{
        background-color: {p['primary']};
        border-radius: 5px;
    }}
    QMenu {{
        background-color: {p['surface_container']};
        color: {p['on_surface']};
        border: 1px solid {p['primary']};
        border-radius: 8px;
        padding: 4px;
    }}
    QMenu::item {{
        padding: 6px 16px;
        border-radius: 5px;
    }}
    QMenu::item:selected {{
        background-color: {p['hover']};
        color: {p['on_hover']};
    }}
    QSplitter::handle {{
        background-color: {p['outline_variant']};
        width: 3px;
    }}
    QSplitter::handle:hover {{
        background-color: {p['primary']};
    }}
    QStatusBar {{
        background-color: {p['surface_container']};
        color: {p['on_surface_variant']};
        border-top: 1px solid {p['outline_variant']};
    }}
    QToolTip {{
        background-color: {p['surface_container']};
        color: {p['on_surface']};
        border: 1px solid {p['primary']};
        padding: 4px 8px;
    }}
    """
    return resolved_mode, p, qss
