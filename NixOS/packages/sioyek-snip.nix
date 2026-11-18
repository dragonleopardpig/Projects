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
    import shutil
    import subprocess
    import sys
    import time

    import fitz
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

        clip = fitz.Rect(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        page_index = int(page_no)
        try:
            if os.path.splitext(path)[1].lower() in DJVU_EXTENSIONS:
                pix = render_djvu(path, page_index, clip)
            else:
                doc = fitz.open(path)
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

        copied = ""
        if shutil.which("wl-copy-image"):
            # wl-copy-image uses GTK to offer image/png, image/bmp, image/tiff, etc.
            # simultaneously on Wayland. WinApps / FreeRDP / Wine require CF_DIB via
            # image/bmp to paste into Windows, while Linux apps expect image/png.
            subprocess.Popen(["wl-copy-image", out],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            copied = " and copied to the clipboard"
        elif shutil.which("wl-copy"):
            # Do not wait on wl-copy: on Wayland the copier has to stay resident to
            # serve the selection, so waiting for it never returns.
            with open(out, "rb") as fh:
                subprocess.Popen(["wl-copy", "-t", "image/png"], stdin=fh,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            copied = " and copied to the clipboard"

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
    wlCopyImage
    wl-clipboard
    libnotify
  ];
  text = ''
    exec python3 ${sioyekSnipScript} "$@"
  '';
}
