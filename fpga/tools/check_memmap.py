#!/usr/bin/env python3
"""Keep the fixed memory regions from overlapping, in SDRAM and in DDR3.

Two splits are load-bearing and neither is checked at elaboration:

* SDRAM -- main RAM, the save area, the VRAM banks and the Slot-2 pak all
  share one 32 MB module. The pak's base lives in main_bus, the bank map's
  ceiling in vram_arbiter.
* DDR3 -- the cart ROM and the pak's lines share one port. The cart
  addresses `{boot_slot, win_addr[25:3]}` and the pak starts at
  EXP_LINE_BASE; the pak is safe only while that base sits above every
  line the cart can name.

Both sides of both splits are read from the RTL here, so widening either
one fails this check instead of quietly aliasing onto the other.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The banks reserve 4 MB of address space in README's map but only reach
# 0x6B0000; this is the headroom the pak base relies on.
MIN_HEADROOM = 0x8000      # halfwords, 64 KB


def text(path):
    return path.read_text(encoding="utf-8", errors="replace")


def constant(path, name):
    m = re.search(name + r"\s*=\s*\d+'h([0-9a-fA-F_]+)", text(path))
    if not m:
        return None
    return int(m.group(1).replace("_", ""), 16)


def cart_line_range(path):
    """The highest line the cart can ask DDR3 for, from its own mapping."""
    body = text(path)
    m = re.search(r"\{\s*boot_slot\s*,\s*win_addr\[(\d+):(\d+)\]\s*\}", body)
    if not m:
        return None
    hi, lo = int(m.group(1)), int(m.group(2))
    idx_bits = hi - lo + 1
    s = re.search(r"input\s*\[(\d+):0\]\s*boot_slot", body)
    if not s:
        return None
    slot_bits = int(s.group(1)) + 1
    return (((1 << slot_bits) - 1) << idx_bits) | ((1 << idx_bits) - 1)


def check_sdram(root):
    top = constant(root / "rtl/video/vram_arbiter.sv", "VRAM_SDRAM_TOP")
    exp = constant(root / "rtl/bus/main_bus.sv", "EXP_SDRAM_BASE")
    if top is None or exp is None:
        print("check_memmap: FAIL -- cannot read VRAM_SDRAM_TOP / "
              "EXP_SDRAM_BASE")
        return False
    if exp <= top:
        print("check_memmap: FAIL (SDRAM) -- the expansion pak at 0x%06x overlaps "
              "the VRAM banks, which reach 0x%06x" % (exp, top))
        return False
    head = exp - top
    if head < MIN_HEADROOM:
        print("check_memmap: FAIL (SDRAM) -- only 0x%x halfwords of headroom "
              "between the VRAM banks and the pak" % head)
        return False
    print("check_memmap: SDRAM banks reach 0x%06x, pak base 0x%06x, "
          "%d KB clear" % (top, exp, head * 2 // 1024))
    return True


def check_ddr3(root):
    base = constant(root / "rtl/mem/exp_ddr.sv", "EXP_LINE_BASE")
    top = cart_line_range(root / "rtl/cart/cart_slot.sv")
    if base is None or top is None:
        print("check_memmap: FAIL (DDR3) -- cannot read EXP_LINE_BASE / the cart's "
              "line mapping")
        return False
    if base <= top:
        print("check_memmap: FAIL (DDR3) -- the pak's lines start at 0x%07x but the "
              "cart can address up to 0x%07x" % (base, top))
        return False
    gap = base - top - 1
    print("check_memmap: DDR3 cart lines end at 0x%07x, pak starts at "
          "0x%07x (%s)" % (top, base,
                           "adjacent" if gap == 0
                           else "0x%x lines clear" % gap))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=str(ROOT),
                    help="tree to read the constants from (a test points "
                         "this at a copy)")
    a = ap.parse_args()
    root = Path(a.rtl)
    ok = check_sdram(root) and check_ddr3(root)
    print("check_memmap: PASS" if ok else "check_memmap: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
