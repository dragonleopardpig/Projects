"""Every glyph name the bar plugins, their helpers and the settings use exists in Noctalia.

Noctalia draws a skull for a name it does not know (GlyphRegistry's kMissingGlyph), so
a typo or a name from another icon set shows up only on screen.  A name resolves the
way Noctalia resolves it: a hand-curated alias (lib/render/text/glyph_registry.cpp),
then a Tabler icon (assets/fonts/tabler.json).

Where a glyph name can stand:
- Luau and Nix: the value assigned to anything named *glyph* (`glyph = "x"`,
  `diskGlyph = "x"`, `M.BAR_GLYPHS = { ... }`, `glyph = busy and "a" or "b"`),
  `ui.glyph({ name = ... })`, `setGlyph(...)`, kitty-control's `card("Title", "icon", ...)`,
  and the `return "x"` fallbacks of functions named *Glyph*;
- Python helpers: the value of a `"glyph":` key.
"""

import argparse
import json
import re
import sys
from pathlib import Path

QUOTED = re.compile(r'"([^"\n]*)"')
ALIAS = re.compile(r'\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}')
GLYPH_ASSIGN = re.compile(r'\b[\w.]*glyph\w*\s*=(?!=)\s*', re.IGNORECASE)
UI_GLYPH_NAME = re.compile(r'ui\.glyph\(\s*\{[^}]*?\bname\s*=\s*')
SET_GLYPH = re.compile(r'\bsetGlyph\(')
CARD_ICON = re.compile(r'\bcard\(\s*"[^"\n]*"\s*,\s*"([^"\n]+)"')
GLYPH_FUNCTION = re.compile(r'^function\s+[\w.:]*Glyph\w*\(.*?^end\b', re.MULTILINE | re.DOTALL)
RETURN_NAME = re.compile(r'\breturn\s+"([^"\n]+)"')
PY_GLYPH_KEY = re.compile(r'"glyph"\s*:\s*')
OPENERS = {"(": ")", "[": "]", "{": "}"}


def strip_comments(text, marker):
    """Drop comments (from `marker` to the end of the line) outside double-quoted strings."""
    out = []
    for line in text.splitlines():
        in_string = False
        cut = len(line)
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "\\" and in_string:
                i += 2
                continue
            if ch == '"':
                in_string = not in_string
            elif not in_string and line.startswith(marker, i):
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def expression_at(text, start, stop_on_newline=True):
    """The expression starting at `start`: up to a top-level `,` `;` or closing bracket.

    A table (`{ ... }`) or call is taken whole, across lines."""
    depth = []
    in_string = False
    i = start
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch in OPENERS:
            depth.append(OPENERS[ch])
        elif depth and ch == depth[-1]:
            depth.pop()
            if not depth and text[start] in OPENERS:
                return text[start:i + 1]
        elif not depth and (ch in ",;)}]" or (stop_on_newline and ch == "\n")):
            return text[start:i]
        i += 1
    return text[start:]


def call_arguments(text, open_paren):
    """The text between `(` at `open_paren` and its matching `)`."""
    return expression_at(text, open_paren)[1:-1]


def names_in_luau_or_nix(text):
    found = []
    for match in GLYPH_ASSIGN.finditer(text):
        found += QUOTED.findall(expression_at(text, match.end()))
    for match in UI_GLYPH_NAME.finditer(text):
        found += QUOTED.findall(expression_at(text, match.end()))
    for match in SET_GLYPH.finditer(text):
        found += QUOTED.findall(call_arguments(text, match.end() - 1))
    found += CARD_ICON.findall(text)
    for match in GLYPH_FUNCTION.finditer(text):
        found += RETURN_NAME.findall(match.group(0))
    return found


def names_in_python(text):
    found = []
    for match in PY_GLYPH_KEY.finditer(text):
        found += QUOTED.findall(expression_at(text, match.end()))
    return found


def glyph_names(path):
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".luau":
        return names_in_luau_or_nix(strip_comments(text, "--"))
    if path.suffix == ".nix":
        return names_in_luau_or_nix(strip_comments(text, "#"))
    if path.suffix == ".py":
        return names_in_python(strip_comments(text, "#"))
    return []


def known_names(tabler_json, registry_cpp):
    tabler = set(json.loads(Path(tabler_json).read_text(encoding="utf-8")))
    source = Path(registry_cpp).read_text(encoding="utf-8")
    block = source.split("kAliases = {", 1)
    if len(block) != 2:
        sys.exit(f"{registry_cpp}: no kAliases table (did Noctalia move it?)")
    aliases = {alias for alias, target in ALIAS.findall(block[1].split("};", 1)[0]) if target in tabler}
    if len(tabler) < 1000 or len(aliases) < 10:
        sys.exit(f"suspiciously few names: {len(tabler)} Tabler icons, {len(aliases)} aliases")
    return tabler | aliases


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--tabler", required=True, help="Noctalia's assets/fonts/tabler.json")
    parser.add_argument("--registry", required=True, help="Noctalia's lib/render/text/glyph_registry.cpp")
    parser.add_argument("--plugins", required=True, help="the plugins directory (one folder per plugin)")
    parser.add_argument("files", nargs="*", help="more files to check (helpers, settings.nix)")
    args = parser.parse_args(argv)

    known = known_names(args.tabler, args.registry)
    missing = []
    total = 0
    for plugin in sorted(p for p in Path(args.plugins).iterdir() if p.is_dir()):
        names_here = 0
        for path in sorted(plugin.rglob("*.luau")):
            for name in glyph_names(path):
                names_here += 1
                if name not in known:
                    missing.append(f"{path}: unknown glyph {name!r}")
        if names_here == 0:
            missing.append(f"{plugin}: found no glyph names at all (has the way it names them changed?)")
        total += names_here
    for file in args.files:
        for name in glyph_names(Path(file)):
            total += 1
            if name not in known:
                missing.append(f"{file}: unknown glyph {name!r}")
    if missing:
        print("\n".join(missing), file=sys.stderr)
        print("Pick a name from Noctalia's assets/fonts/tabler.json (it draws a skull otherwise).",
              file=sys.stderr)
        return 1
    print(f"{total} glyph names checked, all known to Noctalia")
    return 0


if __name__ == "__main__":
    sys.exit(main())
