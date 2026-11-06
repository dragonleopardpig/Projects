# OLO-Neon

A deep midnight surface with Olo-inspired teal filled controls and dark,
high-contrast text. Soft mint and icy cyan provide secondary control colors.
Neon magenta (`#FF149E`, vibrant pink) accents window outlines, their glow,
and orbital wallpaper curves. Hover and selection fills use teal. A pearl-mint
light variant uses darker teal controls with pale text.

The theme includes a version-2 Noctalia palette, matching greeter, Umbriel
borders/overview, Inter UI type, and a matching Foot configuration. The 4K
wallpaper is generated reproducibly from `wallpaper.svg`. Neither app template
generation nor edits to other terminal configs are required.

Open **Super+Comma → Appearance → Theme** and choose custom palette
**OLO-Neon**. Both light and dark shell variants are available. Choosing another
palette through Settings persists as a suite-profile override; remove that
override while stopped to return to the declared default. Compositor/greeter
colors and the dedicated Foot profile use the declared OLO-Neon defaults.

| Role | Dark color |
| --- | --- |
| Primary Olo-inspired control fill | `#00F5C8` |
| Text on primary control | `#00251F` |
| Secondary mint control fill | `#77F9E0` |
| Tertiary cyan control fill | `#61E8FF` |
| Neon outlines and curves | `#FF149E` |
| Midnight surface | `#080D19` |
| Raised surface | `#121C2E` |
| Primary text | `#E9FFF8` |

The right-side bar controls borrow Fastfetch's current Kitty ANSI key colors:
gold DISTRO (`#FFD166`) for weather, clock and notifications; sky-blue DE/WM
(`#6BC5FF`) for network, Bluetooth, tray glyphs and displays; mint-green SYSTEM
(`#4EF2C2`) for privacy and battery; lavender AUDIO (`#C27DFF`) for media and
volume. Caffeine and always-on use neon purple (`#BF40FF`). The Control Panel
button is salmon pink (`#FF7E70`), immediately after the date/time button;
the power button is white (`#FFFFFF`).
These are foreground colors on the midnight bar; OLO control fills and magenta
window outlines remain as above. Warning and attention states keep their
native colors, and tray applications retain their own artwork.

Olo is the inspiration: this palette uses displayable saturated teal rather
than claiming to reproduce the experimental color described by
[UC Berkeley](https://news.berkeley.edu/2025/04/22/scientists-trick-the-eye-into-seeing-new-color-olo/).
