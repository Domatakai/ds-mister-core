#!/usr/bin/env python3
"""Match every table row in AREA.md to a build directory that still exists.

The figures in AREA.md come from Quartus runs whose report directories live
outside the repository, and a later fit reuses a directory. That is how a
number can end up in the document with nothing left to check it against:
the row is not wrong, it is unverifiable, and the two look identical to a
reader.

This tool separates them. It reads each build directory under --builds,
takes the fitted LAB/ALM/register counts, the `emu` setup slack, TNS and
hold, the `pll_hdmi` slack and the bitstream size, then walks the document's
tables and says, row by row:

  ok        a build agrees on every column the row carries
  DIFF      a build matches the row's LABs and ALMs and disagrees elsewhere
  no report no build on disk has that LAB count, so the row cannot be checked

Exit code 1 means at least one row claims something a report contradicts.
Rows with no report are listed but do not fail the run: several predate the
pinned build stamp and could not rebuild to their recorded figures anyway
(AREA.md says which ones).

Run it against a copy of the fit directories, e.g.:

  python tools/area_audit.py --builds %TEMP% --doc AREA.md

It needs no Quartus and no board.
"""

import argparse
import os
import re
import sys

TOLERANCE = {"setup": 0.0006, "tns": 0.0006, "hold": 0.0006, "hdmi": 0.0006}


def number(text):
    """The value of a table cell, or None when it is not a plain number."""
    token = text.strip().replace(",", "").replace("`", "").split()[0] if text.strip() else ""
    match = re.match(r"^[+-]?\d+(?:\.\d+)?$", token)
    return float(token) if match else None


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
        if not os.path.isdir(path):
            continue
        metrics = build_metrics(path)
        if metrics:
            found[name] = metrics
    return found


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


def agrees(metrics, values):
    """Fields where a build and a row disagree."""
    bad = []
    for key, value in values.items():
        actual = metrics.get(key)
        if actual is None:
            continue
        if abs(actual - value) > TOLERANCE.get(key, 0.5):
            bad.append((key, value, actual))
    return bad


def audit(document, root, verbose):
    found = builds(root)
    print("%d completed build(s) under %s" % (len(found), root))
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
        scored = sorted((len(agrees(m, values)), name, agrees(m, values))
                        for name, m in candidates)
        bad, name, detail = scored[0]
        if not bad:
            matched += 1
            if verbose:
                print("ok        line %-5d %-46s <- %s"
                      % (lineno, " | ".join(cells)[:46], name))
            continue
        # A row can only be contradicted by a build that is demonstrably the
        # same one, and a LAB count alone does not establish that: several
        # fits share a count by accident. Two identifying columns, all equal,
        # do -- the rest are then a real disagreement.
        identity = [k for k in ("labs", "alms", "regs") if k in values
                    and found[name].get(k) is not None]
        if len(identity) >= 2 and not {k for k, _a, _b in detail} & set(identity):
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
        print("          closest build %s disagrees on %s" % (name, bad))
    return 1 if diffs else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--doc", default="AREA.md")
    parser.add_argument("--builds", default=os.environ.get("TEMP", "."),
                        help="directory holding the staged fit directories")
    parser.add_argument("--verbose", action="store_true",
                        help="print every matching row, not just the summary")
    args = parser.parse_args(argv)
    if not os.path.isfile(args.doc):
        sys.stderr.write("document not found: %s\n" % args.doc)
        return 2
    if not os.path.isdir(args.builds):
        sys.stderr.write("no build directory: %s\n" % args.builds)
        return 2
    return audit(args.doc, args.builds, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
