#!/usr/bin/env python3
"""The bench-wiring guard has to catch the shapes it exists for.

Each case below hands `check_benches.audit` a step list with something wrong
in it and requires a problem back. A guard that only ever sees a clean tree
proves nothing, which is the failure this whole file is about.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_benches

passed = failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print("ok   %s" % name)
    else:
        failed += 1
        print("FAIL %s" % name)


def step(name, cc, run):
    return (name, cc, run)


good = [step("tb_a", "iverilog -g2012 -o /tmp/tb_a tb/tb_a.sv rtl/a.sv",
             "vvp /tmp/tb_a"),
        step("tb_b", "iverilog -g2012 -o /tmp/tb_b tb/tb_b.sv rtl/b.sv",
             "vvp /tmp/tb_b")]

check("a fully wired pair passes",
      check_benches.audit(good, ["tb_a", "tb_b"]) == [])

# a bench in tb/ that no step compiles
check("an unrun bench is reported",
      any("tb_c" in p for p in
          check_benches.audit(good, ["tb_a", "tb_b", "tb_c"])))

# the vvp name drifting from the -o name: this is how a stale build runs
drift = [step("tb_a", "iverilog -g2012 -o /tmp/tb_a tb/tb_a.sv rtl/a.sv",
              "vvp /tmp/tb_old")]
check("a step running another binary is reported",
      any("runs /tmp/tb_old" in p for p in check_benches.audit(drift, ["tb_a"])))

# a compile with no run at all
norun = [step("tb_a", "iverilog -g2012 -o /tmp/tb_a tb/tb_a.sv rtl/a.sv", None)]
check("a compile that is never run is reported",
      any("never runs it" in p for p in check_benches.audit(norun, ["tb_a"])))

# and the real tree
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
print("\n%d passed, %d failed" % (passed, failed))
print("test_check_benches: %s" % ("FAIL" if failed else "PASS"))
sys.exit(1 if failed else 0)
