#!/usr/bin/env python3
"""The save chip's blank contents, as a block-RAM init file.

rtl/cart/save_spi.sv models the cart's save part as a simple dual-port block
RAM, and a blank part — an erased flash, a factory-fresh FRAM, an unwritten
EEPROM — reads FFh everywhere. In simulation that was an `initial` loop over
all 65,536 bytes, which Quartus cannot elaborate ("loop must terminate within
5000 iterations"), so the core did not build at all. Quartus does support
initialising an inferred RAM from a file, so the contents live here instead:

    reg [7:0] mem [0:65535];
    initial $readmemh("rtl/cart/save_blank.hex", mem);

Regenerate with:

    python tools/gen_save_blank.py --write      # from fpga/
"""
import sys

WORDS = 65536          # 64 KB, the largest save the part types cover
PATH = "rtl/cart/save_blank.hex"


def contents():
    return "".join("ff\n" for _ in range(WORDS))


def main():
    text = contents()
    if len(sys.argv) > 1 and sys.argv[1] == "--write":
        with open(PATH, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        print("wrote %s (%d bytes)" % (PATH, WORDS))
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
