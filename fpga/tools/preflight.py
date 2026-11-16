#!/usr/bin/env python3
"""The gate a push has to pass: every claim in the docs, every bench.

Nothing here needs Quartus or the board, so it can run on any machine that
has iverilog. Two modes:

  python tools/preflight.py          # the guards and the whole suite
  python tools/preflight.py --fast   # the guards only, seconds not minutes

Installing it as this repository's pre-push hook:

  printf '#!/bin/sh\nexec python fpga/tools/preflight.py --fast\n' \
      > .git/hooks/pre-push && chmod +x .git/hooks/pre-push

The hook is local and is not committed; the suite it runs is the one the
documentation quotes, so a push cannot silently carry a stale figure or a
bench nobody compiles.
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARDS = [
    ("check_docs.py", []),
    ("check_memmap.py", []),
    ("check_benches.py", []),
    ("test_check_docs.py", []),
    ("test_check_memmap.py", []),
    ("test_check_benches.py", []),
    ("test_bump_build_id.py", []),
]


def run(args):
    """Run one step; return (ok, tail of its output)."""
    p = subprocess.run([sys.executable] + args, cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace")
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return p.returncode == 0, lines[-1] if lines else "(no output)"


def main():
    fast = "--fast" in sys.argv[1:]
    failed = []
    for script, extra in GUARDS:
        ok, tail = run([os.path.join("tools", script)] + extra)
        print("%s %-22s %s" % ("ok  " if ok else "FAIL", script, tail))
        if not ok:
            failed.append(script)
    if not fast:
        ok, tail = run([os.path.join("tools", "run_benches.py")])
        print("%s %-22s %s" % ("ok  " if ok else "FAIL", "run_benches.py", tail))
        if not ok:
            failed.append("run_benches.py")
    if failed:
        print("\npreflight: FAIL (%s)" % ", ".join(failed))
        return 1
    print("\npreflight: PASS%s" % (" (guards only)" if fast else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
