"""Vector-first PDF snapshots, Markdown rendering and Markdown -> Org export.

Used by the Emacs Study AI workbench (``emacs-study-server.py``), the Sioyek
bridge (``sioyek-to-emacs.py``) and the unit tests.  Everything here is pure
Python on top of PyMuPDF, markdown-it-py, Pygments and Pandoc.
"""

from __future__ import annotations

import html
import os
import re
import shutil
import subprocess
import sys
import time

# --------------------------------------------------------------------------
# PDF snapshots
# --------------------------------------------------------------------------

DJVU_EXTENSIONS = {".djv", ".djvu"}


def _stamp() -> str:
    now = time.time()
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + "%03d" % int((now % 1) * 1000)


def _stem(path: str) -> str:
    stem = os.path.splitext(os.path.basename(path))[0]
    return re.sub(r"[^\w.-]+", "_", stem)[:60] or "doc"


def _crop_djvu(doc_path, page_index, rect, base, dpi):
    from PIL import Image
    import io

    rendered = subprocess.run(
        ["ddjvu", "-page=%d" % (page_index + 1), "-scale=%d" % dpi, "-format=ppm", doc_path, "-"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    x0, y0, x1, y1 = rect
    with Image.open(io.BytesIO(rendered.stdout)) as image:
        image.load()
        ppp = dpi / 72.0
        left = max(0, min(image.width, int(min(x0, x1) * ppp)))
        top = max(0, min(image.height, int(min(y0, y1) * ppp)))
        right = max(0, min(image.width, int(max(x0, x1) * ppp + 0.999)))
        bottom = max(0, min(image.height, int(max(y0, y1) * ppp + 0.999)))
        if right <= left or bottom <= top:
            raise ValueError("The selection is empty")
        crop = image.crop((left, top, right, bottom))
        png = base + ".png"
        crop.save(png)
        return {"svg_path": None, "png_path": png, "width": (right - left) / ppp,
                "height": (bottom - top) / ppp, "page": page_index + 1, "is_vector": False}


def crop_pdf_region(doc_path, page_index, rect_pts, out_dir, dpi=300):
    """Crop RECT_PTS (x0, y0, x1, y1 in page points) of a page.

    Returns a dict with a pure-vector ``svg_path`` (PDF-family documents) and a
    ``png_path`` rendered at DPI, used only for vision models.
    """
    page_index = int(page_index)
    x0, y0, x1, y1 = (float(v) for v in rect_pts)
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, "%s-p%d-%s" % (_stem(doc_path), page_index + 1, _stamp()))
    if os.path.splitext(doc_path)[1].lower() in DJVU_EXTENSIONS:
        return _crop_djvu(doc_path, page_index, (x0, y0, x1, y1), base, dpi)

    import pymupdf

    doc = pymupdf.open(doc_path)
    try:
        page = doc[page_index]
        clip = pymupdf.Rect(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)) & page.rect
        if clip.is_empty:
            raise ValueError("The selection is empty")
        png_path = base + ".png"
        page.get_pixmap(clip=clip, dpi=dpi).save(png_path)
        svg_path = None
        try:
            sub = pymupdf.open()
            try:
                sub.insert_pdf(doc, from_page=page_index, to_page=page_index)
                sub_page = sub[0]
                sub_page.set_cropbox(clip & sub_page.rect)
                svg_text = sub_page.get_svg_image(text_as_path=True)
            finally:
                sub.close()
            svg_path = base + ".svg"
            with open(svg_path, "w", encoding="utf-8") as handle:
                handle.write(svg_text)
        except Exception:  # vector export is best effort; the PNG still exists
            svg_path = None
        return {"svg_path": svg_path, "png_path": png_path, "width": clip.width,
                "height": clip.height, "page": page_index + 1, "is_vector": svg_path is not None}
    finally:
        doc.close()


def resolve_sioyek_page(pdf_path, abs_y) -> int:
    """Map Sioyek's cumulative absolute Y to a 1-based page number (1 on failure)."""
    try:
        import pymupdf

        doc = pymupdf.open(pdf_path)
        try:
            total = 0.0
            for index in range(doc.page_count):
                total += doc[index].rect.height
                if float(abs_y) < total:
                    return index + 1
            return max(1, doc.page_count)
        finally:
            doc.close()
    except Exception:
        return 1


# --------------------------------------------------------------------------
# SVG sanitising
# --------------------------------------------------------------------------

_SVG_DROP_ELEMENTS = ("script", "foreignObject", "iframe", "object", "embed")
_SVG_ELEMENT_RES = [
    re.compile(r"<\s*%s\b[^>]*?/\s*>" % name, re.I) for name in _SVG_DROP_ELEMENTS
] + [
    re.compile(r"<\s*%s\b.*?<\s*/\s*%s\s*>" % (name, name), re.I | re.S) for name in _SVG_DROP_ELEMENTS
]
_SVG_EVENT_RE = re.compile(r"""\s+on[a-zA-Z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)""", re.I)
_SVG_HREF_RE = re.compile(
    r"""\s+(?:xlink:)?href\s*=\s*(?P<q>["'])\s*(?P<url>.*?)(?P=q)""", re.I | re.S)
_SAFE_DATA_RE = re.compile(r"^data:image/(?:png|jpe?g|gif|webp);base64,", re.I)
_SVG_IMPORT_RE = re.compile(r"@import[^;]*;|url\(\s*['\"]?\s*(?:https?:|//|javascript:)[^)]*\)", re.I)


def sanitize_svg(svg_text: str) -> str:
    """Strip scripts, event handlers and remote references; keep vector content."""
    if not svg_text or "<svg" not in svg_text.lower():
        return ""
    start = svg_text.lower().index("<svg")
    text = svg_text[start:]
    end = text.lower().rfind("</svg>")
    if end != -1:
        text = text[: end + len("</svg>")]
    for pattern in _SVG_ELEMENT_RES:
        text = pattern.sub("", text)
    text = _SVG_EVENT_RE.sub("", text)

    def href(match):
        url = match.group("url").strip()
        if url.startswith("#") or _SAFE_DATA_RE.match(url):
            return match.group(0)
        return ""

    text = _SVG_HREF_RE.sub(href, text)
    text = _SVG_IMPORT_RE.sub("", text)
    return text


# --------------------------------------------------------------------------
# Markdown -> HTML (KaTeX-ready math, sanitised vector figures)
# --------------------------------------------------------------------------

_FENCE_RE = re.compile(
    r"^(?P<fence>`{3,}|~{3,})[ \t]*(?P<lang>[\w+#.-]*)[^\n]*\n(?P<body>.*?)^(?P=fence)[ \t]*$",
    re.M | re.S)
_SVG_BLOCK_RE = re.compile(r"<svg\b.*?</svg>", re.I | re.S)
_CODE_SPAN_RE = re.compile(r"(?<!`)(`+)(?!`)(?P<code>.+?)(?<!`)\1(?!`)", re.S)
_MATH_RE = re.compile(
    r"(?<!\\)\$\$(?P<dd>.+?)(?<!\\)\$\$"
    r"|(?<!\\)\\\[(?P<br>.+?)(?<!\\)\\\]"
    r"|(?<!\\)\\\((?P<par>.+?)(?<!\\)\\\)"
    r"|(?<![\\$])\$(?![\s$])(?P<d1>[^\n$]+?)(?<![\\\s$])\$(?![\d$])",
    re.S)


def _token(kind: str, index: int) -> str:
    return "ZZSTUDY%s%dZZ" % (kind, index)


def _highlight_code(code: str, lang: str) -> str:
    escaped = html.escape(code)
    try:
        from pygments import highlight
        from pygments.formatters import HtmlFormatter
        from pygments.lexers import get_lexer_by_name

        lexer = get_lexer_by_name(lang) if lang else None
        if lexer is not None:
            body = highlight(code, lexer, HtmlFormatter(nowrap=True))
            return "<pre><code class=\"codehilite language-%s\">%s</code></pre>" % (
                html.escape(lang), body)
    except Exception:
        pass
    return "<pre><code>%s</code></pre>" % escaped


def _markdown_to_html_body(text: str) -> str:
    try:
        from markdown_it import MarkdownIt

        parser = MarkdownIt("commonmark", {"html": False, "breaks": False}).enable(
            ["table", "strikethrough"])
        return parser.render(text)
    except Exception:
        paragraphs = [p for p in re.split(r"\n{2,}", text) if p.strip()]
        return "".join("<p>%s</p>\n" % html.escape(p).replace("\n", "<br>\n") for p in paragraphs)


def render_markdown_to_html(md_text: str) -> str:
    """Render Markdown to safe HTML.

    Math is emitted as ``<div class="math-display">\\[..\\]</div>`` /
    ``<span class="math-inline">\\(..\\)</span>`` for client side KaTeX, fenced
    ``svg`` blocks and inline ``<svg>`` are sanitised into zoomable vector figures.
    """
    store: dict[str, tuple[str, str]] = {}
    counter = [0]

    def protect(kind: str, payload: str) -> str:
        counter[0] += 1
        key = _token(kind, counter[0])
        store[key] = (kind, payload)
        return key

    def fence(match):
        lang = match.group("lang").lower()
        body = match.group("body")
        if lang == "svg":
            clean = sanitize_svg(body)
            if clean:
                return "\n\n%s\n\n" % protect("B", '<div class="vector-figure">%s</div>' % clean)
        block = '<div class="code-block"><button class="copy-btn" type="button">Copy</button>%s</div>' % (
            _highlight_code(body.rstrip("\n"), lang))
        return "\n\n%s\n\n" % protect("B", block)

    text = _FENCE_RE.sub(fence, md_text or "")

    def svg_block(match):
        clean = sanitize_svg(match.group(0))
        if not clean:
            return ""
        return "\n\n%s\n\n" % protect("B", '<div class="vector-figure">%s</div>' % clean)

    text = _SVG_BLOCK_RE.sub(svg_block, text)
    text = _CODE_SPAN_RE.sub(
        lambda m: protect("C", "<code>%s</code>" % html.escape(m.group("code").strip())), text)

    def math(match):
        for group, display, open_, close in (
                ("dd", True, "\\[", "\\]"), ("br", True, "\\[", "\\]"),
                ("par", False, "\\(", "\\)"), ("d1", False, "\\(", "\\)")):
            tex = match.group(group)
            if tex is not None:
                body = html.escape(tex.strip(), quote=False)
                if display:
                    markup = '<div class="math-display">%s%s%s</div>' % (open_, body, close)
                    return "\n\n%s\n\n" % protect("B", markup)
                return protect("I", '<span class="math-inline">%s%s%s</span>' % (open_, body, close))
        return match.group(0)

    text = _MATH_RE.sub(math, text)
    rendered = _markdown_to_html_body(text)
    for key, (kind, payload) in store.items():
        if kind == "B":
            rendered = rendered.replace("<p>%s</p>" % key, payload).replace(key, payload)
    for key, (kind, payload) in store.items():
        if kind != "B":
            rendered = rendered.replace(key, payload)
    return rendered


# --------------------------------------------------------------------------
# Markdown -> Org
# --------------------------------------------------------------------------

def _slug(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")[:40]
    return "%s-%s" % (slug or "note", time.strftime("%Y%m%d-%H%M%S"))


def _extract_figures(md_text: str):
    """Pull ```svg fences and inline <svg> blocks out, returning (md, [svg])."""
    figures: list[str] = []

    def keep(svg_text: str) -> str:
        clean = sanitize_svg(svg_text)
        if not clean:
            return ""
        figures.append(clean)
        return "\n\nSTUDYFIGTOKEN%dX\n\n" % (len(figures) - 1)

    text = re.sub(
        r"^```svg[^\n]*\n(?P<b>.*?)^```[ \t]*$",
        lambda m: keep(m.group("b")), md_text, flags=re.M | re.S)
    text = _SVG_BLOCK_RE.sub(lambda m: keep(m.group(0)), text)
    return text, figures


def _pandoc_to_org(md_text: str) -> str:
    pandoc = shutil.which("pandoc")
    if not pandoc:
        return md_text
    result = subprocess.run(
        [pandoc, "-f",
         "markdown+tex_math_dollars+tex_math_single_backslash+pipe_tables"
         "+fenced_code_blocks+strikeout-smart-auto_identifiers",
         "-t", "org", "--wrap=none"],
        input=md_text, capture_output=True, text=True, encoding="utf-8", check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "pandoc failed")
    return result.stdout


def _org_link_path(path: str, org_dir) -> str:
    absolute = os.path.abspath(path)
    if org_dir:
        base = os.path.abspath(org_dir)
        if absolute == base or absolute.startswith(base + os.sep):
            return os.path.relpath(absolute, base)
    return absolute


def markdown_to_org(md_text, *, title=None, level=2, assets_dir=None, org_dir=None,
                    slug=None, source_pdf=None, page=None, snapshot_svg=None,
                    snapshot_png=None, agent=None, question=None, selected_text=None):
    """Convert Markdown to an Org subtree.  Returns ``{"org_text", "assets"}``."""
    title = (title or question or "Study note").strip().splitlines()[0][:100] or "Study note"
    slug = slug or _slug(title)
    assets: list[str] = []
    stripped, figures = _extract_figures(md_text or "")
    if (figures or snapshot_svg or snapshot_png) and assets_dir:
        os.makedirs(assets_dir, exist_ok=True)

    snapshot_link = None
    for candidate in (snapshot_svg, snapshot_png):
        if candidate and os.path.isfile(candidate) and assets_dir:
            target = os.path.join(assets_dir, "%s-snip%s" % (slug, os.path.splitext(candidate)[1]))
            shutil.copyfile(candidate, target)
            assets.append(target)
            snapshot_link = target
            break

    body = _pandoc_to_org(stripped).strip("\n")
    if level:
        body = re.sub(r"^(\*+) ", lambda m: "*" * (len(m.group(1)) + level) + " ", body, flags=re.M)

    def figure(match):
        index = int(match.group(1))
        if not assets_dir or index >= len(figures):
            return ""
        target = os.path.join(assets_dir, "%s-fig-%d.svg" % (slug, index + 1))
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(figures[index])
        assets.append(target)
        return "#+ATTR_ORG: :width 600\n[[file:%s]]" % _org_link_path(target, org_dir)

    body = re.sub(r"^STUDYFIGTOKEN(\d+)X$", figure, body, flags=re.M)

    lines = ["%s %s" % ("*" * max(1, level), title), ":PROPERTIES:"]
    if agent:
        lines.append(":AGENT: %s" % agent)
    if source_pdf:
        label = os.path.basename(source_pdf) + (" · p.%s" % page if page else "")
        lines.append(":SOURCE: [[sioyek:%s%s][%s]]" % (
            source_pdf, "::%s" % page if page else "", label))
    lines += [":CREATED: %s" % time.strftime("[%Y-%m-%d %a %H:%M]"), ":END:", ""]
    if selected_text:
        lines += ["#+BEGIN_QUOTE", selected_text.strip(), "#+END_QUOTE", ""]
    if snapshot_link:
        lines += ["#+ATTR_ORG: :width 600", "[[file:%s]]" % _org_link_path(snapshot_link, org_dir), ""]
    if question and question.strip() != title:
        lines += ["*Question:* %s" % question.strip().replace("\n", " "), ""]
    lines.append(body)
    return {"org_text": "\n".join(lines).rstrip("\n") + "\n", "assets": assets}


def build_thread_markdown(turns) -> str:
    """Join user/assistant turns (dicts with role/md) into one Markdown string."""
    parts = []
    for turn in turns:
        if turn.get("role") == "user":
            parts.append("**Question:** %s" % turn.get("md", "").strip())
        elif turn.get("role") == "assistant" and turn.get("md"):
            parts.append(turn["md"].strip())
    return "\n\n".join(parts)


def _main(argv):
    if len(argv) >= 3 and argv[1] == "resolve-page":
        print(resolve_sioyek_page(argv[2], float(argv[3])))
        return 0
    if len(argv) >= 3 and argv[1] == "resolve-pages":
        for value in argv[3:]:
            print(resolve_sioyek_page(argv[2], float(value)))
        return 0
    print("usage: study_assets.py resolve-page <pdf> <y> | resolve-pages <pdf> <y>...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
