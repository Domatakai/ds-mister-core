#!/usr/bin/env python3
"""Check the documents for two layout faults.

A table row that continues onto a line with no leading pipe ends the table
there for a renderer, and a prose line past 79 columns is hard to read in a
diff. Both are reported with their `file:line` and the script exits 1 when
it finds any:

  python fpga/tools/check_docs.py            # the fpga documents
  python fpga/tools/check_docs.py README.md docs

Columns are counted as characters, not bytes: an em dash is one column and
three bytes, and counting bytes once hid four long lines. Table rows and the
lines inside fenced blocks are exempt from the width limit, because table
rows cannot be wrapped without breaking the table and quoted tool output has
to stay as it was printed.
"""

import io
import os
import sys

LIMIT = 79
SKIP = {".git", "node_modules", ".freebuff", "dist", "build", ".next",
        "__pycache__"}


def project_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir))


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
