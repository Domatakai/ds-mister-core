#!/usr/bin/env python3
"""Read a Quartus build's state from its logs and reports, without grep.

The hand-written pipelines this replaces were the source of most of the
mistakes during the area work, and each mistake has a cause worth naming:

  * Quartus pads its logs with NUL bytes, so a pattern can be present and
    still not match until the padding is stripped;
  * rows in its reports are indented, so a pattern anchored at the line
    start (`^Error`, `^; Total LABs`) silently matches nothing;
  * an alternation handed to a shell tool unquoted splits differently than
    intended, and `tail -2` can cut away the one line that decided the
    verdict;
  * a log Quartus has not flushed yet reads as "nothing happened" while the
    build is running perfectly well.

This reader strips NULs, searches unanchored on stripped lines, reads whole
files, and distinguishes "no verdict yet" from "failed" and "clean".

Exit status: 0 clean, 1 errors, 2 no verdict yet, 3 bad usage.
"""
import argparse
import os
import re
import sys

STAGE_NEEDLES = (
    "placement was successful",
    "placement operations ending",
    "routing operations beginning",
    "routing operations ending",
    "Fitter was successful",
    "Fitter was unsuccessful",
    "Assembler was successful",
    "Assembler was unsuccessful",
    "Timing requirements not met",
)


def read(path):
    """Whole file, NUL padding stripped. Returns (text, present)."""
    if not path:
        return "", False
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return "", False
    return raw.replace(b"\x00", b"").decode("utf-8", "replace"), True


def rows(text):
    return [line.strip() for line in text.splitlines()]


def find(pattern, text, flags=re.I):
    return re.search(pattern, text, flags)


def first_match(pattern, text, flags=re.I):
    for line in rows(text):
        if re.search(pattern, line, flags):
            return line
    return None


def all_matching(pattern, text, flags=0):
    return [line for line in rows(text) if re.search(pattern, line, flags)]


def slacks(text):
    out = {}
    for line in rows(text):
        match = re.search(r"Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is (-?[\d.]+)", line, re.I)
        if match:
            out[match.group(1).lower()] = match.group(2)
    return out


def error_lines(text):
    out = []
    for line in rows(text):
        low = line.lower()
        if low.startswith("error") or low.startswith("critical warning (188026)"):
            out.append(line)
    return out


class _Parser(argparse.ArgumentParser):
    """Usage errors get their own exit code: 2 already means "no verdict yet"."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print("%s: error: %s" % (self.prog, message), file=sys.stderr)
        raise SystemExit(3)


def main(argv=None):
    parser = _Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default=".", help="project directory (default: .)")
    parser.add_argument("--map-log", default=None)
    parser.add_argument("--fit-log", default=None)
    parser.add_argument("--asm-log", default=None)
    parser.add_argument("--sta-log", default=None)
    parser.add_argument("--errors", type=int, default=5, help="how many error lines to print")
    args = parser.parse_args(argv)

    outputs = os.path.join(args.dir, "output_files")
    logs = {
        "map": args.map_log or "",
        "fit": args.fit_log or os.path.join(outputs, "NDS.fit.rpt"),
        "asm": args.asm_log or os.path.join(outputs, "NDS.asm.rpt"),
        "sta": args.sta_log or os.path.join(outputs, "NDS.sta.rpt"),
    }
    reports = {
        "fit report": os.path.join(outputs, "NDS.fit.rpt"),
        "rbf": os.path.join(outputs, "NDS.rbf"),
    }

    text = {}
    present = {}
    for stage, path in list(logs.items()) + list(reports.items()):
        text[stage], present[stage] = read(path)

    verdict = None
    for stage in ("fit", "asm"):
        body = text.get(stage, "")
        if find(r"Fitter was successful\. (\d+) errors, (\d+) warnings", body):
            match = find(r"Fitter was successful\. (\d+) errors, (\d+) warnings", body)
            verdict = ("clean", "fitter: %s errors, %s warnings" % (match.group(1), match.group(2)))
        elif find(r"Assembler was successful\. (\d+) errors, (\d+) warnings", body):
            match = find(r"Assembler was successful\. (\d+) errors, (\d+) warnings", body)
            verdict = ("clean", "assembler: %s errors, %s warnings" % (match.group(1), match.group(2)))
        elif find(r"was unsuccessful", body):
            verdict = ("failed", "%s failed" % stage)
            break

    print("project : %s" % os.path.abspath(args.dir))
    for stage in ("map", "fit", "asm", "sta"):
        path = logs[stage]
        if present[stage]:
            status = "read"
        elif path:
            status = "absent (%s)" % path
        else:
            status = "not given"
        print("%-8s: %s" % (stage, status))

    stages = [needle for needle in STAGE_NEEDLES if find(re.escape(needle), text.get("fit", ""))]
    print("stages  : %s" % (", ".join(stages) if stages else "none recorded"))

    timing = slacks(text.get("sta", ""))
    if timing:
        print("slacks  : " + "  ".join("%s %s ns" % (key, timing[key]) for key in
                                       ("setup", "hold", "recovery", "removal", "minimum pulse width") if key in timing))
    else:
        print("slacks  : none reported")

    fitrpt = text.get("fit report", "")
    labs = find(r"Total LABs:[^;]*;\s*([\d,]+ / [\d,]+)", fitrpt)
    interconnect = find(r"Peak interconnect usage[^;]*;\s*([^;]+);", fitrpt)
    if labs:
        print("LABs    : %s" % labs.group(1))
    if interconnect:
        print("interconn: %s" % interconnect.group(1).strip())

    size = None
    rbf = reports["rbf"]
    if os.path.exists(rbf):
        size = os.path.getsize(rbf)
        print("rbf     : %d bytes" % size)

    problems = []
    for stage in ("map", "fit", "asm"):
        problems += error_lines(text.get(stage, ""))
    if problems:
        print("errors  : %d" % len(problems))
        for line in problems[:args.errors]:
            print("          " + line[:160])
    else:
        print("errors  : none found")

    if problems:
        code = 1
    elif verdict and timing:
        code = 0
    else:
        code = 2
    print("verdict : %s" % ("clean" if code == 0 else "errors" if code == 1 else "no verdict yet (still building, or not started)"))
    return code


if __name__ == "__main__":
    sys.exit(main())
