# /etc/nixos/configuration.nix

{ inputs, lib, config,  pkgs, ... }:

let
  # SDDM login theme. metadata.desktop's ConfigFile= is rewritten at boot
  # by systemd.services.sddm-random-theme to pick a random variant, so
  # `embeddedTheme` here is only the fallback if the picker doesn't run.
  astronautPkg = pkgs.sddm-astronaut.override {
    embeddedTheme = "pixel_sakura";
    themeConfig = { FormPosition = "left"; };
  };
  # Sioyek chooses a highlight type by pressing h followed by a-z. Mirror its
  # default 26-color palette on those letter keys of either Logitech keyboard.
  # The older GPRO (046d:c339) uses g810-led. The PRO X TKL (046d:c352) uses
  # Solaar's supported HID++ PER_KEY_LIGHTING_V2 live update; its per-key data
  # cannot currently be stored in an onboard profile by a Linux tool.
  sioyekHighlightColors = {
    a = "f0a3ff";
    b = "0075db";
    c = "994000";
    d = "4d005c";
    e = "1a1a1a";
    f = "005c30";
    g = "2bcf47";
    h = "ffcc99";
    i = "808080";
    j = "94ffb5";
    k = "8f7d00";
    l = "9ecc00";
    m = "c20087";
    n = "003380";
    o = "ffa305";
    p = "ffa8ba";
    q = "426600";
    r = "ff000f";
    s = "5ef2f2";
    t = "00998f";
    u = "e0ff66";
    v = "730aff";
    w = "990000";
    x = "ffff80";
    y = "ffff00";
    z = "ff4f05";
  };
  sioyekKeyboardProfile = pkgs.writeText "gpro-sioyek-highlights.profile" (
    "a ffffff\n"
    + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: color: "k ${key} ${color}") sioyekHighlightColors
      )
    + "\nc\n"
  );
  gproLedSioyek = pkgs.g810-led.override {
    profile = sioyekKeyboardProfile;
  };
  gproSioyekApply = pkgs.writeShellScriptBin "gpro-sioyek" ''
    exec ${lib.getExe' gproLedSioyek "gpro-led"} -p ${sioyekKeyboardProfile}
  '';
  proXTklSioyekScript = pkgs.writeText "pro-x-tkl-sioyek.py" ''
    #!/usr/bin/env python3
    import sys
    import time

    from logitech_receiver import exceptions
    from logitech_receiver import hidpp20_constants
    from logitech_receiver import settings_templates
    from solaar.cli import _find_device, _receivers_and_devices


    PALETTE = ${builtins.toJSON sioyekHighlightColors}


    def main():
        devices = list(_receivers_and_devices())
        keyboard = next(
            (device for device in _find_device(devices, "pro x tkl") if device.ping()),
            None,
        )
        if keyboard is None:
            print("PRO X TKL is not connected", file=sys.stderr)
            return 2

        lighting = settings_templates.check_feature_setting(
            keyboard, "per-key-lighting"
        )
        led_control = settings_templates.check_feature_setting(keyboard, "rgb_control")
        if lighting is None or led_control is None:
            print("PRO X TKL lighting features are unavailable", file=sys.stderr)
            return 1

        solaar_control = next(
            choice for choice in led_control.choices if str(choice) == "Solaar"
        )
        device_control = next(
            choice for choice in led_control.choices if str(choice) == "Device"
        )
        current_control = led_control.read(cached=False)
        if current_control is None:
            print("Could not read the keyboard LED controller", file=sys.stderr)
            return 1
        # PER_KEY_LIGHTING_V2 leaves its commit engine busy after one complete
        # palette. Cycling control back through the device starts a fresh
        # update session, making repeated Super+F7 presses reliable.
        if current_control == solaar_control:
            if led_control.write(device_control, save=False) is None:
                print("Could not reset the keyboard LED controller", file=sys.stderr)
                return 1
            time.sleep(0.05)
        if led_control.write(solaar_control, save=False) is None:
            print("Could not give Solaar control of the keyboard LEDs", file=sys.stderr)
            return 1

        keys_by_name = {str(key).lower(): int(key) for key in lighting.choices}
        colors = {int(key): 0xFFFFFF for key in lighting.choices}
        for key, color in PALETTE.items():
            colors[keys_by_name[key]] = int(color, 16)

        try:
            lighting.write(colors, save=False)
        except exceptions.FeatureCallError as error:
            # The wireless keyboard can briefly report BUSY when committing a
            # second palette. Its update buffer is already populated, so retry
            # just the commit instead of sending every key again.
            if (
                error.error != hidpp20_constants.ErrorCode.BUSY
                or error.request & 0xF0 != 0x70
            ):
                raise
            for delay in (0.05, 0.1, 0.25, 0.5, 1.0):
                time.sleep(delay)
                try:
                    keyboard.feature_request(lighting.feature, 0x70, 0x00)
                    break
                except exceptions.FeatureCallError as retry_error:
                    if retry_error.error != hidpp20_constants.ErrorCode.BUSY:
                        raise
            else:
                raise
        print("Applied Sioyek palette to PRO X TKL")
        return 0


    if __name__ == "__main__":
        try:
            raise SystemExit(main())
        except Exception as error:
            print(f"Could not update PRO X TKL lighting: {error}", file=sys.stderr)
            raise SystemExit(1)
  '';
  # Add one batch command to Solaar so the entire keyboard is updated in one
  # HID++ transaction instead of starting the Solaar CLI once per key.
  solaarSioyek = pkgs.solaar.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      install -Dm755 ${proXTklSioyekScript} $out/bin/pro-x-tkl-sioyek
    '';
  });
  sioyekKeyboardApply = pkgs.writeShellScriptBin "sioyek-keyboard-lights" ''
    if ${solaarSioyek}/bin/pro-x-tkl-sioyek; then
      exit 0
    fi

    exec ${lib.getExe gproSioyekApply}
  '';

  # Sioyek renders through MuPDF, which has no DjVu backend, so DjVu files are
  # converted once into a PDF cached beside the source. ddjvu discards the
  # embedded text layer, hence the Tesseract pass: it restores search and also
  # avoids the duplicated hyphen fragments ("at dif- different heights") that
  # older DjVu text layers carry.
  djvuToPdf = pkgs.writeShellApplication {
    name = "djvu2pdf";
    runtimeInputs = with pkgs; [ djvulibre ocrmypdf tesseract coreutils ];
    text = ''
      force=0
      ocr=1
      src=""
      dst=""

      usage() {
        echo "Usage: djvu2pdf [--force] [--no-ocr] <file.djvu> [out.pdf]" >&2
        echo "" >&2
        echo "  --force   reconvert even if the PDF is already up to date" >&2
        echo "  --no-ocr  skip the OCR pass (fast, but leaves no searchable text)" >&2
        echo "" >&2
        echo "Prints the path of the resulting PDF on stdout." >&2
      }

      while [ $# -gt 0 ]; do
        case "$1" in
          --force)   force=1; shift ;;
          --no-ocr)  ocr=0; shift ;;
          -h|--help) usage; exit 0 ;;
          -*)        echo "djvu2pdf: unknown option $1" >&2; usage; exit 2 ;;
          *)         if [ -z "$src" ]; then src="$1"; else dst="$1"; fi; shift ;;
        esac
      done

      if [ -z "$src" ]; then
        usage
        exit 2
      fi
      if [ ! -r "$src" ]; then
        echo "djvu2pdf: cannot read $src" >&2
        exit 1
      fi
      if [ -z "$dst" ]; then
        dst="''${src%.[dD][jJ][vV]*}.pdf"
      fi

      # Up to date already: report the cached PDF and stop.
      if [ "$force" -eq 0 ] && [ -s "$dst" ] && [ "$dst" -nt "$src" ]; then
        echo "$dst"
        exit 0
      fi

      jobs=$(( $(nproc) - 2 ))
      if [ "$jobs" -lt 1 ]; then
        jobs=1
      fi

      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      # ddjvu emits benign libtiff IFD warnings on stderr; the exit code is what matters.
      nice -n 15 ddjvu -format=pdf -quality=85 -skip "$src" "$tmp/img.pdf" 2>/dev/null

      if [ "$ocr" -eq 1 ]; then
        # --skip-text keeps the run idempotent if a page ever arrives with text.
        nice -n 15 ocrmypdf --optimize 1 --output-type pdf --skip-text \
          --jobs "$jobs" "$tmp/img.pdf" "$tmp/out.pdf"
      else
        mv "$tmp/img.pdf" "$tmp/out.pdf"
      fi

      mv "$tmp/out.pdf" "$dst"
      echo "$dst"
    '';
  };

  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. Their paper sits around 60%
  # grey, so the book reads as muddy. Whitening only the background layer fixes
  # that and leaves the text bit-for-bit untouched, because the mask is never
  # rewritten -- far better than re-rendering pages and levelling them, which
  # softens the type and discards the MRC compression.
  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. That structure is why they
  # need whitening, why they scroll badly, and why the text can be left
  # untouched while the paper is rewritten. DuXiu scans are one bitonal image
  # per page: already white and fast, usually just missing OCR. pdf-prep works
  # out which of those it is and does only the parts that file needs.
  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. That structure is why they
  # need whitening, why they scroll badly, and why the text can be left
  # untouched while the paper is rewritten. DuXiu scans are one bitonal image
  # per page: already white and fast, usually just missing OCR. pdf-prep works
  # out which of those it is and does only the parts that file needs.
  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. That structure is why they
  # need whitening, why they scroll badly, and why the text can be left
  # untouched while the paper is rewritten. DuXiu scans are one bitonal image
  # per page: already white and fast, usually just missing OCR. pdf-prep works
  # out which of those it is and does only the parts that file needs.
  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. That structure is why they
  # need whitening, why they scroll badly, and why the text can be left
  # untouched while the paper is rewritten. DuXiu scans are one bitonal image
  # per page: already white and fast, usually just missing OCR. pdf-prep works
  # out which of those it is and does only the parts that file needs.
  # Internet Archive scans layer each page as a low-resolution RGB background
  # (the paper, plus any continuous-tone photo) with the ink painted over it
  # through a high-resolution JBIG2 stencil mask. That structure is why they
  # need whitening, why they scroll badly, and why the text can be left
  # untouched while the paper is rewritten. DuXiu scans are one bitonal image
  # per page: already white and fast, usually just missing OCR. pdf-prep works
  # out which of those it is and does only the parts that file needs.
  pdfPrepScript = pkgs.writeText "pdf-prep.py" ''
    """Make a scanned PDF pleasant to read: white paper, fast scrolling, selectable text.

    Works out what the file actually needs rather than applying everything blindly.

    Internet Archive scans layer each page as a low-resolution RGB background (the paper,
    plus any continuous-tone photo) with the ink painted over it through a high-resolution
    JBIG2 stencil mask. That structure is why they need whitening (their paper can sit at
    60% grey) and why they scroll badly (a 10 megapixel JPEG 2000 decoded per page just to
    supply ink colour). DuXiu scans are a single bitonal image per page: already white,
    already fast, and usually just missing OCR.
    """
    import argparse
    import hashlib
    import io
    import os
    import shutil
    import sqlite3
    import subprocess
    import sys
    import tempfile
    import zlib

    import fitz
    import numpy as np
    import pikepdf
    from PIL import Image

    PAPER_FLOOR = 40     # a channel's paper level cannot sensibly fall below this
    MIN_BG_DIM = 1500    # a "background" wider than this is really a full-page image
    ALREADY_WHITE = 245  # paper at least this bright is done; touching it only degrades
    TEXT_PER_PAGE = 50   # a page with fewer characters than this counts as untexted
    SIOYEK_DB = os.environ.get("PDF_PREP_SIOYEK_DB",
                               os.path.expanduser("~/.local/share/sioyek/shared.db"))

    # Every one of these columns holds a document checksum, not a filesystem path.
    SIOYEK_KEYS = (("highlights", "document_path"), ("bookmarks", "document_path"),
                   ("marks", "document_path"), ("opened_books", "path"),
                   ("links", "src_document"), ("links", "dst_document"))


    def md5_of(path):
        h = hashlib.md5()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()


    def migrate_sioyek(old_sum, new_sum):
        """Re-point Sioyek's annotations at the rewritten file.

        Sioyek identifies a document by the MD5 of its entire contents, so *any* edit
        orphans its highlights, bookmarks and marks even though the pages are
        unchanged. Nothing here alters page geometry -- only the images inside each
        page -- so the stored coordinates stay valid and just need re-keying.
        """
        if old_sum == new_sum or not os.path.exists(SIOYEK_DB):
            return {}
        moved = {}
        con = sqlite3.connect(SIOYEK_DB)
        try:
            for table, col in SIOYEK_KEYS:
                try:
                    n = con.execute("SELECT COUNT(*) FROM %s WHERE %s=?" % (table, col),
                                    (old_sum,)).fetchone()[0]
                except sqlite3.Error:
                    continue
                if not n:
                    continue
                # OR REPLACE: opened_books.path and marks are UNIQUE, so a row already
                # keyed to the new checksum would otherwise abort the update.
                con.execute("UPDATE OR REPLACE %s SET %s=? WHERE %s=?" % (table, col, col),
                            (new_sum, old_sum))
                moved["%s.%s" % (table, col)] = n
            con.commit()
        finally:
            con.close()
        return moved


    # ---------------------------------------------------------------- tone helpers

    def paper_levels(rgb):
        """Per-channel paper level, measured over ONE shared set of paper pixels.

        The level is taken at the lower edge of the paper's distribution, not at a high
        percentile: a percentile lifts only the brightest tail and leaves the bulk of the
        paper visibly grey.

        Crucially the paper pixels are chosen once, by luminance, and every channel is
        then read over that same set. Letting each channel find its own mode lets them
        latch onto different features on a photo-heavy page -- paper in one channel, a
        photo highlight in another -- which produced gains like (1.67, 1.40, 1.76) and
        tinted whole pages purple.
        """
        grey = rgb.mean(axis=2)
        lo = PAPER_FLOOR
        hist = np.bincount(grey.astype(np.uint8).ravel(), minlength=256)
        band = hist[lo:]
        if band.sum() == 0:
            return [float(max(np.percentile(rgb[..., c], 99), lo)) for c in range(3)]
        mode = int(np.argmax(band)) + lo
        sel = (grey >= mode - 15) & (grey <= mode + 15)
        if sel.sum() < 0.02 * grey.size:      # too few: widen rather than guess
            sel = grey >= mode - 30
        out = []
        for c in range(3):
            v = rgb[..., c][sel].astype(np.float32)
            out.append(float(max(lo, v.mean() - 3.0 * max(v.std(), 2.0))))
        return out


    def background_image(imgs):
        """The paper layer: the image with no soft mask.

        Not simply the smallest image. In an MRC page the foreground carries the JBIG2
        stencil as its /SMask and the background does not, and once --fast has shrunk
        that foreground to a thumbnail it becomes the smallest image on the page. A
        size-based rule would then pick the ink-colour layer and whiten *that*,
        wrecking the page on a second run.
        """
        plain = [i for i in imgs if i[1] == 0]
        if not plain:
            return None
        return min(plain, key=lambda i: i[2] * i[3])


    def has_picture(rgb):
        """Is there a real picture in this layer, or only paper?

        Absolute high-frequency energy does not port between scans: one book's blank
        pages score 0.4 and another's 2.0, so any fixed cut either flattens pages that
        hold a photograph or leaves the other book's gradient in place. Both measures
        here are scale-free.

        darkfrac -- in an MRC background the text lives in the mask, so anything much
        darker than the paper IS a picture. Measured: photographs 0.15, a faint figure
        0.007, blank pages 0.000-0.001.

        tileratio -- how localised the fine detail is. A photograph is concentrated in
        part of the page; scanner noise is spread evenly. Measured: photographs 37-46,
        a faint figure 10, blank pages 1.2-3.5.
        """
        grey = rgb.mean(axis=2)
        hist = np.bincount(grey.astype(np.uint8).ravel(), minlength=256)
        mode = int(np.argmax(hist[120:])) + 120
        if float((grey < mode - 45).mean()) > 0.003:
            return True

        im = Image.fromarray(grey.astype(np.uint8), "L")
        small = im.resize((max(1, im.width // 16), max(1, im.height // 16)), Image.BILINEAR)
        blur = np.asarray(small.resize(im.size, Image.BILINEAR), dtype=np.float32)
        resid = grey - blur
        h, w = resid.shape
        th, tw = max(1, h // 12), max(1, w // 12)
        e = np.array([resid[i:i + th, j:j + tw].std()
                      for i in range(0, h - th + 1, th)
                      for j in range(0, w - tw + 1, tw)])
        med = float(np.median(e))
        if med < 0.05:
            # Already flat everywhere; a ratio here would divide by ~zero.
            return float(e.max()) > 2.0
        return float(np.percentile(e, 95) / med) > 6.0


    def gain_lut(white_point):
        """Linear white balance -- what the scanner should have done."""
        lut = np.arange(256, dtype=np.float32) * (255.0 / max(white_point, 1.0))
        return np.clip(lut, 0, 255).astype(np.uint8)


    def balance_and_deepen(rgb, levels, gamma=1.8):
        """White-balance a layer that holds both ink and paper, then restore ink density.

        A fixed luminance knee cannot be used here. On strongly yellowed paper the blue
        channel sits *below* the knee, so red and green get lifted to white while blue is
        left untouched -- turning a mild yellow into a vivid one (measured: paper coming
        out rgb(254,254,97)).

        So balance each channel against its own paper level first, which makes the paper
        neutral white whatever its tint. That lifts the ink too, so a gamma then pulls the
        midtones back down: white stays white, and the text returns to roughly its
        original density instead of washing out to grey.
        """
        out = np.empty_like(rgb)
        for c in range(3):
            out[..., c] = gain_lut(levels[c])[rgb[..., c]]
        lut = (255.0 * (np.arange(256, dtype=np.float32) / 255.0) ** gamma)
        return np.clip(lut, 0, 255).astype(np.uint8)[out]


    # ------------------------------------------------------------------- analysis

    def survey(path):
        """Report what this file is and what it needs."""
        doc = fitz.open(path)
        pages = len(doc)
        texted = 0
        mrc = 0
        fat_fg = 0
        dpis = []
        tinted = 0
        sampled = 0
        step = max(1, pages // 40)
        for pno in range(pages):
            page = doc[pno]
            if len(page.get_text().strip()) >= TEXT_PER_PAGE:
                texted += 1
            if pno % step:
                continue
            sampled += 1
            imgs = page.get_images(full=True)
            if not imgs:
                continue
            if len(imgs) >= 2 and min(i[2] for i in imgs) < MIN_BG_DIM:
                mrc += 1
            # get_images tuples are (xref, smask, width, height, ...): a wide image
            # carrying a soft mask is the costly JPEG 2000 colour layer. If it has
            # already been shrunk there is no speed left to win.
            if any(i[1] != 0 and i[2] >= MIN_BG_DIM for i in imgs):
                fat_fg += 1
            big = max(imgs, key=lambda i: i[2] * i[3])
            width_in = page.rect.width / 72.0
            if width_in > 0:
                dpis.append(big[2] / width_in)
            pix = page.get_pixmap(dpi=36)
            a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(
                pix.height, pix.width, pix.n)[..., :3].astype(np.float32)
            m = a.mean(axis=2) > 170          # paper, excluding the ink
            if m.sum() >= 100:
                paper = [float(a[..., c][m].mean()) for c in range(3)]
                # Dim-but-neutral is just dense text dragging the average down; a
                # spread between channels is a real tint.
                if max(paper) - min(paper) > 3 or min(paper) < 235:
                    tinted += 1
        doc.close()
        return {
            "pages": pages,
            "texted": texted,
            "needs_ocr": texted < pages * 0.5,
            "is_mrc": bool(sampled and mrc > sampled * 0.5),
            "needs_fast": bool(sampled and fat_fg > sampled * 0.5),
            "dpi": int(np.median(dpis)) if dpis else 0,
            "needs_whiten": bool(sampled and tinted > sampled * 0.2),
        }


    # ------------------------------------------------------------------ whitening

    def whiten(path, dst):
        doc = fitz.open(path)
        white = curved = alone = 0
        for pno in range(len(doc)):
            page = doc[pno]
            imgs = page.get_images(full=True)
            if not imgs:
                continue
            small = background_image(imgs)
            if small is None:
                alone += 1
                continue
            xref, w, h = small[0], small[2], small[3]
            try:
                raw = doc.extract_image(xref)
                pix = fitz.Pixmap(raw["image"])
                if pix.n > 3:
                    pix = fitz.Pixmap(fitz.csRGB, pix)
                a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(
                    pix.height, pix.width, pix.n)
            except Exception:
                alone += 1
                continue

            # A bitonal or greyscale scan arrives with a single channel; widen it so
            # everything below can assume three, and save it back as grey.
            is_grey = a.shape[2] == 1
            rgb = np.repeat(a, 3, axis=2) if is_grey else a[..., :3]
            grey = rgb.mean(axis=2)

            if w > MIN_BG_DIM:
                # No MRC split: ink and paper share one image. Judge colour by a high
                # percentile of saturation, not its mean -- a cover is mostly pale
                # artwork around one saturated block, which drags the mean down to
                # text-page levels. Measured, covers sit at 112-176 and text pages at
                # 0-23. No upper bound on p99: an already-light page still needs the
                # last push.
                p99 = float(np.percentile(grey, 99))
                sat_p95 = float(np.percentile(rgb.max(axis=2) - rgb.min(axis=2), 95))
                if not (grey.mean() > 120 and p99 >= 130 and sat_p95 < 60):
                    alone += 1
                    continue
                levels = paper_levels(rgb)
                if min(levels) >= ALREADY_WHITE:
                    alone += 1
                    continue
                out = balance_and_deepen(rgb, levels)
                buf = io.BytesIO()
                if is_grey:
                    Image.fromarray(out[..., 0], "L").save(buf, "JPEG", quality=85)
                else:
                    Image.fromarray(out, "RGB").save(buf, "JPEG", quality=85)
                page.replace_image(xref, stream=buf.getvalue())
                curved += 1
                continue

            if not has_picture(rgb):
                # Paper only, however unevenly it was lit: flatten it outright. A gain
                # would keep the shading, and any colour in it, which is what left
                # tinted bands along the bottom of these pages.
                buf = io.BytesIO()
                Image.new("L", (w, h), 255).save(buf, "PNG")
                page.replace_image(xref, stream=buf.getvalue())
                white += 1
            else:
                # Balance each channel separately. Scanned paper is warm, so one
                # luminance curve drives red to 255 while blue lags, turning the paper
                # yellow instead of white.
                levels = paper_levels(rgb)
                if min(levels) >= ALREADY_WHITE:
                    alone += 1
                    continue
                out = np.empty_like(rgb)
                for c in range(3):
                    out[..., c] = gain_lut(levels[c])[rgb[..., c]]
                buf = io.BytesIO()
                if is_grey:
                    Image.fromarray(out[..., 0], "L").save(buf, "JPEG", quality=88)
                else:
                    Image.fromarray(out, "RGB").save(buf, "JPEG", quality=88, subsampling=0)
                page.replace_image(xref, stream=buf.getvalue())
                curved += 1

        fitz.TOOLS.mupdf_display_errors(False)
        doc.save(dst, garbage=4, deflate=True)
        fitz.TOOLS.mupdf_display_errors(True)
        doc.close()
        return white, curved, alone


    # ----------------------------------------------------------------- speed pass

    def slim_foregrounds(path, max_side=128):
        """Shrink the MRC foreground, which is only a smooth field of ink colour.

        Decoding ten megapixels of JPEG 2000 per page is what makes these files crawl.
        The stencil carries the letter shapes, and PDF lets a soft mask have different
        pixel dimensions from the image it masks, so the colour field can shrink to a
        thumbnail while the text stays exactly as sharp.

        Must be pikepdf: PyMuPDF's replace_image drops /SMask, losing the stencil and
        painting each page a solid black smear.
        """
        pdf = pikepdf.open(path, allow_overwriting_input=True)
        slimmed = 0
        for page in pdf.pages:
            xobjs = page.get("/Resources", {}).get("/XObject", {})
            for _, obj in dict(xobjs).items():
                if obj.get("/Subtype") != "/Image" or "/SMask" not in obj:
                    continue
                w, h = int(obj.Width), int(obj.Height)
                if w < MIN_BG_DIM or max(w, h) <= max_side:
                    continue
                try:
                    im = Image.open(io.BytesIO(obj.read_raw_bytes())).convert("RGB")
                except Exception:
                    continue
                scale = max_side / float(max(w, h))
                small = im.resize((max(1, int(w * scale)), max(1, int(h * scale))),
                                  Image.BILINEAR)
                obj.write(zlib.compress(np.asarray(small, dtype=np.uint8).tobytes()),
                          filter=pikepdf.Name("/FlateDecode"))
                obj.Width, obj.Height = small.width, small.height
                obj.ColorSpace = pikepdf.Name("/DeviceRGB")
                obj.BitsPerComponent = 8
                for k in ("/DecodeParms", "/Decode"):
                    if k in obj:
                        del obj[k]
                slimmed += 1
        pdf.save(path)
        return slimmed


    # ------------------------------------------------------------------------ OCR

    def run_ocr(src, dst, dpi):
        cmd = ["ocrmypdf", "--skip-text", "--optimize", "0",
               "--jobs", str(max(1, (os.cpu_count() or 4) - 2))]
        # Tesseract wants about 300 dpi; upscale a coarser scan before recognition.
        if dpi and dpi < 300:
            cmd += ["--oversample", "300"]
        cmd += [src, dst]
        subprocess.run(cmd, check=True)


    # --------------------------------------------------------------------- verify

    def verify(path):
        """Measure the result -- a rendered page can look lighter than it truly is.

        Per channel, because a greyscale check passes a page whose paper has gone
        yellow: red hits 255 while blue lags far behind.
        """
        doc = fitz.open(path)
        tinted = []
        for pno in range(len(doc)):
            pix = doc[pno].get_pixmap(dpi=36)
            a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(
                pix.height, pix.width, pix.n)[..., :3]
            paper = [float(np.percentile(a[..., c], 98)) for c in range(3)]
            if min(paper) < 240:
                tinted.append(pno + 1)
        npages = len(doc)
        chars = sum(len(doc[p].get_text()) for p in range(npages))
        doc.close()
        return npages, tinted, chars


    def main():
        ap = argparse.ArgumentParser(
            prog="pdf-prep",
            description="Whiten the paper, speed up scrolling and OCR a scanned PDF, "
                        "doing only the parts the file actually needs.")
        ap.add_argument("input")
        ap.add_argument("output", nargs="?",
                        help="default: <input>-prep.pdf beside the source")
        ap.add_argument("--in-place", action="store_true", help="overwrite the input")
        ap.add_argument("--dry-run", action="store_true",
                        help="report what would be done, writing nothing")
        ap.add_argument("--no-ocr", action="store_true")
        ap.add_argument("--no-whiten", action="store_true")
        ap.add_argument("--no-fast", action="store_true")
        ap.add_argument("--force-ocr", action="store_true",
                        help="OCR even if the file already has a text layer")
        ap.add_argument("--force-whiten", action="store_true",
                        help="run the whiten pass even if the survey sees little to do; "
                             "harmless, since already-white pages are skipped")
        ap.add_argument("--no-migrate", action="store_true",
                        help="do not move Sioyek's highlights onto the new file")
        args = ap.parse_args()

        if not os.path.isfile(args.input):
            sys.exit("pdf-prep: cannot read " + args.input)
        if args.output and args.in_place:
            sys.exit("pdf-prep: give an output path or --in-place, not both")

        stem, ext = os.path.splitext(args.input)
        dst = args.output or (args.input if args.in_place else stem + "-prep" + ext)

        src_sum = md5_of(args.input)
        s = survey(args.input)
        kind = "Internet Archive (MRC layered)" if s["is_mrc"] else "single image per page"
        print("%d pages, %s, about %d dpi" % (s["pages"], kind, s["dpi"]))
        print("  text layer : %s (%d of %d pages)"
              % ("missing" if s["needs_ocr"] else "present", s["texted"], s["pages"]))
        print("  paper      : %s" % ("tinted" if s["needs_whiten"] else "already white"))

        do_whiten = (s["needs_whiten"] or args.force_whiten) and not args.no_whiten
        do_fast = s["needs_fast"] and not args.no_fast
        do_ocr = (s["needs_ocr"] or args.force_ocr) and not args.no_ocr
        plan = [n for n, on in (("whiten", do_whiten), ("fast", do_fast), ("ocr", do_ocr)) if on]
        print("  plan       : %s" % (", ".join(plan) if plan else "nothing to do"))

        if args.dry_run:
            print("dry run: nothing written")
            return
        if not plan:
            print("nothing to do")
            return

        workdir = os.path.dirname(os.path.abspath(dst)) or "."
        fd, tmp = tempfile.mkstemp(suffix=".pdf", dir=workdir)
        os.close(fd)
        try:
            if do_whiten:
                w, c, a = whiten(args.input, tmp)
                print("whiten: %d pages to white, %d balanced, %d left alone" % (w, c, a))
            else:
                shutil.copyfile(args.input, tmp)

            if do_fast:
                print("fast: shrank the colour layer on %d pages (text untouched)"
                      % slim_foregrounds(tmp))

            if do_ocr:
                # OCR last so it sees the whitened images, and --optimize 0 so it does
                # not re-encode the work above.
                fd2, tmp2 = tempfile.mkstemp(suffix=".pdf", dir=workdir)
                os.close(fd2)
                try:
                    run_ocr(tmp, tmp2, s["dpi"])
                    os.replace(tmp2, tmp)
                except subprocess.CalledProcessError as exc:
                    os.path.exists(tmp2) and os.unlink(tmp2)
                    sys.exit("pdf-prep: ocrmypdf failed (%s)" % exc.returncode)

            npages, tinted, chars = verify(tmp)
            print("verify: all %d pages render; %d still tinted; %d characters of text"
                  % (npages, len(tinted), chars))
            if tinted:
                print("  tinted pages: %s%s"
                      % (tinted[:10], " ..." if len(tinted) > 10 else ""))
            shutil.move(tmp, dst)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

        if not args.no_migrate:
            moved = migrate_sioyek(src_sum, md5_of(dst))
            if moved:
                print("sioyek: moved %s onto the new file"
                      % ", ".join("%d %s" % (n, k.split(".")[0]) for k, n in moved.items()))
                print("  (close Sioyek before running this, or it may write back stale state)")

        print(dst)


    if __name__ == "__main__":
        main()
  '';

  pdfPrep = pkgs.writeShellApplication {
    name = "pdf-prep";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: with ps; [ pymupdf numpy pillow pikepdf ]))
      pkgs.ocrmypdf
      pkgs.tesseract
    ];
    text = ''
      exec python3 ${pdfPrepScript} "$@"
    '';
  };

  # Sioyek has no area-screenshot command, but a custom command containing
  # %{selected_rect} makes it prompt for a rectangle and then hand over
  # "page,x0,y0,x1,y1" in MuPDF document space -- page-relative points, which
  # is exactly what PyMuPDF's clip argument wants. Sioyek runs custom commands
  # through QProcess with an argv list rather than a shell, so a substituted
  # path keeps its spaces without any quoting.
  sioyekSnipScript = pkgs.writeText "sioyek-snip.py" ''
    """Crop the rectangle Sioyek just selected into a PNG.

    Sioyek has no area-screenshot command, but a custom command containing
    %{selected_rect} makes it prompt for a rectangle and then hands over
    "page,x0,y0,x1,y1" in MuPDF document space -- page-relative points, the very
    coordinates PyMuPDF's clip argument wants. Rendering through PyMuPDF rather than
    converting to pixels for an external cropper keeps page rotation and a non-zero
    MediaBox origin correct for free.
    """
    import os
    import shutil
    import subprocess
    import sys
    import time

    import fitz

    DPI = int(os.environ.get("SIOYEK_SNIP_DPI", "300"))
    OUTDIR = os.path.expanduser(os.environ.get("SIOYEK_SNIP_DIR", "~/Pictures/Screenshots"))


    def notify(summary, body, urgency="normal"):
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "-a", "Sioyek", "-u", urgency,
                            "-i", "applets-screenshooter", summary, body], check=False)


    def main():
        if len(sys.argv) < 3:
            sys.exit("usage: sioyek-snip <page,x0,y0,x1,y1> <document.pdf>")
        rect_arg, path = sys.argv[1], sys.argv[2]

        try:
            page_no, x0, y0, x1, y1 = (float(v) for v in rect_arg.split(","))
        except ValueError:
            sys.exit("sioyek-snip: cannot parse rect %r" % rect_arg)

        if not os.path.isfile(path):
            sys.exit("sioyek-snip: cannot read " + path)

        doc = fitz.open(path)
        page = doc[int(page_no)]
        clip = fitz.Rect(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        clip = clip & page.rect                      # a drag can run past the page edge
        if clip.is_empty:
            notify("Snip failed", "The selection was empty.", "critical")
            sys.exit("sioyek-snip: empty selection")

        pix = page.get_pixmap(clip=clip, dpi=DPI)
        os.makedirs(OUTDIR, exist_ok=True)
        stem = os.path.splitext(os.path.basename(path))[0][:60]
        out = os.path.join(OUTDIR, "%s-p%d-%s.png"
                           % (stem, int(page_no) + 1, time.strftime("%Y%m%d-%H%M%S")))
        pix.save(out)
        doc.close()

        copied = ""
        if shutil.which("wl-copy"):
            # Do not wait on wl-copy: on Wayland the copier has to stay resident to
            # serve the selection, so waiting for it never returns.
            with open(out, "rb") as fh:
                subprocess.Popen(["wl-copy", "-t", "image/png"], stdin=fh,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            copied = " and copied to the clipboard"

        notify("Snipped page %d" % (int(page_no) + 1),
               "%dx%d px at %d dpi%s" % (pix.width, pix.height, DPI, copied))
        print(out)


    if __name__ == "__main__":
        main()
  '';

  sioyekSnip = pkgs.writeShellApplication {
    name = "sioyek-snip";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: with ps; [ pymupdf ]))
      pkgs.wl-clipboard
      pkgs.libnotify
    ];
    text = ''
      exec python3 ${sioyekSnipScript} "$@"
    '';
  };
in
{
  imports = [];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = ["i2c-dev"];
    initrd.kernelModules = ["nvidia"];
    extraModulePackages = [
      config.boot.kernelPackages.nvidia_x11
    ];
    kernelParams = [
      "quiet"
      "splash"
      "intremap=on"
      "boot.shell_on_fail"
      "udev.log_priority=3"
      "rd.systemd.show_status=auto"
    ];
    # silence first boot output
    consoleLogLevel = 3;
    initrd.verbose = false;
    initrd.systemd.enable = true;

    # plymouth, showing after LUKS unlock
    plymouth.enable = true;
    plymouth.font = "${pkgs.hack-font}/share/fonts/truetype/Hack-Regular.ttf";
    plymouth.logo = "${./assets/nix-snowflake-rainbow.png}";
  };

    # Boot console mode
  boot.loader = {
    systemd-boot.consoleMode = "max";
    systemd-boot.enable = false;
    grub.enable = true;
    grub.device = "nodev";
    grub.useOSProber = true;
    grub.efiSupport = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot";
    grub2-theme = {
      enable = true;
      theme = "stylish";
      footer = true;
    };
  };

  services.udev.extraRules = ''
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
    # Disable USB autosuspend for Logitech G502X
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c099", ATTR{power/autosuspend}="-1"
    # Trigger USB reset service when G502X is detected
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c099", TAG+="systemd", ENV{SYSTEMD_WANTS}="logitech-g502x-reset.service"
  '';

  # Group-writable backlight devices so waybar's backlight/slider (which writes
  # /sys/class/backlight/<dev>/brightness directly) works without root.
  # Covers intel_backlight on M90aPro and ddcciN on X299 hosts.
  services.udev.packages = [ pkgs.brightnessctl gproLedSioyek ];

  # Console font configuration
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-i20n.psf.gz";
  console.packages = with pkgs; [ terminus_font ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "thinky" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB
  # Leave CPU and memory headroom for the desktop during source builds.
  nix.settings.max-jobs = 2;
  nix.settings.cores = 2;
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  # Limit boot entries to prevent /boot from filling up
  boot.loader.grub.configurationLimit = 50;

  hardware.i2c.enable = true;

  # Logitech wireless/wired device support (G502X, PRO Gaming Keyboard)
  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;  # Solaar GUI/device access

  # GVFS for Nemo trash, network mounts, etc.
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # power-profiles-daemon: lets AGS Control Center cycle balanced /
  # performance / power-saver via AstalPowerProfiles (DBus).
  services.power-profiles-daemon.enable = true;


  # USB reset for Logitech G502X (triggered by udev when device appears)
  systemd.services.logitech-g502x-reset = {
    description = "Reset Logitech G502X USB to fix scroll wheel";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "g502x-reset" ''
        sleep 5
        for dev in /sys/bus/usb/devices/*/idProduct; do
          if [ "$(cat "$dev" 2>/dev/null)" = "c099" ]; then
            devpath=$(dirname "$dev")
            echo "Resetting Logitech G502X at $devpath"
            echo 0 > "$devpath/authorized"
            sleep 2
            echo 1 > "$devpath/authorized"
          fi
        done
      '';
    };
  };

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Asia/Singapore";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_SG.UTF-8";
  i18n.supportedLocales = [
    "en_SG.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "zh_CN.UTF-8/UTF-8"
  ];
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_SG.UTF-8";
    LC_IDENTIFICATION = "en_SG.UTF-8";
    LC_MEASUREMENT = "en_SG.UTF-8";
    LC_MONETARY = "en_SG.UTF-8";
    LC_NAME = "en_SG.UTF-8";
    LC_NUMERIC = "en_SG.UTF-8";
    LC_PAPER = "en_SG.UTF-8";
    LC_TELEPHONE = "en_SG.UTF-8";
    LC_TIME = "en_SG.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    xkb.layout = "us";
    xkb.variant = "";
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    package = pkgs.kdePackages.sddm;
    extraPackages = with pkgs; [
      kdePackages.qtsvg
      kdePackages.qtmultimedia
      kdePackages.qtvirtualkeyboard
    ];
    theme = "sddm-astronaut-theme";
    settings = {
      General = {
        DefaultSession = "hyprland-uwsm.desktop";
      };
      Theme = {
        Current = "sddm-astronaut-theme";
        # Picked-up by sddm-random-theme.service: a writable mirror of the
        # astronaut theme dir lives here, with metadata.desktop rewritten
        # to point at a random Themes/<variant>.conf each boot.
        ThemeDir = "/var/lib/sddm/themes";
      };
    };
  };

  # Pick a random sddm-astronaut variant before SDDM starts. Mirrors the
  # upstream theme dir into /var/lib/sddm/themes/sddm-astronaut-theme/ as
  # symlinks, then writes a fresh metadata.desktop pointing at a random
  # *.conf from Themes/.
  systemd.services.sddm-random-theme = {
    description = "Pick a random sddm-astronaut variant for the login screen";
    wantedBy = [ "display-manager.service" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
    script = ''
      set -eu
      src=${astronautPkg}/share/sddm/themes/sddm-astronaut-theme
      dst=/var/lib/sddm/themes/sddm-astronaut-theme
      mkdir -p "$dst"
      # Mirror everything from upstream as symlinks, except metadata.desktop
      # which we generate.
      for f in "$src"/* "$src"/.[!.]*; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        [ "$name" = metadata.desktop ] && continue
        ln -sfn "$f" "$dst/$name"
      done
      # Pick a random *.conf (the *.conf.user override files are excluded
      # by the .conf$ anchor).
      mapfile -t variants < <(ls "$src/Themes/" | grep '\.conf$')
      pick=''${variants[RANDOM % ''${#variants[@]}]}
      sed "s|^ConfigFile=.*|ConfigFile=Themes/$pick|" \
        "$src/metadata.desktop" > "$dst/metadata.desktop"
      echo "sddm-random-theme: picked $pick" >&2
    '';
  };

  programs.uwsm = {
    enable = true;
    waylandCompositors = {
      hyprland = {
        prettyName = "Hyprland";
        comment = "Hyprland compositor managed by UWSM";
        binPath = "/run/current-system/sw/bin/start-hyprland";
      };
    };
  };

  programs.hyprland = {
    enable = true;
    withUWSM = true; # recommended for most users
    xwayland.enable = true; # Xwayland can be disabled.
  };

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = false;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
    config = {
      common = {
        default = [ "hyprland" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.Print" = [ "gtk" ];
      };
      hyprland = {
        default = [ "hyprland" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.AppChooser" = [ "gtk" ];
        "org.freedesktop.impl.portal.Print" = [ "gtk" ];
      };
    };
  };

  systemd.user.services.xdg-desktop-portal-gtk = {
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Environment = [
        "GDK_BACKEND=wayland"
        "DISPLAY="
        "WAYLAND_DISPLAY=wayland-1"
        "XDG_CURRENT_DESKTOP=Hyprland"
        "XDG_SESSION_TYPE=wayland"
        "XDG_DATA_DIRS=%h/.nix-profile/share:/nix/profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share:/run/current-system/sw/share"
      ];
    };
  };

  systemd.user.services.xdg-desktop-portal = {
    after = [ "xdg-desktop-portal-gtk.service" ];
    wants = [ "xdg-desktop-portal-gtk.service" ];
    serviceConfig = {
      Environment = [
        "XDG_CURRENT_DESKTOP=Hyprland"
        "XDG_SESSION_TYPE=wayland"
        "XDG_DATA_DIRS=%h/.nix-profile/share:/nix/profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share:/run/current-system/sw/share"
      ];
    };
  };

  programs.dconf.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.brlaser ];

  hardware.sane = {
    enable = true;
    brscan4.enable = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
  
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  # Required for bubblewrap-based FHS env (EasyConnect launcher).
  security.unprivilegedUsernsClone = true;
  boot.kernel.sysctl."user.max_user_namespaces" = 15000;
  security.wrappers.bwrap = {
    source = "${pkgs.bubblewrap}/bin/bwrap";
    owner = "root";
    group = "root";
    setuid = true;
  };
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  systemd.user.services.orca.enable = false;

  services.upower.enable = true;
  services.gnome.gnome-keyring.enable = true;

  security.sudo = {
    enable = true;
    extraRules = [
      {
        users = [ "thinky" ];
        commands = [
          {
            command = "ALL"; # Allows all commands
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.thinky = {
    isNormalUser = true;
    description = "thinky";
    extraGroups = [ "networkmanager" "wheel" "i2c" "scanner" "lp" "video" ];
    subGidRanges = [
      {
        count = 65536;
        startGid = 100000;
      }
    ];
    subUidRanges = [
      {
        count = 65536;
        startUid = 100000;
      }
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
    
  };

  # Allow only the specific unfree packages we intentionally use.
  nixpkgs.config.allowUnfreePredicate = pkg:
    let
      name = lib.getName pkg;
      licenses = lib.toList (pkg.meta.license or []);
      hasCudaEula = lib.any (license:
        (license.fullName or "") == "CUDA EULA"
        || (license.shortName or "") == "CUDA EULA"
      ) licenses;
    in
      builtins.elem name [
        "brother-udev-rule-type1"
        "brscan4"
        "claude-code"
        "claude-monitor"
        "codex"
        "corefonts"
        "megasync"
        "nvidia-settings"
        "nvidia-x11"
        "proton-vpn"
        "zoom"
        # Unfree firmware pulled in by hardware.enableAllFirmware on the
        # PortableSSD host (broad device coverage for booting any machine).
        "broadcom-bt-firmware"
        "b43-firmware"
        "xone-dongle-firmware"
        "facetimehd-firmware"
        "facetimehd-calibration"
      ]
      || lib.hasPrefix "brscan4" name
      || hasCudaEula;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [

    # ── Archive & Compression ──
    zip                        # Create ZIP archives
    unzip                      # Extract ZIP archives
    xz                         # XZ/LZMA compression
    p7zip                      # 7-Zip archive manager
    zstd                       # Zstandard fast compression
    gnutar                     # GNU tar archiver
    peazip                     # Free archive manager utility

    # ── Core Utilities ──
    file                       # Determine file types
    which                      # Locate commands in PATH
    dpkg                       # Debian package extractor (for .deb)
    tree                       # Directory listing as tree
    gnused                     # GNU stream editor
    gawk                       # GNU pattern processing language
    gnupg                      # GnuPG encryption and signing
    wget                       # Download files from the web
    yq-go                      # YAML/JSON/XML processor (CLI)
    yt-dlp                    # Download video (NASA APOD video days)

    # ── Networking & Diagnostics ──
    networkmanager             # Network connection manager
    mtr                        # Traceroute + ping network diagnostic
    iperf3                     # Network bandwidth measurement
    dnsutils                   # DNS tools: dig, nslookup
    ldns                       # DNS tool: drill (dig alternative)
    aria2                      # Multi-protocol download utility
    socat                      # Multipurpose network relay (netcat replacement)
    nmap                       # Network discovery and security scanner
    ipcalc                     # IPv4/IPv6 subnet calculator
    traceroute                 # Trace packet route to host
    inetutils                  # Basic networking tools (ftp, telnet, etc.)
    ethtool                    # Ethernet device configuration
    filezilla                  # GUI FTP/SFTP client
    remmina                    # Remote desktop client
    freerdp                    # RDP implementation (needed for Remmina RDP plugins)
    python3
    python3Packages.pygobject3
    gtk3
    spice-protocol             # Needed for some clipboard sync features
    proton-vpn                 # ProtonVPN graphical client
    onlyoffice-desktopeditors  # ONLYOFFICE desktop editors

    # ── System Monitoring & Debugging ──
    sysstat                    # System performance tools (iostat, mpstat, sar)
    lm_sensors                 # Hardware sensor monitoring (sensors command)
    iotop                      # I/O usage monitor per process
    iftop                      # Network bandwidth monitor per connection
    strace                     # System call tracer
    ltrace                     # Library call tracer
    lsof                       # List open files and sockets
    pciutils                   # PCI device info (lspci)
    usbutils                   # USB device info (lsusb)
    lshw                       # Detailed hardware listing
    python3Packages.gpustat    # GPU usage monitor (NVIDIA) — CLI/JSON. (nixpkgs's bare `gpustat` is the unrelated Rust GUI tool.)
    upower                     # Battery and power device info
    mission-center             # GUI system monitor (CPU, RAM, disk, network)
    resources                  # Lightweight GUI resource monitor
    zenity                     # GTK dialogs (needed by tinyfiledialogs)
    mesa-demos
    vulkan-tools
    glmark2

    # ── Hardware & Power ──
    brightnessctl              # Screen brightness control
    ddcutil                    # External monitor brightness via DDC/CI
    gproLedSioyek              # GPRO live/udev profile matching Sioyek highlights
    gproSioyekApply            # Legacy GPRO-only palette command
    sioyekKeyboardApply        # Auto-detect GPRO or PRO X TKL and apply its palette
    power-profiles-daemon      # Power profile management (balanced, performance, saver)
    simple-scan                # Simple GNOME scan GUI (flatbed / quick scans)
    naps2                      # Multi-page ADF → searchable-PDF scanning with OCR
    xsane
    sane-airscan

    # ── Disk & Partitioning ──
    gparted                    # GUI partition editor
    usbimager                  # Write disk images to USB drives
    smartmontools              # SMART health + drive error log (smartctl -d sat /dev/sda
                               # for the USB-attached PortableSSD root)

    # ── Hyprland & Wayland Desktop ──
    awww                       # Animated wallpaper daemon for Wayland
    hyprsysteminfo             # Hyprland system info utility
    hyprpolkitagent            # Polkit authentication agent for Hyprland
    waypaper                   # GUI wallpaper setter for Wayland
    slurp                      # Wayland region selector (for screenshots)
    grim                       # Wayland screenshot utility
    wl-clipboard               # Wayland clipboard utilities (wl-copy, wl-paste)
    xclip                      # X11 clipboard utility (for XWayland apps like Remmina)
    copyq                      # Powerful clipboard manager (Wayland + X11 sync)
    libnotify                  # Desktop notification sending (notify-send)
    # ── Themes & Appearance ──
    orchis-theme               # GTK theme (Orchis)
    tela-icon-theme            # Tela icon theme
    tela-circle-icon-theme     # Tela Circle icon theme
    fluent-icon-theme          # Fluent Design icon theme
    adwaita-icon-theme         # GNOME default icon theme
    sassc                      # SASS/SCSS CSS compiler (for theme building)
    astronautPkg               # SDDM login screen theme (random variant per boot)

    # ── File Managers ──
    nemo-with-extensions       # Cinnamon file manager with plugins
    nemo-fileroller
    cinnamon-desktop           # gsettings schemas for Nemo (terminal, etc.)
    file-roller
    spacedrive                 # Cross-platform file manager

    # ── Image & Media Tools ──
    imagemagick                # Image conversion and manipulation (CLI)
    ffmpeg                     # Audio/video converter and streamer
    ffmpegthumbnailer          # Video thumbnails (used by Emacs Dirvish preview)
    mediainfo                  # Media metadata (used by Emacs Dirvish preview)
    vips                       # Fast image thumbnailing — Dirvish image dispatcher
    guvcview                   # GUI webcam viewer/recorder
    v4l-utils                  # V4L2 utilities (includes qv4l2)
    gimp                       # GNU image editor (Photoshop alternative)
    inkscape                   # Vector graphics editor (Illustrator alternative)
    pinta                      # Simple raster image editor (Paint.NET alternative)
    imv                        # Wayland-native image viewer
    tiv                        # Terminal image viewer (ASCII art)
    chafa                      # Terminal image viewer (Unicode/sixel)
    viu                        # Terminal image viewer (Unicode)

    # ── Office & Documents ──
    texliveFull                # Full TeX/LaTeX distribution
    hugo                       # Static site generator
    glow                       # Terminal markdown previewer
    minder                     # Mind map

    # ── CAD & Engineering ──
    librecad                   # 2D CAD application
    freecad                    # 3D parametric CAD modeler
    openscad
    mayo
    (python3.withPackages (ps: with ps; [
      pythonocc-core           # OpenCASCADE Python bindings for scripted CAD cleanup
      trimesh                  # Mesh analysis / cleanup helpers
      meshio                   # Mesh format conversion helpers
    ]))
    # ── Emacs & Editor Ecosystem ──
    ((emacsPackagesFor emacs-pgtk).emacsWithPackages (
      epkgs: with epkgs; [
        vterm                  # Terminal emulator inside Emacs
        direnv                 # Direnv integration for Emacs
        lsp-pyright            # Python LSP client (Pyright)
        zmq                    # ZeroMQ bindings for Jupyter
        pyvenv
        codex-cli
        material-theme
	      gruvbox-theme
	      doom-themes
	      ef-themes
	      pdf-tools
	      async
        neotree
        dirvish                # Yazi-like miller-columns Dired with previews
        all-the-icons
        rainbow-delimiters
        yaml-mode
        dockerfile-mode
        toml-mode
        json-mode
	      prettier-js
	      js2-refactor
	      rjsx-mode
	      tide
	      web-mode
	      emmet-mode
	      rustic
	      ox-rst
	      alert
	      org-fragtog
	      ob-nix
	      latex-preview-pane
	      org-modern
	      slime
	      nix-mode
	      geiser-mit
	      pyvenv
	      nov
	      markdown-mode
	      mixed-pitch
	      smartparens
	      spice-mode
	      ob-spice
	      saveplace-pdf-view
	      rg
	      ob-rust
	      lua-mode
	      direnv
	      magik-mode
	      treemacs
	      transpose-frame
      ]
    ))
    enchant                  # Spell checking meta-library (used by jinx)
    hunspell                   # Spell checker backend (used by enchant)
    hunspellDicts.en_US        # US English dictionary for hunspell

    # ── Language Servers (LSP) ──
    # System-wide LSPs (used across all projects)
    yaml-language-server       # YAML language server
    vscode-json-languageserver # JSON language server
    bash-language-server       # Bash/shell script language server
    nixd                       # Nix language server
    marksman                   # Markdown language server
    vale-ls                    # Vale language server (prose/Markdown)

    # ── Development Tools ──
    pkg-config                 # Compiler/linker flags helper
    libxml2                    # XML parsing library
    glib                       # GLib core library
    jsonrpc-glib               # JSON-RPC library for GLib
    nodejs_24                  # Node.js JavaScript runtime
    nix-index                  # Nix package file index (nix-locate)
    nix-output-monitor         # Pretty nix build output (nom)
    devenv                     # Developer environment manager
    repomix                    # Repository content mixer for LLM context
    xvfb-run                   # Run a GUI/render command on a throwaway X display. `Xvfb` itself
                               # already comes in transitively via xorg-server, but only the
                               # wrapper allocates a free display AND tears it down: a leftover
                               # Xvfb wedges user@1000.service at logout, so the NEXT login waits
                               # out the ~90 s stop-timeout. Headless KrakenOS validator/render
                               # runs are the source, e.g. `xvfb-run -a .devenv/state/venv/bin/python
                               # -m KrakenOS.UI.validate_open3d_...`.

    # ── AI Assistants ──
    # claude-code                # Anthropic Claude CLI coding assistant
    # claude-monitor             # Claude usage monitoring tool
    # codex
    # gemini-cli

    # ── Containers & Compatibility ──
    distrobox                  # Run other Linux distros in containers
    cryfs                      # Encrypts files locally
    # FHS environment for running non-NixOS binaries
    (let base = pkgs.appimageTools.defaultFhsEnvArgs; in
     pkgs.buildFHSEnv (base // {
       name = "fhs";
       targetPkgs = pkgs:
         (base.targetPkgs pkgs) ++ (with pkgs; [
           pkg-config
           ncurses
           gtk2
           gnome-themes-extra
           gtk-engine-murrine
           gtk3
           glib
           cairo
           pango
           gdk-pixbuf
           atk
           at-spi2-atk
           nss
           nspr
           alsa-lib
           cups
           dbus
           libnotify
           libX11
           libXcomposite
           libXcursor
           libXdamage
           libXext
           libXfixes
           libXi
           libXrandr
           libXrender
           libXtst
           libXScrnSaver
           libxcb
           libxkbcommon
           libdrm
           libgbm
           wget
         ]);
       profile = "export FHS=1";
       runScript = "bash";
       extraOutputsToInstall = ["dev"];
     }))

    # ── Git & Version Control ──
    git-credential-manager     # Cross-platform Git credential storage
    gh                         # GitHub CLI

    # ── PDF & Document Viewers ──
    # Sioyek wrapped to use XWayland (native Wayland has issues with NVIDIA)
    (pkgs.symlinkJoin {
      name = "sioyek-wrapped";
      paths = [ pkgs.sioyek ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/sioyek --set QT_QPA_PLATFORM xcb
      '';
    })
    djvuToPdf                  # djvu2pdf: DjVu → searchable PDF for Sioyek
    pdfPrep                    # pdf-prep: whiten, speed up and OCR a scanned PDF
    sioyekSnip                 # sioyek-snip: crop a dragged rectangle out of a page
    djvulibre                  # ddjvu/djvused/djvudump for inspecting DjVu directly
    ocrmypdf                   # Adds a searchable text layer to scanned PDFs
    tesseract                  # OCR engine behind ocrmypdf

    # ── Cloud ──
    filen-desktop

    # ── Utilities ──
    wget
    
    # ── Fun ──
    cowsay                     # Talking cow ASCII art
  ] ++ (lib.optionals (pkgs ? gmsh) [ pkgs.gmsh ])
    ++ (lib.optionals (pkgs ? f3d) [ pkgs.f3d ])
    ++ (lib.optionals (pkgs ? paraview) [ pkgs.paraview ]);

  services.blueman.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        FastConnectable = true;
      };
      Policy = {
        AutoEnable = true;
      };
    };
  };

  # Container runtime for distrobox
  virtualisation.podman.enable = true;

  # Provide /usr/bin/wget for apps that hardcode it
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/wget - - - - /run/current-system/sw/bin/wget"
  ];

  # EasyConnect EasyMonitor service (user install path)
  systemd.services.EasyMonitor = {
    description = "Sangfor EasyMonitor Service (EasyConnect)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/usr/share/sangfor/EasyConnect/resources/bin/EasyMonitor";
    };
    serviceConfig = {
      Type = "forking";
      ExecStart = "/usr/share/sangfor/EasyConnect/resources/bin/EasyMonitor";
      ExecReload = "/bin/kill -USR1 $MAINPID";
      ExecStop = "/bin/kill -QUIT $MAINPID";
      Restart = "on-failure";
    };
  };

  # Set the default editor to vim
  environment.variables.EDITOR = "xed";
  environment.variables.GTK_IM_MODULE = lib.mkForce "";
  environment.variables.QT_IM_MODULE = lib.mkForce "";

  # Optional: Enable nix-ld for automatic handling of dynamic libraries
  # This is often recommended for seamless integration with non-Nix software.
  programs.nix-ld.enable = true;

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    # pinentryPackage = pkgs.pinentry-qt;
  };

  i18n.inputMethod = {
    type = "fcitx5";
    enable = true;
    fcitx5.addons = with pkgs; [
      fcitx5-gtk   # Or fcitx5-qt for KDE Plasma
      fcitx5-rime
      rime-data
      librime
      qt6Packages.fcitx5-chinese-addons
      fcitx5-nord  # a color theme
    ];
  };

  fonts.packages = with pkgs; [
    corefonts
    nerd-fonts.ubuntu
    nerd-fonts.ubuntu-sans
    nerd-fonts.ubuntu-mono
    nerd-fonts.caskaydia-cove
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    wqy_microhei
    wqy_zenhei
  ];

  system.stateVersion = "25.11";

}
