#!/usr/bin/env python3
"""Move the pinned build stamp before cutting a release bitstream.

`sys/build_id.tcl` writes BUILD_DATE from `sys/build_id.txt` when that file
carries a stamp, so rebuilds of the same tree produce the same netlist. The
date shown in the core therefore stays put until this script moves it:

  python fpga/tools/bump_build_id.py          # today, YYMMDD
  python fpga/tools/bump_build_id.py 261108   # an explicit stamp

Comments in the stamp file are kept, and so are its line endings.
"""

import argparse
import io
import os
import re
import time

STAMP = re.compile(r"^\d{6}$")


def stamp_file():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir, "sys", "build_id.txt"))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stamp", nargs="?",
                        help="six digits, YYMMDD (default: today)")
    args = parser.parse_args(argv)

    stamp = args.stamp or time.strftime("%y%m%d")
    if not STAMP.match(stamp):
        parser.error("stamp must be six digits, YYMMDD: %r" % stamp)

    path = stamp_file()
    if not os.path.exists(path):
        print("no stamp file at %s" % path)
        return 2

    raw = io.open(path, "rb").read()
    eol = "\r\n" if b"\r\n" in raw else "\n"
    lines = raw.decode("utf-8").replace("\r\n", "\n").split("\n")
    found = [n for n, line in enumerate(lines) if STAMP.match(line.strip())]
    if len(found) != 1:
        print("%s should hold exactly one YYMMDD line, found %d"
              % (path, len(found)))
        return 2

    old = lines[found[0]].strip()
    if old == stamp:
        print("build stamp already %s" % stamp)
        return 0

    lines[found[0]] = stamp
    io.open(path, "wb").write(
        "\n".join(lines).replace("\n", eol).encode("utf-8"))
    print("build stamp %s -> %s" % (old, stamp))
    print("rebuild so the bitstream carries it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
