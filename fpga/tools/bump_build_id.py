#!/usr/bin/env python3
"""Move the pinned build stamp, and record or check it against a bitstream.

`sys/build_id.tcl` writes BUILD_DATE from `sys/build_id.txt` when that file
carries a stamp, so rebuilds of the same tree produce the same netlist. The
date shown in the core therefore stays put until this script moves it:

  python fpga/tools/bump_build_id.py          # today, YYMMDD
  python fpga/tools/bump_build_id.py 261108   # an explicit stamp

After the build, record which stamp the bitstream carries:

  python fpga/tools/bump_build_id.py --record

That writes output_files/NDS.rbf.stamp with the stamp, its size and SHA-256.
It refuses when the bitstream is older than the stamp or when build_id.v
disagrees with it. Before copying a bitstream to a card, check a record
that is already there against the file and the current pin:

  python fpga/tools/bump_build_id.py --verify

Add `--strict` to that check to make a record older than the pin a failure
rather than a warning:

  python fpga/tools/bump_build_id.py --verify --strict

Comments in the stamp file are kept.
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


def bitstream_path(rbf):
    if not os.path.isabs(rbf):
        rbf = os.path.join(project_dir(), rbf)
    return rbf


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


def read_record(side):
    fields = {}
    if not os.path.exists(side):
        return fields
    text = io.open(side, "rb").read().decode("utf-8", "replace")
    for line in text.replace("\r\n", "\n").split("\n"):
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def record(rbf, stamp):
    rbf = bitstream_path(rbf)
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
    lines = [
        "build stamp: %s" % stamp,
        "bitstream: %s" % os.path.basename(rbf),
        "bytes: %d" % len(data),
        "sha256: %s" % hashlib.sha256(data).hexdigest(),
        "recorded: %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
    ]
    payload = "\r\n".join(lines) + "\r\n"
    io.open(rbf + ".stamp", "wb").write(payload.encode("utf-8"))
    print("recorded %s -> %s"
          % (os.path.basename(rbf), os.path.basename(rbf) + ".stamp"))
    for line in lines:
        print("  " + line)
    return 0


def verify(rbf, stamp, strict=False):
    rbf = bitstream_path(rbf)
    side = rbf + ".stamp"
    name = os.path.basename(side)
    if not os.path.exists(side):
        print("no record at %s - run --record after a build" % side)
        return 1
    if not os.path.exists(rbf):
        print("no bitstream at %s" % rbf)
        return 1
    fields = read_record(side)
    data = io.open(rbf, "rb").read()
    digest = hashlib.sha256(data).hexdigest()
    problems = []
    pin_path = stamp_file()
    if os.path.exists(pin_path):
        if os.path.getmtime(side) < os.path.getmtime(pin_path):
            stale = ("%s is older than sys/build_id.txt - the pin changed"
                     " after it was recorded" % name)
            if strict:
                problems.append(stale)
            else:
                print("warning: " + stale)
    if fields.get("build stamp") != stamp:
        problems.append("record holds stamp %s, the pin is %s"
                        % (fields.get("build stamp"), stamp))
    if fields.get("bytes") != str(len(data)):
        problems.append("record holds %s bytes, the bitstream has %d"
                        % (fields.get("bytes"), len(data)))
    if fields.get("sha256") != digest:
        problems.append("record holds sha256 %s, the bitstream hashes %s"
                        % ((fields.get("sha256") or "none")[:12],
                           digest[:12]))
    if problems:
        for problem in problems:
            print(problem)
        print("%s does not describe %s"
              % (name, os.path.basename(rbf)))
        return 1
    print("%s matches %s: stamp %s, %d bytes"
          % (name, os.path.basename(rbf), stamp, len(data)))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stamp", nargs="?",
                        help="six digits, YYMMDD (default: today)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--record", nargs="?", const="output_files/NDS.rbf",
                      metavar="RBF",
                      help="record the stamp against a built bitstream")
    mode.add_argument("--verify", nargs="?", const="output_files/NDS.rbf",
                      metavar="RBF",
                      help="check an existing record against the bitstream")
    parser.add_argument("--strict", action="store_true",
                        help="fail when the record predates the pin")
    args = parser.parse_args(argv)
    if args.strict and not args.verify:
        parser.error("--strict only applies to --verify")

    if args.stamp is not None:
        if not STAMP.match(args.stamp):
            parser.error("stamp must be six digits, YYMMDD: %r" % args.stamp)
        return write_stamp(args.stamp)

    if not (args.record or args.verify):
        today = time.strftime("%y%m%d")
        code = write_stamp(today)
        if code == 0:
            print("rebuild so the bitstream carries it")
        return code

    stamp = read_stamp()
    if stamp is None:
        print("no pinned stamp in %s" % stamp_file())
        return 2
    if args.record:
        return record(args.record, stamp)
    return verify(args.verify, stamp, args.strict)


if __name__ == "__main__":
    raise SystemExit(main())
