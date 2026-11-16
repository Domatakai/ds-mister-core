#!/usr/bin/env python3
"""Prove check_memmap fails when either split is broken.

A guard that only ever prints PASS is worthless, so each case here edits a
copy of the RTL the way a careless change would and expects the checker to
refuse it: the pak base dropped onto the VRAM banks, the VRAM map grown
into the pak, the cart's slot bits widened into the pak's DDR3 lines, and
the pak's line base moved down into the cart's.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FILES = ["rtl/video/vram_arbiter.sv", "rtl/bus/main_bus.sv",
         "rtl/mem/exp_ddr.sv", "rtl/cart/cart_slot.sv"]

passed = failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print("ok   %s" % name)
    else:
        failed += 1
        print("FAIL %s" % name)


def tree_with(edit=None, old=None, new=None):
    d = Path(tempfile.mkdtemp(prefix="memmap-"))
    for f in FILES:
        dst = d / f
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / f, dst)
    if edit:
        p = d / edit
        s = p.read_text(encoding="utf-8")
        assert s.count(old) == 1, "test edit did not match in %s" % edit
        p.write_text(s.replace(old, new), encoding="utf-8")
    return d


def run(d):
    r = subprocess.run([sys.executable, str(HERE / "check_memmap.py"),
                        "--rtl", str(d)], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


d = tree_with()
rc, out = run(d)
check("the real tree passes", rc == 0 and "check_memmap: PASS" in out)
check("and it reports both splits",
      "SDRAM" in out and "DDR3" in out)

d = tree_with("rtl/bus/main_bus.sv",
              "EXP_SDRAM_BASE = 25'h700000", "EXP_SDRAM_BASE = 25'h6A0000")
rc, out = run(d)
check("a pak base on the VRAM banks is refused", rc == 1 and "SDRAM" in out)

d = tree_with("rtl/video/vram_arbiter.sv",
              "VRAM_SDRAM_TOP  = 24'h6B_0000", "VRAM_SDRAM_TOP  = 24'h70_0000")
rc, out = run(d)
check("a VRAM map grown into the pak is refused", rc == 1)

d = tree_with("rtl/mem/exp_ddr.sv",
              "EXP_LINE_BASE = 29'h200_0000", "EXP_LINE_BASE = 29'h1F0_0000")
rc, out = run(d)
check("a pak line base inside the cart's lines is refused", rc == 1)

d = tree_with("rtl/cart/cart_slot.sv",
              "input      [1:0]  boot_slot,", "input      [2:0]  boot_slot,")
rc, out = run(d)
check("a cart widened into the pak's lines is refused", rc == 1)

print("\n%d passed, %d failed" % (passed, failed))
# a verdict line the bench runner can read, like the checkers print
print("test_check_memmap: %s" % ("FAIL" if failed else "PASS"))
sys.exit(1 if failed else 0)
