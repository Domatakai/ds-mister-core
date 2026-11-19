#!/usr/bin/env python3
"""Self-test for area_audit.py.

Builds throwaway fit directories and documents, runs the audit over them, and
checks each verdict -- a row a build reproduces, one it contradicts, one that
only shares a LAB count, one nothing covers, and the ledger that keeps a row
verifiable after its report directory is gone:

  python fpga/tools/test_area_audit.py

One line per case; exits 1 if any of them fails. Nothing outside a temporary
directory is touched, and nothing here needs Quartus.
"""

import csv
import io
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "area_audit.py")
EOL = chr(13) + chr(10)

failures = []
count = 0


def check(name, good, detail=""):
    global count
    count += 1
    print("%-56s %s" % (name, "ok" if good else "FAIL"))
    if not good:
        failures.append((name, detail))


def new():
    root = tempfile.mkdtemp(prefix="ndsaudit")
    os.makedirs(os.path.join(root, "tools"))
    shutil.copy2(TOOL, os.path.join(root, "tools", "area_audit.py"))
    return root


def write(root, name, text):
    path = os.path.join(root, name)
    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)
    io.open(path, "wb").write(text.replace(chr(10), EOL).encode("utf-8"))
    return path


def clock(line_type, name, slack, tns):
    return ("Type  : %s '%s'\nSlack : %s\nTNS   : %s\n\n"
            % (line_type, name, slack, tns))


EMU = "emu|u_pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk"
HDMI = ("pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|"
        "counter[0].output_counter|divclk")


def fit(dirpath, labs="4,125", alms="37,668", regs="33,043", setup="-8.907",
        tns="-44808.642", hold="0.250", other_hold="0.160", hdmi="-0.064",
        rbf=3695232, seed="2", tds="OFF", effort="8.0"):
    """A build directory with the four files the audit reads."""
    out = os.path.join(dirpath, "output_files")
    os.makedirs(out)
    io.open(os.path.join(out, "NDS.fit.rpt"), "wb").write(
        ("Fitter was successful. 0 errors, 18 warnings\n"
         "    ; Total LABs:  partially or completely used  ; %s / 4,191 ; 98 %% ;\n"
         "    ; Logic utilization (in ALMs)     ; %s / 41,910 ( 90 %% ) ;\n"
         "    ; Total registers                 ; %s ;\n"
         % (labs, alms, regs)).replace(chr(10), EOL).encode("utf-8"))
    io.open(os.path.join(out, "NDS.sta.summary"), "wb").write(
        (clock("Setup", EMU, setup, tns) + clock("Setup", HDMI, hdmi, "0.000")
         + clock("Hold", EMU, hold, "0.000")
         + clock("Hold", HDMI, other_hold, "0.000")).replace(
             chr(10), EOL).encode("utf-8"))
    io.open(os.path.join(out, "NDS.rbf"), "wb").write(b"r" * rbf)
    io.open(os.path.join(dirpath, "NDS.qsf"), "wb").write(
        ("set_global_assignment -name SEED %s\n"
         "set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS %s\n"
         "set_global_assignment -name PLACEMENT_EFFORT_MULTIPLIER %s\n"
         % (seed, tds, effort)).replace(chr(10), EOL).encode("utf-8"))
    return dirpath


ROWH = ["LABs", "ALMs", "regs", "`emu` setup", "`emu` TNS", "hold",
        "`pll_hdmi`", "rbf"]
ROW = "4,125", "37,668", "33,043", "-8.907", "-44,808.642", "+0.250", \
      "-0.064", "3,695,232"


def document(*rows, header=None):
    head = header or ROWH
    body = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for row in rows:
        body.append("| " + " | ".join(row) + " |")
    return chr(10).join(body) + chr(10)


def run(root, *args):
    done = subprocess.run([sys.executable, os.path.join(root, "tools",
                                                        "area_audit.py")]
                          + list(args),
                          cwd=root, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def audit(root, doc="AREA.md", builds="fits", ledger="reports/fits.csv"):
    return run(root, "--doc", doc, "--builds", builds, "--ledger", ledger)


def write_qsf(root, name, seed="2", tds="OFF", effort="8.0"):
    return write(root, name,
                 "set_global_assignment -name SEED %s\n"
                 "set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS %s\n"
                 "set_global_assignment -name PLACEMENT_EFFORT_MULTIPLIER %s\n"
                 % (seed, tds, effort))


def shipped(root, folder="fits/shipped", doc="AREA.md"):
    return run(root, "--check-shipped", "--doc", doc, "--ledger",
               "reports/fits.csv", "--folder", folder)


def ledger_of(root, path="reports/fits.csv"):
    with io.open(os.path.join(root, path), encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def strip_trees(root, path="reports/fits.csv"):
    """A ledger as it was written before rows carried a tree."""
    rows = ledger_of(root, path)
    with io.open(os.path.join(root, path), "w", newline="") as handle:
        writer = csv.DictWriter(handle, list(rows[0].keys()))
        writer.writeheader()
        for row in rows:
            row["tree"] = ""
            writer.writerow(row)


SHIPPED_ROW = ("both bank writes captured",) + ROW
SHIPPED_HEAD = ["fit"] + ROWH


def main():
    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    write(root, "AREA.md", document(ROW))
    rc, out = audit(root)
    check("a reproduced row matches", rc == 0 and "matched: 1" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    drifted = list(ROW)
    drifted[4] = "-40,000.000"
    write(root, "AREA.md", document(tuple(drifted)))
    rc, out = audit(root)
    check("a same-build drift is contradicted and fails",
          rc == 1 and "contradicted: 1" in out and "tns" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    other = list(ROW)
    other[2] = "32,551"
    write(root, "AREA.md", document(tuple(other)))
    rc, out = audit(root)
    check("a shared LAB count with different registers only closes",
          rc == 0 and "contradicted: 0" in out and "close" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    missing = list(ROW)
    missing[0] = "4,096"
    write(root, "AREA.md", document(tuple(missing)))
    rc, out = audit(root)
    check("a row with no build is reported, not failed",
          rc == 0 and "no report: 1" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    write(root, "AREA.md",
          document(("4,125", "-8.907", "-44,808.642", "3,695,232"),
                   header=["LABs", "`emu` setup", "`emu` TNS", "rbf"]))
    rc, out = audit(root)
    check("`emu` TNS is not read as the setup column",
          rc == 0 and "matched: 1" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    write(root, "AREA.md",
          document(("4,125", "+0.160", "+0.250"),
                   header=["LABs", "worst hold", "hold"]))
    rc, out = audit(root)
    check("`worst hold` is the worst clock, `hold` is the emu domain",
          rc == 0 and "matched: 1" in out, out)

    root = new()
    build = fit(os.path.join(root, "fits", "nds-tds-s2b"), seed="2", tds="ON")
    rc, out = run(root, "--record", build, "--ledger", "reports/fits.csv")
    check("--record writes one line for the fit",
          rc == 0 and "recorded nds-tds-s2b" in out, out)
    ok_rows = io.open(os.path.join(root, "reports", "fits.csv"),
                      encoding="utf-8").read().strip().splitlines()
    check("the ledger line carries settings and counts",
          len(ok_rows) == 2 and "4125" in ok_rows[1] and ",on," in ok_rows[1]
          and ok_rows[1].startswith("nds-tds-s2b,"), chr(10).join(ok_rows))

    write(root, "AREA.md", document(ROW))
    empty = os.path.join(root, "empty")
    os.makedirs(empty)
    rc, out = audit(root, builds="empty")
    check("a row stays verifiable from the ledger alone",
          rc == 0 and "matched: 1" in out and "1 archived" in out, out)

    rc, out = run(root, "--record", build, "--ledger", "reports/fits.csv")
    rows_again = io.open(os.path.join(root, "reports", "fits.csv"),
                         encoding="utf-8").read().strip().splitlines()
    check("recording the same build replaces its line",
          rc == 0 and len(rows_again) == 2, chr(10).join(rows_again))

    root = new()
    one = fit(os.path.join(root, "fits", "one"))
    twin = fit(os.path.join(root, "fits", "twin"))
    write(root, "fits/one/rtl/core.sv", "module core; endmodule\n")
    write(root, "fits/twin/rtl/core.sv", "module core; endmodule\n")
    run(root, "--record", one, "--ledger", "reports/fits.csv")
    rc, out = run(root, "--record", twin, "--ledger", "reports/fits.csv")
    check("one fit captured under a second label is refused",
          rc == 2 and "already holds these figures" in out
          and "one capture, not two" in out, out)
    check("the refused capture leaves one line",
          len(ledger_of(root)) == 1, ledger_of(root))

    rc, out = run(root, "--record", twin, "--allow-duplicate",
                  "--ledger", "reports/fits.csv")
    check("--allow-duplicate records it anyway",
          rc == 0 and len(ledger_of(root)) == 2, out)

    root = new()
    one = fit(os.path.join(root, "fits", "one"))
    other = fit(os.path.join(root, "fits", "other"), labs="4,096",
                regs="32,551", setup="-8.329")
    write(root, "fits/one/rtl/core.sv", "module core; endmodule\n")
    write(root, "fits/other/rtl/core.sv", "module core; endmodule\n")
    run(root, "--record", one, "--ledger", "reports/fits.csv")
    rc, out = run(root, "--record", other, "--ledger", "reports/fits.csv")
    check("a fit with its own figures still records",
          rc == 0 and len(ledger_of(root)) == 2, out)

    root = new()
    fit(os.path.join(root, "fits", "nds-tree-s2"))
    rc, out = run(root, "--record", os.path.join(root, "fits", "nothing"),
                  "--ledger", "reports/fits.csv")
    check("recording a directory with no fit is an error",
          rc == 2 and "no finished fit" in out, out)

    root = new()
    rc, out = audit(root, doc="missing.md")
    check("a missing document is an error",
          rc == 2 and "document not found" in out, out)

    root = new()
    write(root, "AREA.md", document(ROW))
    rc, out = run(root, "--doc", "AREA.md", "--builds", "nope",
                  "--ledger", "nope.csv")
    check("no evidence at all is an error",
          rc == 2 and "neither a build directory" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "a"))
    fit(os.path.join(root, "fits", "b"), labs="4,096", setup="-8.329")
    write(root, "AREA.md", document(ROW, ROW))
    rc, out = audit(root)
    check("the summary counts every row",
          rc == 0 and "rows checked: 2" in out and "matched: 2" in out, out)

    root = new()
    build = fit(os.path.join(root, "fits", "shipped"))
    write(root, "AREA.md", document(SHIPPED_ROW, header=SHIPPED_HEAD))
    run(root, "--record", build, "--ledger", "reports/fits.csv")
    rc, out = shipped(root)
    check("the shipped row matches the recorded build",
          rc == 0 and "matches shipped" in out, out)

    drifted = list(SHIPPED_ROW)
    drifted[5] = "-40,000.000"
    write(root, "AREA.md", document(tuple(drifted), header=SHIPPED_HEAD))
    rc, out = shipped(root)
    check("a shipped row that drifted fails the check",
          rc == 1 and "disagrees" in out, out)

    root = new()
    build = fit(os.path.join(root, "fits", "seed6"), seed="6")
    write_qsf(root, "qsf/NDS.qsf")
    write(root, "AREA.md", document(SHIPPED_ROW, header=SHIPPED_HEAD))
    run(root, "--record", build, "--ledger", "reports/fits.csv")
    rc, out = shipped(root, folder="qsf")
    check("a shipped setting with no recorded fit fails",
          rc == 1 and "no archived fit" in out, out)

    root = new()
    fit(os.path.join(root, "fits", "shipped"))
    write(root, "AREA.md", document(ROW, header=SHIPPED_HEAD))
    rc, out = shipped(root)
    check("a document without the shipped row fails",
          rc == 1 and "no 'both bank writes captured' row" in out, out)

    root = new()
    one = fit(os.path.join(root, "fits", "one"))
    two = fit(os.path.join(root, "fits", "two"), labs="4,096")
    write(root, "/".join(["fits", "one", "rtl", "core.sv"]), "module core; endmodule\n")
    write(root, "/".join(["fits", "two", "rtl", "core.sv"]), "module core; endmodule\n")
    run(root, "--record", one, "--ledger", "reports/fits.csv")
    run(root, "--record", two, "--ledger", "reports/fits.csv")
    rows = ledger_of(root)
    check("a row records a twelve-digit tree id",
          len(rows) == 2 and all(len(row["tree"]) == 12 for row in rows), rows)
    check("two builds of one design share a tree id",
          rows[0]["tree"] == rows[1]["tree"], rows)

    write(root, "/".join(["fits", "two", "rtl", "core.sv"]), "module core (input a); endmodule\n")
    run(root, "--record", two, "--ledger", "reports/fits.csv")
    rows = ledger_of(root)
    check("a one-word edit is a different tree",
          rows[0]["tree"] != rows[1]["tree"], rows)

    root = new()
    build = fit(os.path.join(root, "fits", "shipped"))
    write(root, "/".join(["fits", "shipped", "rtl", "core.sv"]), "module core; endmodule\n")
    write_qsf(root, "qsf/NDS.qsf")
    write(root, "/".join(["qsf", "rtl", "core.sv"]), "module core; endmodule\n")
    write(root, "AREA.md", document(SHIPPED_ROW, header=SHIPPED_HEAD))
    run(root, "--record", build, "--ledger", "reports/fits.csv")
    rc, out = shipped(root, folder="qsf")
    check("a fit of the same tree opens the gate",
          rc == 0 and "on tree" in out, out)

    write(root, "/".join(["qsf", "rtl", "core.sv"]), "module core (input a); endmodule\n")
    rc, out = shipped(root, folder="qsf")
    check("a fit of another tree does not stand in",
          rc == 1 and "from tree" in out, out)

    strip_trees(root)
    rc, out = shipped(root, folder="qsf")
    check("an unbound fit is not evidence for a tree",
          rc == 1 and "unbound" in out, out)

    rc, out = run(root, "--bind-tree", "fits", "--ledger", "reports/fits.csv")
    check("--bind-tree reads the directory a row names",
          rc == 0 and "bound 1 row(s)" in out, out)

    rc, out = shipped(root, folder="fits/shipped")
    check("the bound row then stands for its tree",
          rc == 0 and "matches shipped" in out, out)

    strip_trees(root)
    rc, out = run(root, "--bind-tree", "nowhere", "--ledger", "reports/fits.csv")
    check("a row whose build is gone stays unbound",
          rc == 0 and "1 left unbound" in out, out)

    root = new()
    one = fit(os.path.join(root, "fits", "one"))
    two = fit(os.path.join(root, "fits", "two"), labs="4,096", seed="6")
    write(root, "fits/one/rtl/core.sv", "module core; endmodule\n")
    write(root, "fits/two/rtl/core.sv", "module core; endmodule\n")
    write(root, "fits/one/NDS.qsf",
          "# a note about the pins\n"
          "set_global_assignment -name SEED 2\n"
          "set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF\n"
          "set_global_assignment -name PLACEMENT_EFFORT_MULTIPLIER 8.0\n")
    run(root, "--record", one, "--ledger", "reports/fits.csv")
    run(root, "--record", two, "--ledger", "reports/fits.csv")
    rows = ledger_of(root)
    check("a seed choice and a .qsf comment are not a new tree",
          rows[0]["tree"] == rows[1]["tree"], rows)

    if failures:
        print("%d of %d cases failed" % (len(failures), count))
        print("test_area_audit: FAIL")
        for name, detail in failures:
            print("FAILED: %s" % name)
            if detail:
                print(detail)
        return 1
    print("%d cases passed" % count)
    print("test_area_audit: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
