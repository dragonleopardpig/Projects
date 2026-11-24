{
  writeText,
  writeShellApplication,
  python3,
  djvulibre,
  wlCopyImage,
  wl-clipboard,
  libnotify,
}:

let
  # Sioyek has no area-screenshot command, but a custom command containing
  # %{selected_rect} makes it prompt for a rectangle and then hand over
  # "page,x0,y0,x1,y1" in MuPDF document space -- page-relative points.
  # PyMuPDF renders PDF-family documents; DjVuLibre renders DjVu using the same
  # 72-points-per-inch coordinate conversion. Sioyek runs custom commands
  # through QProcess with an argv list rather than a shell, so a substituted
  # path keeps its spaces without any quoting.
  sioyekSnipScript = writeText "sioyek-snip.py" ''
    """Crop the rectangle Sioyek just selected into a PNG.

    Sioyek has no area-screenshot command, but a custom command containing
    %{selected_rect} makes it prompt for a rectangle and then hands over
    "page,x0,y0,x1,y1" in MuPDF document space -- page-relative points. PDF-family
    documents are rendered with PyMuPDF. DjVu documents are rendered with DjVuLibre
    and cropped after converting points to output pixels.
    """
    import io
    import math
    import os
    import selectors
    import shutil
    import subprocess
    import sys
    import time

    import pymupdf
    from PIL import Image

    DPI = int(os.environ.get("SIOYEK_SNIP_DPI", "300"))
    OUTDIR = os.path.expanduser(os.environ.get("SIOYEK_SNIP_DIR", "~/Pictures/Screenshots"))
    DJVU_EXTENSIONS = {".djv", ".djvu"}


    def notify(summary, body, urgency="normal"):
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "-a", "Sioyek", "-u", urgency,
                            "-i", "applets-screenshooter", summary, body], check=False)


    def render_djvu(path, page_no, clip):
        command = [
            "ddjvu",
            "-page=%d" % (page_no + 1),
            "-scale=%d" % DPI,
            "-format=ppm",
            path,
            "-",
        ]
        try:
            rendered = subprocess.run(command, check=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            detail = error.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(detail or "DjVuLibre could not render the page") from error

        with Image.open(io.BytesIO(rendered.stdout)) as page_image:
            page_image.load()
            pixels_per_point = DPI / 72.0
            left = max(0, min(page_image.width, math.floor(clip.x0 * pixels_per_point)))
            top = max(0, min(page_image.height, math.floor(clip.y0 * pixels_per_point)))
            right = max(0, min(page_image.width, math.ceil(clip.x1 * pixels_per_point)))
            bottom = max(0, min(page_image.height, math.ceil(clip.y1 * pixels_per_point)))
            if right <= left or bottom <= top:
                raise RuntimeError("The selection was empty")
            return page_image.crop((left, top, right, bottom))


    def copy_snapshot(path):
        owner = subprocess.Popen(
            ["${wlCopyImage}/bin/wl-copy-image", "--ready", path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        with owner.stdout, selectors.DefaultSelector() as selector:
            selector.register(owner.stdout, selectors.EVENT_READ)
            if selector.select(timeout=3) and owner.stdout.readline() == b"ready\n":
                return " and copied to the clipboard"
        if owner.poll() is None:
            owner.terminate()
        try:
            owner.wait(timeout=1)
        except subprocess.TimeoutExpired:
            owner.kill()
            owner.wait()

        if os.environ.get("WAYLAND_DISPLAY") or os.environ.get("WAYLAND_SOCKET"):
            try:
                with open(path, "rb") as image:
                    result = subprocess.run(
                        ["${wl-clipboard}/bin/wl-copy", "--type", "image/png"], stdin=image,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3,
                        check=False,
                    )
                if result.returncode == 0:
                    return " and copied to the clipboard as PNG"
            except subprocess.TimeoutExpired:
                pass
        return ""


    def main():
        if len(sys.argv) < 3:
            sys.exit("usage: sioyek-snip <page,x0,y0,x1,y1> <document>")
        rect_arg, path = sys.argv[1], sys.argv[2]

        try:
            page_no, x0, y0, x1, y1 = (float(v) for v in rect_arg.split(","))
        except ValueError:
            sys.exit("sioyek-snip: cannot parse rect %r" % rect_arg)

        if not os.path.isfile(path):
            sys.exit("sioyek-snip: cannot read " + path)

        clip = pymupdf.Rect(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        page_index = int(page_no)
        try:
            if os.path.splitext(path)[1].lower() in DJVU_EXTENSIONS:
                pix = render_djvu(path, page_index, clip)
            else:
                doc = pymupdf.open(path)
                try:
                    page = doc[page_index]
                    clip = clip & page.rect          # a drag can run past the page edge
                    if clip.is_empty:
                        raise RuntimeError("The selection was empty")
                    pix = page.get_pixmap(clip=clip, dpi=DPI)
                finally:
                    doc.close()
        except Exception as error:
            notify("Snip failed", str(error), "critical")
            sys.exit("sioyek-snip: " + str(error))

        os.makedirs(OUTDIR, exist_ok=True)
        stem = os.path.splitext(os.path.basename(path))[0][:60]
        out = os.path.join(OUTDIR, "%s-p%d-%s.png"
                           % (stem, page_index + 1, time.strftime("%Y%m%d-%H%M%S")))
        pix.save(out)

        copied = copy_snapshot(out)

        notify("Snipped page %d" % (page_index + 1),
               "%dx%d px at %d dpi%s" % (pix.width, pix.height, DPI, copied))
        print(out)


    if __name__ == "__main__":
        main()
  '';
in
writeShellApplication {
  name = "sioyek-snip";
  runtimeInputs = [
    (python3.withPackages (ps: with ps; [ pillow pymupdf ]))
    djvulibre
    libnotify
  ];
  text = ''
    exec python3 ${sioyekSnipScript} "$@"
  '';
}
