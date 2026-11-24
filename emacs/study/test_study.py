"""Tests for the Emacs Study AI backend.  Run:

    emacs-study-python -m unittest -v ~/Projects/emacs/study/test_study.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import study_assets  # noqa: E402

PDF = os.path.expanduser("~/.local/share/sioyek/tutorial.pdf")
KATEX = next(iter(sorted(Path("/nix/store").glob("*-katex-*/lib/node_modules/katex/dist"))), None)


@unittest.skipUnless(os.path.exists(PDF), "tutorial.pdf missing")
class CropTests(unittest.TestCase):
    def test_vector_svg_and_png(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = study_assets.crop_pdf_region(PDF, 0, (72, 72, 350, 260), tmp)
            self.assertTrue(result["is_vector"])
            svg = Path(result["svg_path"]).read_text()
            self.assertIn("<svg", svg)
            self.assertIn("viewBox", svg)
            self.assertIn("<path", svg)
            self.assertNotIn("<image", svg.split("<defs>")[0])
            self.assertEqual(Path(result["png_path"]).read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
            self.assertAlmostEqual(result["width"], 278, delta=1)

    def test_empty_selection_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                study_assets.crop_pdf_region(PDF, 0, (5000, 5000, 5100, 5100), tmp)

    def test_resolve_page(self):
        self.assertEqual(study_assets.resolve_sioyek_page(PDF, 1.0), 1)
        self.assertGreaterEqual(study_assets.resolve_sioyek_page(PDF, 1e9), 1)
        self.assertEqual(study_assets.resolve_sioyek_page("/nonexistent.pdf", 5), 1)


class SvgTests(unittest.TestCase):
    def test_sanitize(self):
        dirty = ('junk<svg viewBox="0 0 10 10" onload="x()"><script>alert(1)</script>'
                 '<foreignObject><p>x</p></foreignObject>'
                 '<a xlink:href="javascript:alert(1)"><circle r="3"/></a>'
                 '<image href="https://evil.example/a.png"/>'
                 '<image href="data:image/png;base64,AAAA"/>'
                 '<use href="#ok"/><marker id="m"/></svg>tail')
        clean = study_assets.sanitize_svg(dirty)
        for bad in ("script", "foreignObject", "onload", "javascript", "evil.example"):
            self.assertNotIn(bad, clean)
        for good in ('viewBox="0 0 10 10"', "<circle", "data:image/png", 'href="#ok"', "<marker"):
            self.assertIn(good, clean)
        self.assertTrue(clean.startswith("<svg") and clean.endswith("</svg>"))
        self.assertEqual(study_assets.sanitize_svg("no svg here"), "")


class MarkdownTests(unittest.TestCase):
    def test_html(self):
        md = ("Inline $a_1 + b_2$ and \\(x^2\\).\n\n$$\\int_0^1 x\\,dx$$\n\n"
              "| a | b |\n|---|---|\n| 1 | 2 |\n\n```python\nx = 1 * 2\n```\n\n"
              "Price is $5 and $6.\n\n<svg viewBox=\"0 0 5 5\"><script>1</script><rect width=\"5\" height=\"5\"/></svg>\n")
        out = study_assets.render_markdown_to_html(md)
        self.assertIn('<span class="math-inline">\\(a_1 + b_2\\)</span>', out)
        self.assertIn('<span class="math-inline">\\(x^2\\)</span>', out)
        self.assertIn('<div class="math-display">\\[\\int_0^1 x\\,dx\\]</div>', out)
        self.assertIn("<table>", out)
        self.assertIn("code-block", out)
        self.assertIn("copy-btn", out)
        self.assertIn("Price is $5 and $6.", out)
        self.assertIn('<div class="vector-figure"><svg', out)
        self.assertNotIn("<script", out)
        self.assertNotIn("ZZSTUDY", out)
        self.assertNotIn("<p><div", out)

    def test_html_escaped(self):
        out = study_assets.render_markdown_to_html("<b>x</b> $a<b$")
        self.assertNotIn("<b>", out)


@unittest.skipUnless(shutil.which("pandoc"), "pandoc missing")
class OrgTests(unittest.TestCase):
    def test_markdown_to_org(self):
        with tempfile.TemporaryDirectory() as tmp:
            org_dir = os.path.join(tmp, "notes")
            assets = os.path.join(org_dir, "study-assets")
            snap = os.path.join(tmp, "snap.svg")
            Path(snap).write_text('<svg viewBox="0 0 4 4"><rect width="4" height="4"/></svg>')
            md = ("## Result\n\nInline $E=mc^2$ and\n\n$$\\int_0^1 x\\,dx$$\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n"
                  "<svg viewBox=\"0 0 9 9\"><circle r=\"3\"/><script>1</script></svg>\n")
            result = study_assets.markdown_to_org(
                md, title="What is E?", level=2, assets_dir=assets, org_dir=org_dir,
                source_pdf="/books/Photonics.pdf", page=42, snapshot_svg=snap,
                agent="Claude Code", question="What is E?", selected_text="E equals")
            text = result["org_text"]
            self.assertTrue(text.startswith("** What is E?\n:PROPERTIES:\n"))
            self.assertIn(":AGENT: Claude Code", text)
            self.assertIn("[[sioyek:/books/Photonics.pdf::42][Photonics.pdf · p.42]]", text)
            self.assertIn("#+BEGIN_QUOTE\nE equals\n#+END_QUOTE", text)
            self.assertIn("\\(E=mc^2\\)", text)
            self.assertIn("\\[\\int_0^1 x\\,dx\\]", text)
            self.assertRegex(text, r"\|\s*a\s*\|\s*b\s*\|")
            self.assertIn("**** Result", text)
            self.assertNotIn("STUDYFIGTOKEN", text)
            files = sorted(os.path.basename(p) for p in result["assets"])
            self.assertEqual(len(files), 2)
            self.assertTrue(any(f.endswith("-snip.svg") for f in files))
            fig = next(p for p in result["assets"] if "-fig-" in p)
            self.assertNotIn("script", Path(fig).read_text())
            self.assertIn("[[file:study-assets/", text)


def request(base, path, token, body=None, method=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        base + path, data=data, method=method or ("GET" if body is None else "POST"),
        headers={"X-Study-Token": token, "Content-Type": "application/json"} if token else {})
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read()
        return resp.status, raw


@unittest.skipUnless(shutil.which("pandoc"), "pandoc missing")
class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.snips = os.path.join(self.tmp, "snips")
        self.org = os.path.join(self.tmp, "notes.org")
        self.runtime = os.path.join(self.tmp, "runtime.json")
        cmd = [sys.executable, str(HERE / "emacs-study-server.py"), "--standalone", "--mock-agent",
               "--snip-dir", self.snips, "--target-org", self.org, "--runtime-file", self.runtime]
        if KATEX:
            cmd += ["--katex-dir", str(KATEX)]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        info = json.loads(self.proc.stdout.readline())
        self.base = "http://127.0.0.1:%d" % info["port"]
        self.token = info["token"]

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def get_json(self, path, body=None):
        return json.loads(request(self.base, path, self.token, body)[1])

    def wait_idle(self):
        for _ in range(100):
            state = self.get_json("/api/state")
            if not state["busy"]:
                return state
            time.sleep(0.05)
        self.fail("agent never finished")

    def test_auth_and_runtime_file(self):
        self.assertEqual(oct(os.stat(self.runtime).st_mode & 0o777), "0o600")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            request(self.base, "/api/state", "wrong-token")
        self.assertEqual(caught.exception.code, 401)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            request(self.base, "/", None)
        self.assertEqual(caught.exception.code, 401)
        status, page = request(self.base, "/", self.token)
        self.assertEqual(status, 200)
        self.assertIn(b"Emacs Study AI", page)
        if KATEX:
            self.assertEqual(request(self.base, "/assets/katex/katex.min.css", None)[0], 200)
            with self.assertRaises(urllib.error.HTTPError):
                request(self.base, "/assets/katex/../../etc/passwd", None)

    @unittest.skipUnless(os.path.exists(PDF), "tutorial.pdf missing")
    def test_context_merge_chat_and_save(self):
        snap = study_assets.crop_pdf_region(PDF, 0, (72, 72, 350, 260), self.snips)
        ctx = self.get_json("/api/context", {"file": PDF, "page": 1, "text": "Snell's law"})["context"]
        self.assertEqual(ctx["text"], "Snell's law")
        self.assertIsNone(ctx["svg"])
        ctx = self.get_json("/api/context", {"file": PDF, "page": 1, "svg_path": snap["svg_path"],
                                             "png_path": snap["png_path"]})["context"]
        self.assertEqual(ctx["text"], "Snell's law")  # merged, not replaced
        self.assertTrue(ctx["svg"].endswith(".svg"))
        status, svg = request(self.base, "/api/snip/" + ctx["svg"], self.token)
        self.assertEqual(status, 200)
        self.assertIn(b"<svg", svg)
        # snapshots outside the snip dir are ignored
        bad = self.get_json("/api/context", {"file": PDF, "page": 2, "svg_path": "/etc/passwd",
                                             "text": "other page", "replace": True})["context"]
        self.assertIsNone(bad["svg"])
        self.assertEqual(bad["page"], 2)
        self.get_json("/api/context", {"file": PDF, "page": 1, "text": "Snell's law",
                                       "svg_path": snap["svg_path"], "png_path": snap["png_path"],
                                       "replace": True})

        self.assertTrue(self.get_json("/api/chat", {"question": "Derive it"})["ok"])
        state = self.wait_idle()
        answer = state["turns"][-1]
        self.assertEqual(answer["role"], "assistant")
        self.assertIn('class="math-display"', answer["html"])
        self.assertIn("<table>", answer["html"])
        self.assertNotIn("<script", answer["html"])
        self.assertIn("vector-figure", answer["html"])

        saved = self.get_json("/api/save-org", {"turn_id": answer["id"]})
        self.assertTrue(saved["ok"])
        self.assertIn("* Derive it", saved["org_text"])
        self.assertIn(":SOURCE: [[sioyek:%s::1]" % PDF, saved["org_text"])
        self.assertIn("#+BEGIN_QUOTE\nSnell's law", saved["org_text"])
        self.assertIn("\\(n_1 \\sin\\theta_1 = n_2 \\sin\\theta_2\\)", saved["org_text"])
        self.assertTrue(all(os.path.exists(p) for p in saved["assets"]))
        thread = self.get_json("/api/save-org", {"thread": True})
        self.assertTrue(thread["ok"])
        self.assertIn("*Question:* Derive it", thread["org_text"])

        self.get_json("/api/reset", {})
        self.assertEqual(self.get_json("/api/state")["turns"], [])

    def test_stop_removes_runtime_file(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        self.assertFalse(os.path.exists(self.runtime))

    @unittest.skipUnless(os.path.exists(PDF), "tutorial.pdf missing")
    def test_sioyek_bridge_cli(self):
        bridge = str(HERE / "sioyek-to-emacs.py")
        env = dict(os.environ, EMACS_STUDY_RUNTIME=self.runtime)
        r1 = subprocess.run(
            [sys.executable, bridge, "--mode", "text", "--file=" + PDF,
             "--page", "0", "--text=-1/2 mv^2"],
            env=env, capture_output=True, text=True, check=False)
        self.assertEqual(r1.returncode, 0, r1.stderr)
        ctx1 = self.get_json("/api/state")["context"]
        self.assertEqual(ctx1["text"], "-1/2 mv^2")
        self.assertEqual(ctx1["page"], 1)

        r2 = subprocess.run(
            [sys.executable, bridge, "--mode", "rect", "--file=" + PDF,
             "--rect=0,72,72,350,260", "--snip-dir", self.snips],
            env=env, capture_output=True, text=True, check=False)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        ctx2 = self.get_json("/api/state")["context"]
        self.assertEqual(ctx2["text"], "-1/2 mv^2")  # merged on same PDF & page
        self.assertTrue(ctx2["svg"].endswith(".svg"))


if __name__ == "__main__":
    unittest.main()
