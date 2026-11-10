#!/usr/bin/env python3
"""
Windows RDP / VM BMP-to-PNG Clipboard Bridge.
Converts incoming Windows clipboard bitmaps (image/bmp) to standard Wayland
image/png so GTK4 applications (like Pinta) and Linux browsers can paste them.
"""

import os
import subprocess
import sys
import tempfile

def main():
    # 1. Check if image/png is already present on the clipboard.
    try:
        types_res = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=2)
        types = types_res.stdout.splitlines()
        if "image/png" in types:
            return
    except Exception:
        pass

    # 2. Read full payload from stdin (passed by wl-paste -t image/bmp --watch)
    try:
        raw = sys.stdin.buffer.read()
    except Exception:
        return

    # A valid Windows BMP starts with 'BM' and has at least 54 bytes of header
    if len(raw) < 54 or not raw.startswith(b"BM"):
        return

    # 3. Write raw BMP to temporary file
    bmp_path = None
    png_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as f_bmp:
            f_bmp.write(raw)
            bmp_path = f_bmp.name

        png_path = bmp_path + ".png"

        # 4. Convert BMP to PNG using ImageMagick
        res = subprocess.run(
            ["magick", bmp_path, png_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )

        if res.returncode == 0 and os.path.isfile(png_path) and os.path.getsize(png_path) > 0:
            # 5. Populate Wayland clipboard with the synthesized PNG
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
