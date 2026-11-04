#!/usr/bin/env python3
"""Check that figures quoted in the FPGA docs still match the Quartus reports.

Two failures kept recurring while fitting this design:

  * a figure copied into a document, then a rebuild changes it, and the document
    keeps the old value until somebody notices by hand -- `ascal` was quoted at
    8,344 ALUTs, then 2,883, while every report on disk said 2,826;
  * checks that compared strings instead of numbers, so "45,936.820" in a
    document "failed" against "-45936.820" in a report, and a correct document
    looked broken.

So each claim below pairs a pattern in the document with the report field that
produces it, compares them as numbers or as clock stamps, and with --fix rewrites
only the digits of a claim that genuinely drifted, keeping the document's own
digit grouping.

Report inputs (all optional, defaults try --dir/output_files and --dir/*.log):
  --sta-log  captured quartus_sta output   --fit-log  captured quartus_fit output
  --map-rpt  output_files/NDS.map.rpt      --fit-rpt  output_files/NDS.fit.rpt
  --rbf      output_files/NDS.rbf          --map-t6   the t6 map report, for the
                                          entity figures the docs attribute to t6

Exit codes: 0 every claim matches, 1 drift found (or corrected with --fix),
2 no evidence to compare against, 3 bad usage.
"""

import argparse
import os
import re
import sys

# The three (332119) blocks in quartus_sta output appear in this order.
SECTION_ORDER = ["setup", "hold", "recovery", "removal", "pulse"]


def read(path):
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8", "replace")


def as_number(text):
    return float(re.sub(r"[^0-9.\-]", "", text))


def format_like(original, value):
    """Write value using the grouping and sign style of the text being replaced."""
    if "." in original:
        body = "{:,.3f}".format(abs(value)) if "," in original else "{:.3f}".format(abs(value))
    else:
        whole = int(round(value))
        body = "{:,}".format(whole) if "," in original else str(whole)
    return ("-" if value < 0 else "+") + body if original[:1] in "+-" else body


def parse_sta(path):
    """Per-clock slacks and the worst-case summaries, with clock blocks kept apart."""
    text = read(path)
    found = {"clocks": {}}
    for match in re.finditer(
            r"Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is (-?\d+\.\d+)",
            text):
        key = "pulse" if match.group(1) == "minimum pulse width" else match.group(1)
        found[key] = as_number(match.group(2))

    blocks = []
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if "(332119)" not in stripped:
            continue
        parts = stripped.split()
        if len(parts) >= 5 and parts[2] == "Slack" and parts[-1] == "Clock":
            current = {}
            blocks.append(current)
            continue
        if current is None or len(parts) < 5:
            continue
        try:
            slack, tns = as_number(parts[2]), as_number(parts[3])
        except ValueError:
            continue
        current[parts[4]] = (slack, tns)

    for index, block in enumerate(blocks[:len(SECTION_ORDER)]):
        section = SECTION_ORDER[index]
        for clock, pair in block.items():
            found["clocks"][(section, clock)] = pair
    return found


def parse_fit(path):
    text = read(path)
    found = {}
    match = re.search(r"Fitter was successful\.\s*(\d+) errors,\s*(\d+) warnings", text)
    if match:
        found["errors"] = as_number(match.group(1))
        found["warnings"] = as_number(match.group(2))
    match = re.search(r"Info: Elapsed time:\s*(\d\d:\d\d:\d\d)", text)
    if match:
        found["fit_total"] = match.group(1)
    for line in text.splitlines():
        if "routing operations ending" in line:
            stamp = re.search(r"(\d\d:\d\d:\d\d)", line)
            if stamp:
                found["fit_routing"] = stamp.group(1)
    return found


def parse_fit_rpt(path):
    text = read(path)
    match = re.search(r"Total LABs:[^;]*;\s*([\d,]+)\s*/\s*([\d,]+)", text)
    if not match:
        return {}
    return {"labs": as_number(match.group(1)), "labs_total": as_number(match.group(2))}


def parse_map(path):
    text = read(path)
    match = re.search(r"\|\s*ascal:ascal\s*\|\s*;\s*([\d,]+)\s*\([^)]*\)\s*;\s*([\d,]+)", text)
    if not match:
        return {}
    return {"ascal_aluts": as_number(match.group(1)), "ascal_regs": as_number(match.group(2))}


# label, document pattern, {group: evidence key}, evidence source
CLAIMS = [
    # The "current" row is the build the tree ships today. The `after` row is
    # kept as history (t11, before the save file), so these claims point at the
    # label rather than at the word "after".
    ("setup slack", r"\| current \| (-?\d+\.\d{3}) \(emu\)", {1: "setup"}, "sta"),
    ("setup TNS", r"\| current \| -?\d+\.\d{3} \(emu\) \| (-?[\d,]+\.\d{3})",
     {1: "tns@setup:emu|u_pll"}, "sta"),
    ("hold slack", r"\| current \| -?\d+\.\d{3} \(emu\) \| -?[\d,]+\.\d{3} \| "
                    r"(\+?\d+\.\d{3}) \(\w+\) \|", {1: "hold"}, "sta"),
    ("LABs used", r"\| current \| -?\d+\.\d{3} \(emu\) \| -?[\d,]+\.\d{3} \| "
                  r"\+?\d+\.\d{3} \(\w+\) \| (\d{1,2},\d{3}) \|", {1: "labs"}, "fitrpt"),
    ("fit time", r"\| current \| -?\d+\.\d{3} \(emu\) \| -?[\d,]+\.\d{3} \| "
                 r"\+?\d+\.\d{3} \(\w+\) \| \d{1,2},\d{3} \| \d+\.\d/\d+\.\d/\d+\.\d \| "
                 r"(\d\d:\d\d:\d\d) \|", {1: "fit_total"}, "fit"),
    ("routing time", r"Routing falls from \d\d:\d\d:\d\d to (\d\d:\d\d:\d\d)",
     {1: "fit_routing"}, "fit"),
    ("rbf bytes", r"writes a ([\d,]+)-byte `NDS\.rbf`", {1: "rbf_bytes"}, "rbf"),
    ("warning count", r"fitter's warning count drops from\s+\d+ to (\d+)", {1: "warnings"}, "fit"),
    ("ascal ALUTs", r"`ascal` is \*\*([\d,]+)\*\* ALUTs in context", {1: "ascal_aluts"}, "map_t6"),
    ("pll_hdmi slack", r"`pll_hdmi` is (-?\d+\.\d{3}) ns",
     {1: "slack@setup:pll_hdmi|pll_hdmi_inst"}, "sta"),
    ("pll_hdmi TNS", r"`pll_hdmi` is -?\d+\.\d{3} ns with (-?\d+\.\d{3}) of TNS",
     {1: "tns@setup:pll_hdmi|pll_hdmi_inst"}, "sta"),
    ("emu slack", r"the emu domain (-?\d+\.\d{3}) with", {1: "slack@setup:emu|u_pll"}, "sta"),
    ("h2f_user0_clk", r"`h2f_user0_clk` is \+(\d+\.\d{3})",
     {1: "slack@setup:h2f_user0_clk"}, "sta"),
    ("FPGA_CLK1_50", r"`FPGA_CLK1_50` \+(\d+\.\d{3})", {1: "slack@setup:FPGA_CLK1_50"}, "sta"),
    ("FPGA_CLK2_50", r"`FPGA_CLK2_50` \+(\d+\.\d{3})", {1: "slack@setup:FPGA_CLK2_50"}, "sta"),
    ("pll_audio", r"`pll_audio` \+(\d+\.\d{3})", {1: "slack@setup:pll_audio"}, "sta"),
    ("FPGA_CLK3_50", r"`FPGA_CLK3_50` \+(\d+\.\d{3})", {1: "slack@setup:FPGA_CLK3_50"}, "sta"),
    ("recovery", r"recovery \+(\d+\.\d{3})", {1: "recovery"}, "sta"),
    ("removal", r"removal \+(\d+\.\d{3})", {1: "removal"}, "sta"),
    ("pulse width", r"pulse width \+(\d+\.\d{3})", {1: "pulse"}, "sta"),
]


def resolve(key, blob):
    if "@" in key:
        field, rest = key.split("@", 1)
        section, needle = rest.split(":", 1)
        for (sec, clock), pair in blob.get("clocks", {}).items():
            if sec == section and needle in clock:
                return pair[0] if field == "slack" else pair[1]
        return None
    return blob.get(key)


def same_value(quoted, actual):
    if isinstance(actual, str):
        return quoted.replace(":", "") == actual.replace(":", "")
    return round(as_number(quoted), 3) == round(actual, 3)


class _Parser(argparse.ArgumentParser):
    """Usage errors get exit code 3; 2 already means "no evidence"."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print("%s: error: %s" % (self.prog, message), file=sys.stderr)
        raise SystemExit(3)


def main(argv=None):
    parser = _Parser(description=__doc__,
                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--doc", default="fpga/AREA.md")
    parser.add_argument("--dir", default=".")
    parser.add_argument("--sta-log")
    parser.add_argument("--fit-log")
    parser.add_argument("--map-rpt")
    parser.add_argument("--fit-rpt")
    parser.add_argument("--rbf")
    parser.add_argument("--map-t6")
    parser.add_argument("--fix", action="store_true",
                        help="rewrite drifted numbers in the document instead of only reporting")
    args = parser.parse_args(argv)

    outputs = os.path.join(args.dir, "output_files")
    sources = {
        "sta-log": args.sta_log or os.path.join(args.dir, "sta.log"),
        "fit-log": args.fit_log or os.path.join(args.dir, "fit.log"),
        "map-rpt": args.map_rpt or os.path.join(outputs, "NDS.map.rpt"),
        "fit-rpt": args.fit_rpt or os.path.join(outputs, "NDS.fit.rpt"),
        "rbf": args.rbf or os.path.join(outputs, "NDS.rbf"),
    }
    missing = [name for name, path in sources.items() if not os.path.exists(path)]
    if missing:
        sys.stderr.write("no evidence for: %s\n" % ", ".join(missing))
        sys.stderr.write("pass --sta-log/--fit-log/--map-rpt/--fit-rpt/--rbf\n")
        return 2
    if not os.path.exists(args.doc):
        sys.stderr.write("document not found: %s\n" % args.doc)
        return 2

    evidence = {
        "sta": parse_sta(sources["sta-log"]),
        "fit": parse_fit(sources["fit-log"]),
        "fitrpt": parse_fit_rpt(sources["fit-rpt"]),
        "map": parse_map(sources["map-rpt"]),
        "map_t6": parse_map(args.map_t6) if args.map_t6 else {},
        "rbf": {"rbf_bytes": os.path.getsize(sources["rbf"])},
    }

    text = open(args.doc, encoding="utf-8", newline="").read()
    drifted, checked = [], 0
    for label, pattern, groups, source in CLAIMS:
        if source == "map_t6" and not args.map_t6:
            print("SKIP %-16s needs --map-t6 (the report the docs cite for this figure)" % label)
            continue
        match = re.search(pattern, text)
        if not match:
            print("SKIP %-16s pattern not found in %s" % (label, args.doc))
            continue
        for index, key in groups.items():
            quoted = match.group(index)
            actual = resolve(key, evidence[source])
            if actual is None:
                print("SKIP %-16s report field %r absent" % (label, key))
                continue
            checked += 1
            if same_value(quoted, actual):
                print("PASS %-16s %s" % (label, quoted))
            else:
                print("DRIFT %-15s document says %s, report says %s" % (label, quoted, actual))
                drifted.append((label, pattern, index, actual, quoted))

    if args.fix and drifted:
        for label, pattern, index, actual, quoted in drifted:
            replacement = actual if isinstance(actual, str) else format_like(quoted, actual)
            match = re.search(pattern, text)
            begin, end = match.start(index), match.end(index)
            text = text[:begin] + replacement + text[end:]
            print("FIXED %-14s %s -> %s" % (label, quoted, replacement))
        with open(args.doc, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        print("\nwrote %s; rerun without --fix to confirm" % args.doc)

    print("\n%d claims checked, %d drifted" % (checked, len(drifted)))
    return 1 if drifted else 0


if __name__ == "__main__":
    sys.exit(main())
