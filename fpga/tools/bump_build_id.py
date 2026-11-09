#!/usr/bin/env python3
"""Move the pinned build stamp, and record it against a built bitstream.

`sys/build_id.tcl` writes BUILD_DATE from `sys/build_id.txt` when that file
carries a stamp, so rebuilds of the same tree produce the same netlist. The
date shown in the core therefore stays put until this script moves it:

  python fpga/tools/bump_build_id.py          # today, YYMMDD
  python fpga/tools/bump_build_id.py 261108   # an explicit stamp

After the build, record which stamp the bitstream carries:

  python fpga/tools/bump_build_id.py --record

That writes output_files/NDS.rbf.stamp with the stamp, its size and SHA-256,
and refuses when the bitstream is older than the stamp or when build_id.v
disagrees with it. Comments in the stamp file are kept.
"""

import argparse
import hashlib
import io
import os
import re
import time

STAMP = re.compile(r"^\d{6}$")


def project_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, os.pardir))


def stamp_file():
    return os.path.join(project_dir(), "sys", "build_id.txt")


def read_stamp():
    path = stamp_file()
    if not os.path.exists(path):
        return None
    raw = io.open(path, "rb").read()
    lines = raw.decode("utf-8").replace("\r\n", "\n").split("\n")
    found = [line.strip() for line in lines if STAMP.match(line.strip())]
    return found[0] if len(found) == 1 else None


def write_stamp(stamp):
    path = stamp_file()
    raw = io.open(path, "rb").read()
    eol = "\r\n" if b"\r\n" in raw else "\n"
    lines = raw.decode("utf-8").replace("\r\n", "\n").split("\n")
    found = [n for n, line in enumerate(lines) if STAMP.match(line.strip())]
    if len(found) != 1:
        print("%s should hold exactly one YYMMDD line, found %d"
              % (path, len(found)))
        return 1
    old = lines[found[0]].strip()
    if old == stamp:
        print("build stamp already %s" % stamp)
        return 0
    lines[found[0]] = stamp
    io.open(path, "wb").write(
        "\n".join(lines).replace("\n", eol).encode("utf-8"))
    print("build stamp %s -> %s" % (old, stamp))
    return 0


def record(rbf, stamp):
    if not os.path.isabs(rbf):
        rbf = os.path.join(project_dir(), rbf)
    if not os.path.exists(rbf):
        print("no bitstream at %s - build it first" % rbf)
        return 1
    build_id = os.path.join(project_dir(), "build_id.v")
    if os.path.exists(build_id):
        text = io.open(build_id, "rb").read().decode("utf-8", "replace")
        found = re.search(r'BUILD_DATE\s+"(\d{6})"', text)
        if found and found.group(1) != stamp:
            print("build_id.v holds %s but the pin is %s: rebuild before "
                  "recording" % (found.group(1), stamp))
            return 1
        if os.path.getmtime(build_id) > os.path.getmtime(rbf):
            print("%s is older than build_id.v: rebuild before recording"
                  % os.path.basename(rbf))
            return 1
    data = io.open(rbf, "rb").read()
    side = rbf + ".stamp"
    lines = [
        "build stamp: %s" % stamp,
        "bitstream: %s" % os.path.basename(rbf),
        "bytes: %d" % len(data),
        "sha256: %s" % hashlib.sha256(data).hexdigest(),
        "recorded: %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
    ]
    io.open(side, "wb").write(("\r\n".join(lines) + "\r\n").encode("utf-8"))
    print("recorded %s -> %s"
          % (os.path.basename(rbf), os.path.basename(side)))
    for line in lines:
        print("  " + line)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stamp", nargs="?",
                        help="six digits, YYMMDD (default: today)")
    parser.add_argument("--record", nargs="?", const="output_files/NDS.rbf",
                        metavar="RBF",
                        help="record the stamp against a built bitstream")
    args = parser.parse_args(argv)

    if args.stamp is not None:
        if not STAMP.match(args.stamp):
            parser.error("stamp must be six digits, YYMMDD: %r" % args.stamp)
        code, stamp = write_stamp(args.stamp), args.stamp
    elif args.record:
        stamp = read_stamp()
        if stamp is None:
            print("no pinned stamp in %s" % stamp_file())
            return 2
        code = 0
    else:
        today = time.strftime("%y%m%d")
        code, stamp = write_stamp(today), today
        if code == 0:
            print("rebuild so the bitstream carries it")

    if code:
        return code
    if args.record:
        return record(args.record, stamp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
