#!/usr/bin/env python3
"""Run the benches exactly as the README documents them, with a memory guard.

The README's *Simulation* section is the single source of truth: its shell
snippet compiles and runs every bench. This script extracts that snippet and
runs each bench's compile and simulation as its own step, reporting one line
per bench from the verdicts the benches print ("TB <name> PASS" /
"tb_<name>: PASS").

Each step is watched by tools/bench_guard.py, which kills it if available
memory falls below --min-free or it outlives --max-seconds. That matters on a
small machine: a runaway bench once committed 28 GB here, and Windows answers
commit exhaustion with a freeze and a bugcheck instead of an allocation
failure, so an unguarded run takes the whole session with it.

Every step writes its own log under %TEMP%/benchlogs (or /tmp/benchlogs), which
keeps a `$display` loop out of this process's memory.

  python tools/run_benches.py                 # everything
  python tools/run_benches.py --only tb_spu   # one bench
  python tools/run_benches.py --min-free 400  # tighter/looser guard
"""
import argparse
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_guard  # noqa: E402


def snippet(text):
    sec = text[text.index("### Simulation"):]
    m = re.search(r"```(?:bash|sh)?\n(.*?)```", sec, re.S)
    if not m:
        raise SystemExit("no shell snippet found under '### Simulation'")
    return m.group(1)


def commands(text):
    """The snippet's commands, with backslash continuations joined."""
    joined, buf = [], ""
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.endswith("\\"):
            buf += s[:-1].strip() + " "
            continue
        joined.append((buf + s).strip())
        buf = ""
    if buf:
        joined.append(buf.strip())
    return [c for c in joined
            if c and not c.startswith("#") and c != "cd fpga"]


def steps(readme):
    """Split the snippet into (name, compile command, run command) triples."""
    sh = snippet(open(readme, encoding="utf-8").read().replace("\r\n", "\n"))
    out, cur = [], None
    for s in commands(sh):
        if s.startswith("iverilog "):
            cur = {"cc": s, "run": None}
        elif s.startswith("vvp ") and cur is not None:
            cur["run"] = s
            out.append(cur)
            cur = None
    named = []
    for n, st in enumerate(out, 1):
        m = re.search(r"-o\s+(\S+)", st["cc"])
        name = os.path.basename(m.group(1)) if m else "bench%02d" % n
        named.append((name, st["cc"], st["run"]))
    return named


def verdicts(text):
    found = re.findall(r"^\s*TB\s+(\S+).*?\b(PASS|FAIL)\s*$", text, re.M)
    found += re.findall(r"^\s*(tb_\S+?):\s*(PASS|FAIL)", text, re.M)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="substring of a step name")
    ap.add_argument("--min-free", type=int, default=0,
                    help="optional physical floor (MB); 0 = guard on commit alone")
    ap.add_argument("--min-commit", type=int, default=600,
                    help="kill a step when commit headroom drops below this (MB)")
    ap.add_argument("--max-seconds", type=int, default=300)
    ap.add_argument("--verbose", action="store_true", help="print every log")
    a = ap.parse_args()

    logs = os.path.join(tempfile.gettempdir(), "benchlogs")
    os.makedirs(logs, exist_ok=True)

    total, failed, passed = 0, 0, 0
    for name, cc, run in steps("README.md"):
        if a.only and a.only not in name:
            continue
        total += 1
        c = bench_guard.run(cc, os.path.join(logs, name + ".cc.log"),
                            a.min_free, a.max_seconds, min_commit_mb=a.min_commit)
        r = None
        if c.ok and run:
            r = bench_guard.run(run, os.path.join(logs, name + ".run.log"),
                                a.min_free, a.max_seconds, min_commit_mb=a.min_commit)
        text = ""
        for f in (os.path.join(logs, name + ".cc.log"), os.path.join(logs, name + ".run.log")):
            if os.path.exists(f):
                text += open(f, encoding="utf-8", errors="replace").read()

        vs = verdicts(text)
        if c.ok and (r is None or r.ok) and vs and all(v == "PASS" for _, v in vs):
            passed += 1
            status = "ok  "
        else:
            failed += 1
            status = "FAIL"

        cost = c.line() if r is None else "compile %s | run %s" % (c.line(), r.line())
        print("%s %-22s %s" % (status, name, cost))
        for vname, v in vs:
            print("     %s %s" % (vname, v))
        if status != "ok  " or a.verbose:
            tail = [l for l in text.splitlines() if l.startswith(("FAIL", "error", "Error"))][:6]
            for l in tail:
                print("     " + l.strip())
            if not text:
                print("     (no output; see %s)" % logs)
        sys.stdout.flush()

    print("\n%d step(s), %d passed, %d failed" % (total, passed, failed))
    return 0 if failed == 0 and total else 1


if __name__ == "__main__":
    sys.exit(main())
