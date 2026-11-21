"""The bar's icons: every one its own neon colour, and every one can be unpinned.

Reads the generated Noctalia config (settings.nix) and fails on:
- an icon without a colour, a colour too dull to be neon (chroma), one too dark to read on
  the see-through bar (contrast below MIN_CONTRAST against WORST_BAR), two icons whose
  colours are too alike (CIEDE2000 below MIN_DE), or neighbours on the bar that are hard to
  tell apart (below MIN_NEIGHBOUR_DE);
- an icon whose right click does not open the native Pin/Unpin menu (`widget-menu`; except
  the tray and the taskbar, which handle right click per item);
- a plugin icon without a left-click action in settings.nix: once unpinned it sits in the
  tray drawer, which runs config actions only (the plugin's script is not running);
- a local plugin whose bar script has its own onRightClick but whose plugin.toml does not
  name it (`right_click_label`), so the Pin/Unpin menu could not offer it.
"""

import argparse
import itertools
import math
import re
import sys
import tomllib
from pathlib import Path

MIN_DE = 7.0
MIN_NEIGHBOUR_DE = 20.0
MIN_CHROMA = 35.0
# The bar is theme.nix's dark surface; the GUI has it at 60% opacity, so a bright wallpaper
# shows through.  Worst case measured: that bar over a mid-grey wallpaper.
BAR_SURFACE = "#080D19"
BAR_OPACITY = 0.6
WALLPAPER = "#808080"
MIN_CONTRAST = 4.5  # WCAG's floor for small text, which bar glyphs are
# No colour of their own: app icons (taskbar) and the window title (text).
UNCOLOURED = {"taskbar", "active_window"}
# White on purpose (2026-11-15 "make the top-bar power button white").
WHITE_OK = {"session"}
OWN_RIGHT_CLICK = {"tray", "taskbar"}
# Plugin icons with nothing to do on a left click.
NO_LEFT_CLICK = {"xwayland"}
MENU = "widget-menu"


def lab(hex_colour):
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

    def linear(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = linear(r), linear(g), linear(b)
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116

    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def luminance(hex_colour):
    h = hex_colour.lstrip("#")
    channels = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    r, g, b = (c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(c1, c2):
    high, low = sorted((luminance(c1), luminance(c2)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def worst_bar():
    bar = [int(BAR_SURFACE[i:i + 2], 16) for i in (1, 3, 5)]
    wall = [int(WALLPAPER[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(BAR_OPACITY * b + (1 - BAR_OPACITY) * w):02X}" for b, w in zip(bar, wall, strict=True))


def delta_e(c1, c2):
    """CIEDE2000 difference of two sRGB hex colours."""
    l1, a1, b1 = lab(c1)
    l2, a2, b2 = lab(c2)
    cbar = (math.hypot(a1, b1) + math.hypot(a2, b2)) / 2
    g = 0.5 * (1 - math.sqrt(cbar ** 7 / (cbar ** 7 + 25 ** 7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360
    h2p = math.degrees(math.atan2(b2, a2p)) % 360
    dlp, dcp = l2 - l1, c2p - c1p
    dh = h2p - h1p
    if c1p * c2p == 0:
        dh = 0
    elif dh > 180:
        dh -= 360
    elif dh < -180:
        dh += 360
    dhp = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dh / 2))
    lbp, cbp = (l1 + l2) / 2, (c1p + c2p) / 2
    if c1p * c2p == 0:
        hbp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hbp = (h1p + h2p) / 2
    elif h1p + h2p < 360:
        hbp = (h1p + h2p + 360) / 2
    else:
        hbp = (h1p + h2p - 360) / 2
    t = (1 - 0.17 * math.cos(math.radians(hbp - 30)) + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6)) - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    dtheta = 30 * math.exp(-(((hbp - 275) / 25) ** 2))
    rc = 2 * math.sqrt(cbp ** 7 / (cbp ** 7 + 25 ** 7))
    sl = 1 + 0.015 * (lbp - 50) ** 2 / math.sqrt(20 + (lbp - 50) ** 2)
    sc = 1 + 0.045 * cbp
    sh = 1 + 0.015 * cbp * t
    rt = -math.sin(math.radians(2 * dtheta)) * rc
    return math.sqrt((dlp / sl) ** 2 + (dcp / sc) ** 2 + (dhp / sh) ** 2 + rt * (dcp / sc) * (dhp / sh))


def unnamed_right_clicks(plugins_dir):
    """Local plugin bars with their own onRightClick that plugin.toml does not name."""
    missing = []
    for manifest in sorted(Path(plugins_dir).glob("*/plugin.toml")):
        data = tomllib.loads(manifest.read_text(encoding="utf-8"))
        for widget in data.get("widget", []):
            script = (manifest.parent / widget["entry"]).read_text(encoding="utf-8")
            if re.search(r"^function onRightClick\b", script, re.MULTILINE) and not widget.get("right_click_label"):
                missing.append(f"{data['id']}:{widget['id']}")
    return missing


def problems(config, plugins_dir):
    found = []
    bar = config["bar"]["main"]
    widgets = config.get("widget", {})
    sections = [bar.get(side, []) for side in ("start", "center", "end")]

    coloured = []
    for name in itertools.chain(*sections):
        if name in UNCOLOURED:
            continue
        colour = widgets.get(name, {}).get("color")
        if not isinstance(colour, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", colour):
            found.append(f"{name}: no colour of its own (widget.{name}.color)")
            continue
        if name not in WHITE_OK:
            _, a, b = lab(colour)
            if math.hypot(a, b) < MIN_CHROMA:
                found.append(f"{name}: {colour} is not neon (chroma {math.hypot(a, b):.0f})")
        ratio = contrast(colour, worst_bar())
        if ratio < MIN_CONTRAST:
            found.append(f"{name}: {colour} is too dark on the bar ({ratio:.2f}:1 < {MIN_CONTRAST}:1)")
        coloured.append((name, colour))
    for (n1, c1), (n2, c2) in itertools.combinations(coloured, 2):
        d = delta_e(c1, c2)
        if d < MIN_DE:
            found.append(f"{n1} {c1} and {n2} {c2} are too alike (dE {d:.1f} < {MIN_DE})")
    colour_of = dict(coloured)
    for section in sections:
        shown = [n for n in section if n in colour_of]
        for n1, n2 in zip(shown, shown[1:], strict=False):
            d = delta_e(colour_of[n1], colour_of[n2])
            if d < MIN_NEIGHBOUR_DE:
                found.append(f"neighbours {n1} and {n2} are hard to tell apart (dE {d:.1f} < {MIN_NEIGHBOUR_DE})")

    for name in itertools.chain(*sections):
        if name not in OWN_RIGHT_CLICK:
            right = widgets.get(name, {}).get("actions", {}).get("right")
            if right != MENU:
                found.append(f"{name}: right click is {right!r}, not the Pin/Unpin menu")
        if ":" in widgets.get(name, {}).get("type", "") and name not in NO_LEFT_CLICK:
            if not widgets[name].get("actions", {}).get("left"):
                found.append(f"{name}: plugin icon without actions.left (the tray drawer could not open it)")
    for entry in unnamed_right_clicks(plugins_dir):
        found.append(f"{entry}: onRightClick without right_click_label in plugin.toml (the menu cannot offer it)")
    return found, len(coloured)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--config", required=True, help="the generated Noctalia config.toml")
    parser.add_argument("--plugins", required=True, help="the local plugins directory")
    args = parser.parse_args(argv)
    config = tomllib.loads(Path(args.config).read_text(encoding="utf-8"))
    found, count = problems(config, args.plugins)
    if found:
        print("\n".join(found), file=sys.stderr)
        return 1
    print(f"{count} bar icons: each its own neon colour, each with the Pin/Unpin menu")
    return 0


if __name__ == "__main__":
    sys.exit(main())
