#!/usr/bin/env python3
"""
Windows RDP / VM BMP-to-PNG Clipboard Bridge.
Converts incoming Windows clipboard bitmaps (image/bmp) to standard Wayland
image/png so GTK4 applications (like Pinta) and Linux desktop tools can paste them.

FreeRDP / Wayland pipes do not send EOF immediately. Read the byte count from
the BMP header and close the transfer before querying the current MIME types.
Clipboard offers that already include PNG keep their other formats.
"""

import os
import select
import subprocess
import sys
import tempfile

def read_bmp_from_stream(stream, timeout=2.0):
    try:
        fd = stream.fileno()
        header = bytearray()
        while len(header) < 14:
            r, _, _ = select.select([fd], [], [], timeout)
            if not r:
                return None
            chunk = os.read(fd, 14 - len(header))
            if not chunk:
                return None
            header.extend(chunk)

        if header[:2] != b"BM":
            return None

        file_size = int.from_bytes(header[2:6], "little")
        # Sanity check: valid BMP between 54 bytes and 128 MB
        if file_size < 54 or file_size > 128 * 1024 * 1024:
            return None

        remaining = file_size - 14
        body = bytearray()
        while len(body) < remaining:
            r, _, _ = select.select([fd], [], [], timeout)
            if not r:
                # Timeout waiting for next chunk; break and proceed with what we have
                break
            chunk = os.read(fd, min(65536, remaining - len(body)))
            if not chunk:
                break
            body.extend(chunk)

        return bytes(header) + bytes(body)
    except Exception as e:
        print(f"[bmp-to-png] Stream read error: {e}", file=sys.stderr)
        return None


def clipboard_needs_png():
    result = subprocess.run(
        ["wl-paste", "--list-types"],
        capture_output=True,
        timeout=2,
        check=False,
    )
    types = set(result.stdout.splitlines())
    return result.returncode == 0 and b"image/bmp" in types and b"image/png" not in types


def main():
    with sys.stdin.buffer as stream:
        raw = read_bmp_from_stream(stream)
    if not raw or len(raw) < 54 or not raw.startswith(b"BM"):
        return

    bmp_path = None
    png_path = None
    try:
        if not clipboard_needs_png():
            return
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

        if (res.returncode == 0 and os.path.isfile(png_path)
                and os.path.getsize(png_path) > 0 and clipboard_needs_png()):
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
