#!/usr/bin/env python3
"""Self-test for check_docs.py.

Builds throwaway document trees and runs the checker over them, so the rules
can be re-checked after any change:

  python fpga/tools/test_check_docs.py

One line per case; exits 1 if any of them fails. The repository is not
touched - each case works in a temporary directory that is removed again at
the end.
"""

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "check_docs.py")
EOL = chr(13) + chr(10)

failures = []
count = 0


def check(name, good, detail=""):
    global count
    count += 1
    print("%-52s %s" % (name, "ok" if good else "FAIL"))
    if not good:
        failures.append((name, detail))


def new():
    root = tempfile.mkdtemp(prefix="ndsdocs")
    os.makedirs(os.path.join(root, "tools"))
    shutil.copy2(TOOL, os.path.join(root, "tools", "check_docs.py"))
    return root


def write(root, name, text):
    path = os.path.join(root, name)
    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)
    io.open(path, "wb").write(text.replace(chr(10), EOL).encode("utf-8"))
    return path


def run(root, *args):
    done = subprocess.run(
        [sys.executable, os.path.join(root, "tools", "check_docs.py")]
        + list(args),
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def run_real(*paths):
    """Run the checker over real documents, as a person would."""
    done = subprocess.run(
        [sys.executable, TOOL] + list(paths),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def table(*rows):
    body = ["| a | b |", "|---|---|"] + list(rows)
    return chr(10).join(body) + chr(10)


def main():
    root = new()
    write(root, "docs/clean.md", "A short line." + chr(10) + chr(10)
          + table("| 1 | 2 |"))
    rc, out = run(root, "docs")
    check("clean document passes", rc == 0 and "docs ok: 1 file" in out, out)

    root = new()
    write(root, "docs/split.md", table("| 1 | ends here") + "tail |" + chr(10))
    rc, out = run(root, "docs")
    check("split table row fails with its line",
          rc == 1
          and "split.md:4: table row continues without a leading pipe" in out,
          out)

    root = new()
    write(root, "docs/long.md", "x" * 80 + chr(10))
    rc, out = run(root, "docs")
    check("prose over 79 columns fails",
          rc == 1 and "long.md:1: prose is 80 columns (limit 79)" in out, out)

    root = new()
    write(root, "docs/edge.md", "x" * 79 + chr(10))
    rc, out = run(root, "docs")
    check("prose at exactly 79 columns passes", rc == 0, out)

    root = new()
    write(root, "docs/wide.md", table("| " + "y" * 120 + " | z |"))
    rc, out = run(root, "docs")
    check("long table row passes", rc == 0, out)

    root = new()
    write(root, "docs/fence.md",
          "```" + chr(10) + "z" * 150 + chr(10) + "```" + chr(10))
    rc, out = run(root, "docs")
    check("long line in a fence passes", rc == 0, out)

    root = new()
    write(root, "docs/after.md",
          table("| 1 | 2 |") + "prose straight after the table" + chr(10))
    rc, out = run(root, "docs")
    check("prose after a closed row is reported",
          rc == 1 and "after.md:4: table row continues" in out, out)

    root = new()
    write(root, "docs/dash.md", "\u2014" * 79 + chr(10))
    rc, out = run(root, "docs")
    check("79 em dashes pass (characters, not bytes)",
          rc == 0 and "docs ok: 1 file" in out, out)

    root = new()
    write(root, "docs/dash2.md", "\u2014" * 80 + chr(10))
    rc, out = run(root, "docs")
    check("80 em dashes fail at 80 columns",
          rc == 1 and "prose is 80 columns" in out, out)

    root = new()
    write(root, "docs/clean.md", "fine" + chr(10))
    write(root, "docs/node_modules/pkg/README.md", "x" * 90 + chr(10))
    rc, out = run(root, "docs")
    check("dependency directories are skipped", rc == 0, out)

    root = new()
    write(root, "docs/a.md", "x" * 80 + chr(10))
    write(root, "docs/b.md", table("| 1 |") + "tail |" + chr(10))
    rc, out = run(root, "docs")
    check("counts problems across files",
          rc == 1 and "2 problem(s) in 2 of 2 file(s)" in out, out)

    root = new()
    write(root, "docs/one.md", "x" * 81 + chr(10))
    rc, out = run(root, "docs/one.md")
    check("a file path is checked directly",
          rc == 1 and "one.md:1: prose is 81 columns" in out, out)

    root = new()
    rc, out = run(root, "nope")
    check("a missing path is an error",
          rc == 2 and "no such file or directory: nope" in out, out)

    root = new()
    write(root, "AREA.md", "x" * 80 + chr(10))
    rc, out = run(root)
    check("no argument checks the project directory",
          rc == 1 and "AREA.md:1: prose" in out, out)

    root = new()
    write(root, "docs/hd.md",
          "### Decoder fixes (2026-11-07, rebuilt" + chr(10)
          + "2026-11-09)" + chr(10))
    rc, out = run(root, "docs")
    check("heading with an unclosed bracket fails",
          rc == 1 and "hd.md:1: heading continues onto the next line" in out,
          out)

    root = new()
    write(root, "docs/hd2.md",
          "## Sizing," + chr(10) + chr(10) + "Prose." + chr(10))
    rc, out = run(root, "docs")
    check("heading ending in a comma fails",
          rc == 1 and "hd2.md:1: heading continues" in out, out)

    root = new()
    write(root, "docs/hd3.md",
          "## A long heading that runs most of the width and then stops"
          + chr(10) + "carries on here" + chr(10))
    rc, out = run(root, "docs")
    check("long heading followed by lowercase text fails",
          rc == 1 and "hd3.md:1: heading continues" in out, out)

    root = new()
    write(root, "docs/hd4.md",
          "## A long heading that runs most of the width and then stops"
          + chr(10) + "A separate sentence follows." + chr(10))
    rc, out = run(root, "docs")
    check("long heading followed by a capital passes", rc == 0, out)

    root = new()
    write(root, "docs/hd5.md",
          "## Balanced heading (2026-11-07)" + chr(10) + chr(10) + "Prose."
          + chr(10))
    rc, out = run(root, "docs")
    check("a closed heading passes", rc == 0, out)

    root = new()
    write(root, "docs/hd6.md",
          "```" + chr(10) + "# a comment (unclosed"
          + chr(10) + "```" + chr(10))
    rc, out = run(root, "docs")
    check("a heading-like comment in a fence passes", rc == 0, out)

    root = new()
    write(root, "docs/hd7.md",
          "### Fixing the fitter" + chr(10) + "and the report" + chr(10)
          + chr(10) + "Prose." + chr(10))
    rc, out = run(root, "docs")
    check("short heading wrapped onto a fragment fails",
          rc == 1 and "hd7.md:1: heading continues" in out, out)

    root = new()
    write(root, "docs/hd8.md",
          "## Notes" + chr(10) + "first line of the paragraph" + chr(10)
          + "which runs on." + chr(10))
    rc, out = run(root, "docs")
    check("a lowercase paragraph after a heading passes", rc == 0, out)

    root = new()
    write(root, "docs/hd9.md",
          "## Notes" + chr(10) + "see the table." + chr(10))
    rc, out = run(root, "docs")
    check("a lowercase sentence after a heading passes", rc == 0, out)

    root = new()
    write(root, "docs/hd10.md",
          "## Usage" + chr(10) + "run the tool with the path" + chr(10)
          + chr(10) + "More prose." + chr(10))
    rc, out = run(root, "docs")
    check("a lowercase imperative after a heading passes", rc == 0, out)

    targets = [os.path.dirname(HERE)]
    repo = os.path.dirname(targets[0])
    if os.path.isdir(os.path.join(repo, ".git")):
        targets.append(repo)
    bad = []
    files = 0
    for target in targets:
        rc, out = run_real(target)
        found = re.search(r"docs ok: (\d+) file", out)
        if rc != 0 or not found or int(found.group(1)) < 1:
            bad.append(out)
            continue
        files += int(found.group(1))
    check("the real documents pass",
          not bad and files >= len(targets),
          "".join(bad) or "checked %d file(s)" % files)
    print()
    if failures:
        print("%d of %d cases failed" % (len(failures), count))
        for name, detail in failures:
            print("FAILED: %s" % name)
            if detail:
                print(detail)
        return 1
    print("%d cases passed" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
