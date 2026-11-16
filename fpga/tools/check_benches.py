#!/usr/bin/env python3
"""Every bench in tb/ is compiled and run by the README's snippet.

The snippet is what `run_benches.py` executes, so a bench file listed in the
documentation but never wired into it is a test nobody runs -- and one that
still claims [SIM-VERIFIED]. That happened to `tb/tb_mic_adc.sv`: it was in
the bench table for months and the snippet had no step for it.

This checks the shape rather than trusting the tables:
  * every tb/tb_*.sv appears as a source in some step,
  * every step's `vvp` runs the binary its `iverilog -o` produced, since a
    mismatch silently re-runs a stale build,
  * every step that compiles something also runs it.

  python tools/check_benches.py             # the real README
  python tools/check_benches.py --verbose   # list each step as it is read
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_benches


def bench_sources(text):
    """The tb/tb_*.sv files the snippet compiles."""
    return set(re.findall(r"tb/(tb_[a-z0-9_]+)\.sv", text))


def audit(steps, benches):
    """Return a list of problems; empty means every bench is wired up."""
    problems = []
    compiled = {}
    for name, cc, run in steps:
        for b in re.findall(r"tb/(tb_[a-z0-9_]+)\.sv", cc):
            compiled.setdefault(b, []).append(name)
        if not cc.startswith("iverilog"):
            continue
        out = re.search(r"-o\s+(\S+)", cc)
        if out is None:
            problems.append("step %s has no -o output" % name)
            continue
        want = out.group(1)
        if run is None:
            problems.append("step %s compiles %s but never runs it"
                            % (name, want))
            continue
        got = run.split()[1] if len(run.split()) > 1 else ""
        if got != want:
            problems.append("step %s builds %s but runs %s"
                            % (name, want, got))
    for b in sorted(benches):
        if b not in compiled:
            problems.append("%s is in tb/ but no snippet step compiles it" % b)
    return problems


def main():
    verbose = "--verbose" in sys.argv[1:]
    steps = run_benches.steps("README.md")
    benches = sorted(f[:-3] for f in os.listdir("tb")
                     if f.startswith("tb_") and f.endswith(".sv"))
    if verbose:
        for name, cc, _ in steps:
            print("  %-22s %s" % (name, cc.split()[0]))
    problems = audit(steps, benches)
    for p in problems:
        print("FAIL %s" % p)
    print("check_benches: %d benches, %d snippet steps"
          % (len(benches), len(steps)))
    # the verdict line ends with the verdict: run_benches.py reads it as one
    print("check_benches: %s" % ("FAIL" if problems else "PASS"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
