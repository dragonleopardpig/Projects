"""rsync excludes for what the boot sweep (modules/impermanence-clean-dev.py) would remove.

Reads the sweep's --dry-run output ("remove dir|file|symlink <path>") on stdin and writes
NUL-separated rsync patterns for `rsync --from0 --exclude-from=FILE`, anchored at ROOT
(the source directory given to rsync).  More patterns relative to ROOT come as arguments
(a trailing / means a directory).  Lines that are not removals, and paths that are gone or
outside ROOT, are skipped (reported on stderr).

rsync reads a backslash as an escape only in a pattern that has a wildcard, so a path with
*, ? or [ gets those and its backslashes escaped; any other path is written as it is.
"""

import argparse
import os
import re
import sys
from pathlib import Path

REMOVAL = re.compile(r"^remove (dir|file|symlink) (/.*)$")
WILDCARDS = set("*?[")


def pattern(rel, is_dir):
    if WILDCARDS & set(rel):
        rel = re.sub(r"([\\*?\[])", r"\\\1", rel)
    return "/" + rel + ("/" if is_dir else "")


def excludes(lines, root, extra=()):
    root = Path(os.path.abspath(root))
    found, skipped = [], []
    for line in lines:
        match = REMOVAL.match(line.rstrip("\n"))
        if not match:
            continue
        kind, path = match.groups()
        path = Path(path)
        try:
            rel = path.relative_to(root)
        except ValueError:
            skipped.append(f"outside {root}: {path}")
            continue
        if not os.path.lexists(path):
            skipped.append(f"gone: {path}")
            continue
        found.append(pattern(str(rel), kind == "dir"))
    for item in extra:
        found.append(pattern(item.strip("/"), item.endswith("/")))
    return found, skipped


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("root", help="the directory rsync copies from (patterns are anchored there)")
    parser.add_argument("extra", nargs="*", help="more paths relative to ROOT to leave out")
    parser.add_argument("--output", required=True, help="where to write the NUL-separated patterns")
    args = parser.parse_args(argv)
    # File names need not be UTF-8; keep their bytes as they are.
    sys.stdin.reconfigure(errors="surrogateescape")
    found, skipped = excludes(sys.stdin, args.root, args.extra)
    for note in skipped:
        print(f"sweep-excludes: skipped ({note})", file=sys.stderr)
    with open(args.output, "w", encoding="utf-8", errors="surrogateescape") as out:
        out.write("".join(p + "\0" for p in found))
    print(f"{len(found)} paths left out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
