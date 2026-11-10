#!/usr/bin/env python3
"""Check the documents for three layout faults.

A table row that continues onto a line with no leading pipe ends the table
there for a renderer, a prose line past 79 columns is hard to read in a
diff, and a heading whose title runs onto the next line loses the rest of
it, because Markdown ends a heading at the newline. All three are
reported with their `file:line` and the script exits 1 when it finds any:

  python fpga/tools/check_docs.py            # the fpga documents
  python fpga/tools/check_docs.py README.md docs

Columns are counted as characters, not bytes: an em dash is one column and
three bytes, and counting bytes once hid four long lines. Table rows and the
lines inside fenced blocks are exempt from the width limit, because table
rows cannot be wrapped without breaking the table and quoted tool output has
to stay as it was printed. A heading inside a fence is a comment in the
quoted code, so only headings outside fences are checked.
"""

import io
import os
import sys

LIMIT = 79
CONTINUED = 60
SKIP = {".git", "node_modules", ".freebuff", "dist", "build", ".next",
        "__pycache__"}


def project_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir))


def is_heading(line):
    """True for an ATX heading: up to six hashes, then a space or the end."""
    stripped = line.lstrip()
    if not stripped.startswith("#"):
        return False
    hashes = len(stripped) - len(stripped.lstrip("#"))
    rest = stripped[hashes:]
    return hashes <= 6 and (rest == "" or rest.startswith(" "))


def heading_continues(line, nxt):
    """True when a heading looks like a title that was wrapped.

    Markdown has no continued heading: the second line becomes body
    text, so the title a reader sees stops at the newline. The remains
    are a bracket the heading never closes, a trailing comma, or a next
    line that carries the sentence on -- a lowercase word or a closing
    bracket -- under a heading already most of the width.
    """
    body = line.strip()
    if (body.count("(") != body.count(")")
            or body.count("[") != body.count("]")):
        return True
    if body.endswith(","):
        return True
    nxt = nxt.strip()
    if not nxt or len(body) < CONTINUED:
        return False
    return nxt[0].islower() or nxt[0] in "),;"


def markdown_files(paths):
    found = []
    for path in paths:
        if os.path.isfile(path):
            found.append(path)
            continue
        for root, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if d not in SKIP)
            for name in sorted(files):
                if name.lower().endswith(".md"):
                    found.append(os.path.join(root, name))
    return found


def check(path):
    raw = io.open(path, "rb").read().decode("utf-8", "replace")
    lines = raw.replace(chr(13) + chr(10), chr(10)).split(chr(10))
    problems = []
    fenced = False
    table = False
    for n, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
            table = False
            continue
        if not line.strip():
            table = False
            continue
        if fenced:
            continue
        if is_heading(line) and heading_continues(
                line, lines[n + 1] if n + 1 < len(lines) else ""):
            problems.append(
                (n + 1, "heading continues onto the next line"))
            continue
        if line.startswith("|"):
            table = True
            continue
        if table:
            problems.append(
                (n + 1, "table row continues without a leading pipe"))
            continue
        if len(line) > LIMIT:
            problems.append(
                (n + 1, "prose is %d columns (limit %d)" % (len(line), LIMIT)))
    return problems


def main(argv):
    paths = argv or [project_dir()]
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        for path in missing:
            print("no such file or directory: %s" % path)
        return 2
    files = markdown_files(paths)
    total = 0
    bad = 0
    for path in files:
        problems = check(path)
        if problems:
            bad += 1
        for line, why in problems:
            print("%s:%d: %s" % (path, line, why))
            total += 1
    if total:
        print("%d problem(s) in %d of %d file(s)"
              % (total, bad, len(files)))
        return 1
    print("docs ok: %d file(s)" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
