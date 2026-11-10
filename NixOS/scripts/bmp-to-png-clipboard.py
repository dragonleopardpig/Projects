#!/usr/bin/env python3
"""
Windows RDP / VM BMP-to-PNG Clipboard Bridge.
Converts incoming Windows clipboard bitmaps (image/bmp) to standard Wayland
image/png so GTK4 applications (like Pinta) and Linux desktop tools can paste them.

NOTE: Never invoke `wl-paste` inside this handler. Re-entrant clipboard queries
from a child of `wl-paste --watch` cause a protocol deadlock with the compositor.
"""

import os
import subprocess
import sys
import tempfile

def main():
    try:
        raw = sys.stdin.buffer.read()
    except Exception:
        return

    # Check for valid BMP magic and minimal header size
    if len(raw) < 54 or not raw.startswith(b"BM"):
        return

    bmp_path = None
    png_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as f_bmp:
            f_bmp.write(raw)
            bmp_path = f_bmp.name

        png_path = bmp_path + ".png"

        # Convert BMP to PNG using ImageMagick
        res = subprocess.run(
            ["magick", bmp_path, png_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )

        if res.returncode == 0 and os.path.isfile(png_path) and os.path.getsize(png_path) > 0:
            with open(png_path, "rb") as f_png:
                subprocess.run(
                    ["wl-copy", "-t", "image/png"],
                    stdin=f_png,
                    check=True,
                    timeout=5,
                )
    except Exception as e:
        print(f"[bmp-to-png] Conversion error: {e}", file=sys.stderr)
    finally:
        if bmp_path and os.path.exists(bmp_path):
            try:
                os.remove(bmp_path)
            except OSError:
                pass
        if png_path and os.path.exists(png_path):
            try:
                os.remove(png_path)
            except OSError:
                pass

if __name__ == "__main__":
    main()
