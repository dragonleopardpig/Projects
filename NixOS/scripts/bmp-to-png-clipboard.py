#!/usr/bin/env python3
"""
Windows RDP / VM BMP-to-PNG Clipboard Bridge.
Converts incoming Windows clipboard bitmaps (image/bmp) to standard Wayland
image/png so GTK4 applications (like Pinta) and Linux desktop tools can paste them.

Crucial detail: FreeRDP / Wayland pipes do not send EOF immediately.
Instead of waiting for EOF, we read the exact BMP byte count encoded in the
14-byte BMP header (offset [2:6], little-endian uint32).
"""

import os
import subprocess
import sys
import tempfile

def read_bmp_from_stream(stream):
    try:
        header = stream.read(14)
        if len(header) < 14 or header[:2] != b"BM":
            return None

        file_size = int.from_bytes(header[2:6], "little")
        # Sanity check: valid BMP between 54 bytes and 128 MB
        if file_size < 54 or file_size > 128 * 1024 * 1024:
            return None

        remaining = file_size - 14
        body = bytearray()
        while len(body) < remaining:
            chunk = stream.read(min(65536, remaining - len(body)))
            if not chunk:
                break
            body.extend(chunk)

        if len(body) != remaining:
            return None

        return header + bytes(body)
    except Exception:
        return None

def main():
    # 1. Check if image/png is already present on the clipboard
    try:
        types_res = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=2)
        types = types_res.stdout.splitlines()
        if "image/png" in types:
            return
    except Exception:
        pass

    # 2. Read exactly the BMP size from stdin (avoiding EOF hang)
    raw = read_bmp_from_stream(sys.stdin.buffer)
    if not raw:
        return

    # 3. Convert BMP to PNG using ImageMagick
    bmp_path = None
    png_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as f_bmp:
            f_bmp.write(raw)
            bmp_path = f_bmp.name

        png_path = bmp_path + ".png"

        res = subprocess.run(
            ["magick", bmp_path, png_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )

        if res.returncode == 0 and os.path.isfile(png_path) and os.path.getsize(png_path) > 0:
            # 4. Populate Wayland clipboard with the synthesized PNG
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
