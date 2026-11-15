#!/usr/bin/env python3
"""Keep the fixed SDRAM regions from overlapping.

One 32 MB module holds everything here: main RAM, the save area, the VRAM
banks and the Slot-2 expansion pak. The pak's base and the bank map's
ceiling live in two different modules and neither is checked at
elaboration, so this reads both from the RTL and fails if they meet --
which is what would happen if the bank map ever grew.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The banks reserve 4 MB of address space in README's map but only reach
# 0x6B0000; this is the headroom the pak base relies on.
MIN_HEADROOM = 0x8000      # halfwords, 64 KB


def constant(path, name):
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(name + r"\s*=\s*\d+'h([0-9a-fA-F_]+)", text)
    if not m:
        return None
    return int(m.group(1).replace("_", ""), 16)


def main():
    top = constant(ROOT / "rtl/video/vram_arbiter.sv", "VRAM_SDRAM_TOP")
    exp = constant(ROOT / "rtl/bus/main_bus.sv", "EXP_SDRAM_BASE")
    if top is None or exp is None:
        print("check_memmap: cannot read VRAM_SDRAM_TOP / EXP_SDRAM_BASE")
        return 1
    if exp <= top:
        print("check_memmap: the expansion pak at 0x%06x overlaps the VRAM "
              "banks, which reach 0x%06x" % (exp, top))
        return 1
    head = exp - top
    if head < MIN_HEADROOM:
        print("check_memmap: only 0x%x halfwords of headroom between the "
              "VRAM banks and the pak" % head)
        return 1
    print("check_memmap: ok, VRAM banks reach 0x%06x, pak base 0x%06x, "
          "%d KB clear" % (top, exp, head * 2 // 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
