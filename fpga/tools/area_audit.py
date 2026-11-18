#!/usr/bin/env python3
"""Match every table row in AREA.md to a build that still has evidence.

The figures in AREA.md come from Quartus runs whose report directories live
outside the repository, and a later fit reuses a directory. That is how a
number can end up in the document with nothing left to check it against:
the row is not wrong, it is unverifiable, and the two look identical to a
reader.

This tool separates them. It takes the fitted LAB/ALM/register counts, the
`emu` setup slack, TNS and hold, the worst hold, the `pll_hdmi` slack and
the bitstream size from every build directory under --builds and from the
ledger of archived runs, then walks the document's tables and says, row by
row:

  ok         a build agrees on every column the row carries
  DIFF       a build that is demonstrably the same one disagrees
  close      a build shares the LAB count but is a different build
  no report  nothing on disk or in the ledger carries that LAB count

Exit code 1 means at least one row claims something a build contradicts.
The other two categories are listed but pass: several rows predate the
pinned build stamp and could not rebuild to their recorded figures anyway.

The ledger is how a row stops being unverifiable. `--record` appends one
line per finished fit -- counts, slacks, bitstream size and the settings
that produced them -- so the evidence survives the report directory:

  python tools/area_audit.py --record %TEMP%\\nds-tds-s2b
  python tools/area_audit.py --builds %TEMP%

`build.bat` calls --record after a successful flow, so a build banked
through it is in the ledger without anyone remembering.
"""

import argparse
import csv
import os
import re
import sys

TOLERANCE = {"setup": 0.0006, "tns": 0.0006, "hold": 0.0006,
             "glhold": 0.0006, "hdmi": 0.0006}

COUNTS = ("labs", "alms", "regs", "rbf")
SLACKS = ("setup", "tns", "hold", "glhold", "hdmi")
LEDGER_HEADER = ["label", "seed", "tds", "effort"] + list(COUNTS) + list(SLACKS)


def number(text):
    """The value of a table cell or ledger field, or None if not a number."""
    token = text.strip().replace(",", "").replace("`", "").split()[0] if text.strip() else ""
    return float(token) if re.match(r"^[+-]?\d+(?:\.\d+)?$", token) else None


def read(path):
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8", "replace")


def sta_summary(path):
    """Setup/Hold slacks per clock, keyed by (section, clock name)."""
    found = {}
    current = None
    for line in read(path).splitlines():
        if line.startswith("Type  :"):
            match = re.match(r"Type  : (Setup|Hold) '([^']+)'", line)
            current = (match.group(1), match.group(2)) if match else None
        elif current and line.startswith("Slack :"):
            found.setdefault(current, {})["slack"] = number(line.split(":", 1)[1])
        elif current and line.startswith("TNS"):
            found.setdefault(current, {})["tns"] = number(line.split(":", 1)[1])
    return found


def slack(sta, section, needle, field="slack"):
    for (sec, clock), values in sta.items():
        if sec == section and needle in clock:
            return values.get(field)
    return None


def build_metrics(directory):
    """What one finished build's reports say, or None if it did not finish."""
    out = os.path.join(directory, "output_files")
    fit = os.path.join(out, "NDS.fit.rpt")
    summary = os.path.join(out, "NDS.sta.summary")
    if not (os.path.isfile(fit) and os.path.isfile(summary)):
        return None
    text = read(fit)
    labs = re.search(r"Total LABs:[^;]*;\s*([\d,]+)\s*/", text)
    alms = re.search(r"Logic utilization \(in ALMs\)\s*;\s*([\d,]+)\s*/", text)
    regs = re.search(r"; Total registers\s*;\s*([\d,]+)", text)
    if not labs:
        return None
    sta = sta_summary(summary)
    holds = [v["slack"] for (sec, _clock), v in sta.items()
             if sec == "Hold" and v.get("slack") is not None]
    rbf = os.path.join(out, "NDS.rbf")
    return {
        "labs": number(labs.group(1)),
        "alms": number(alms.group(1)) if alms else None,
        "regs": number(regs.group(1)) if regs else None,
        "setup": slack(sta, "Setup", "emu|u_pll"),
        "tns": slack(sta, "Setup", "emu|u_pll", "tns"),
        "hold": slack(sta, "Hold", "emu|u_pll"),
        "glhold": min(holds) if holds else None,
        "hdmi": slack(sta, "Setup", "pll_hdmi"),
        "rbf": os.path.getsize(rbf) if os.path.isfile(rbf) else None,
    }


def builds(root):
    found = {}
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(path):
            metrics = build_metrics(path)
            if metrics:
                found[name] = metrics
    return found


def ledger_rows(path):
    """The archived runs, one dictionary per line, header keys only."""
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("label"):
                rows.append({key: row.get(key, "") for key in LEDGER_HEADER})
    return rows


def ledger_metrics(path):
    """Archived runs as the same metric dictionaries the reports produce."""
    found = {}
    for row in ledger_rows(path):
        found[row["label"]] = {key: (number(row[key]) if row[key] else None)
                               for key in COUNTS + SLACKS}
    return found


def qsf_value(qsf, name):
    """The value a build's own .qsf gave an assignment, or an empty string."""
    if not os.path.isfile(qsf):
        return ""
    for line in read(qsf).splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "set_global_assignment" and parts[2] == name:
            return parts[3]
    return ""


def record(directory, ledger, label):
    """Append one finished fit to the ledger, replacing any earlier line."""
    metrics = build_metrics(directory)
    if metrics is None:
        sys.stderr.write("no finished fit in %s: needs output_files/NDS.fit.rpt\n"
                         "and output_files/NDS.sta.summary\n" % directory)
        return 2
    qsf = os.path.join(directory, "NDS.qsf")
    entry = {"label": label or os.path.basename(os.path.abspath(directory)),
             "seed": qsf_value(qsf, "SEED"),
             "tds": "on" if qsf_value(qsf, "SYNTH_TIMING_DRIVEN_SYNTHESIS").lower() == "on" else "off",
             "effort": qsf_value(qsf, "PLACEMENT_EFFORT_MULTIPLIER")}
    for key in COUNTS:
        value = metrics.get(key)
        entry[key] = "" if value is None else str(int(value))
    for key in SLACKS:
        value = metrics.get(key)
        entry[key] = "" if value is None else "%.3f" % value

    rows = [row for row in ledger_rows(ledger) if row["label"] != entry["label"]]
    rows.append(entry)
    rows.sort(key=lambda row: row["label"])
    folder = os.path.dirname(os.path.abspath(ledger))
    if not os.path.isdir(folder):
        os.makedirs(folder)
    with open(ledger, "w", newline="") as handle:
        writer = csv.DictWriter(handle, LEDGER_HEADER)
        writer.writeheader()
        writer.writerows(rows)
    print("recorded %s: %s LABs, %s setup, %s pll_hdmi, %s bytes (seed %s, tds %s, effort %s)"
          % (entry["label"], entry["labs"], entry["setup"], entry["hdmi"],
             entry["rbf"], entry["seed"] or "?", entry["tds"], entry["effort"] or "?"))
    return 0


def rows(document):
    """Yield (line number, header cells, row cells) for every table row."""
    header = None
    for lineno, line in enumerate(read(document).splitlines(), 1):
        text = line.strip()
        if not text.startswith("|"):
            header = None
            continue
        cells = [cell.strip() for cell in text.strip("|").split("|")]
        if cells and all(re.match(r"^:?-{2,}:?$", cell) for cell in cells if cell):
            continue
        if header is None:
            header = cells
            continue
        yield lineno, header, cells


def claimed(header, cells):
    """The numeric columns a row carries, keyed the way the reports are.

    Order matters: one header can carry two of these words, and `emu` TNS is
    the emu domain's TNS, not its setup slack -- the same collision that put
    a stale figure in the document once already.
    """
    values = {}
    for index, cell in enumerate(header):
        if index >= len(cells):
            break
        value = number(cells[index])
        if value is None:
            continue
        low = cell.lower()
        if "tns" in low:
            key = "tns"
        elif "worst" in low and "hold" in low:
            key = "glhold"
        elif "labs" in low:
            key = "labs"
        elif "alm" in low:
            key = "alms"
        elif "register" in low or "regs" in low:
            key = "regs"
        elif "pll_hdmi" in low or "hdmi" in low:
            key = "hdmi"
        elif "rbf" in low:
            key = "rbf"
        elif "emu" in low or "setup" in low:
            key = "setup"
        elif "hold" in low:
            key = "hold"
        else:
            continue
        values[key] = value
    return values


def disagrees(metrics, values):
    """Columns where a build and a row disagree."""
    bad = []
    for key, value in values.items():
        actual = metrics.get(key)
        if actual is not None and abs(actual - value) > TOLERANCE.get(key, 0.5):
            bad.append((key, value, actual))
    return bad


def audit(document, root, ledger, verbose):
    live = builds(root) if os.path.isdir(root) else {}
    archived = ledger_metrics(ledger)
    found = dict(archived)
    found.update(live)  # a live report outranks the line it was recorded on
    print("%d completed build(s) under %s, %d archived row(s) in %s"
          % (len(live), root, len(archived), ledger))
    checked = matched = 0
    diffs, close, missing = [], [], []
    for lineno, header, cells in rows(document):
        values = claimed(header, cells)
        if "labs" not in values:
            continue
        checked += 1
        candidates = [(name, m) for name, m in found.items()
                      if m["labs"] == values["labs"] and
                      (values.get("alms") is None or m["alms"] == values["alms"])]
        if not candidates:
            missing.append((lineno, cells))
            continue
        scored = sorted((len(disagrees(m, values)), name, disagrees(m, values))
                        for name, m in candidates)
        count, name, detail = scored[0]
        if not count:
            matched += 1
            if verbose:
                print("ok        line %-5d %-46s <- %s"
                      % (lineno, " | ".join(cells)[:46], name))
            continue
        # A row can only be contradicted by a build that is demonstrably the
        # same one, and a LAB count alone does not establish that: several
        # fits share a count by accident. Two identifying columns, all equal,
        # do -- the rest are then a real disagreement.
        identity = [key for key in ("labs", "alms", "regs")
                    if key in values and found[name].get(key) is not None]
        if len(identity) >= 2 and not {key for key, _a, _b in detail} & set(identity):
            diffs.append((lineno, cells, name, detail))
        else:
            close.append((lineno, cells, name, detail))
    print("\nrows checked: %d  matched: %d  contradicted: %d  no report: %d"
          % (checked, matched, len(diffs), len(missing)))
    for lineno, cells, name, bad in close:
        print("close     line %d: %s" % (lineno, " | ".join(cells)))
        print("          build %s shares the count, disagrees on %s" % (name, bad))
    for lineno, cells in missing:
        print("no report line %d: %s" % (lineno, " | ".join(cells)))
    for lineno, cells, name, bad in diffs:
        print("DIFF      line %d: %s" % (lineno, " | ".join(cells)))
        print("          build %s disagrees on %s" % (name, bad))
    return 1 if diffs else 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--doc", default="AREA.md")
    parser.add_argument("--builds", default=os.environ.get("TEMP", "."),
                        help="directory holding the staged fit directories")
    parser.add_argument("--ledger", default="reports/fits.csv",
                        help="archived runs, written by --record")
    parser.add_argument("--record", metavar="BUILD_DIR",
                        help="append this build's figures to the ledger")
    parser.add_argument("--label", help="ledger name (default: directory name)")
    parser.add_argument("--verbose", action="store_true",
                        help="print every matching row, not just the summary")
    args = parser.parse_args(argv)
    if args.record:
        return record(args.record, args.ledger, args.label)
    if not os.path.isfile(args.doc):
        sys.stderr.write("document not found: %s\n" % args.doc)
        return 2
    if not os.path.isdir(args.builds) and not os.path.isfile(args.ledger):
        sys.stderr.write("neither a build directory (%s) nor a ledger (%s)\n"
                         % (args.builds, args.ledger))
        return 2
    return audit(args.doc, args.builds, args.ledger, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
