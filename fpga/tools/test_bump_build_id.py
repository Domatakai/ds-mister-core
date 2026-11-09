#!/usr/bin/env python3
"""Self-test for bump_build_id.py.

Exercises the bump, record and verify paths against throwaway copies of
the project layout, so they can be re-checked after any change:

  python fpga/tools/test_bump_build_id.py

One line per case; exits 1 if any of them fails. The repository is not
touched - each case works in a temporary directory that is removed again
at the end. The build.bat cases run the real success path from
that file with the prompt answered for it, so they only run on
Windows.
"""

import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "bump_build_id.py")
BUILD_BAT = os.path.join(HERE, os.pardir, "build.bat")
RBF = bytes(range(256))

failures = []
count = 0


def check(name, good, detail=""):
    global count
    count += 1
    print("%-48s %s" % (name, "ok" if good else "FAIL"))
    if not good:
        failures.append((name, detail))


def write(path, data):
    io.open(path, "wb").write(data)


def set_pin(root, stamp):
    write(os.path.join(root, "sys", "build_id.txt"),
          ("# pinned for the release\r\n"
           "# moved by tools/bump_build_id.py\r\n%s\r\n" % stamp)
          .encode("utf-8"))


def tree(stamp="261108", build_date="261108"):
    root = tempfile.mkdtemp(prefix="ndsstamp")
    for name in ("tools", "sys", "output_files"):
        os.makedirs(os.path.join(root, name))
    shutil.copy2(TOOL, os.path.join(root, "tools", "bump_build_id.py"))
    set_pin(root, stamp)
    write(os.path.join(root, "build_id.v"),
          ('`define BUILD_DATE "%s"\n' % build_date).encode("utf-8"))
    write(os.path.join(root, "output_files", "NDS.rbf"), RBF)
    os.utime(os.path.join(root, "build_id.v"), (1000, 1000))
    os.utime(os.path.join(root, "output_files", "NDS.rbf"), (2000, 2000))
    return root


def run(root, *args):
    done = subprocess.run(
        [sys.executable, os.path.join(root, "tools", "bump_build_id.py")]
        + list(args),
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def pin(root):
    text = io.open(os.path.join(root, "sys", "build_id.txt"), "rb").read()
    lines = text.decode("utf-8").split("\r\n")
    return [l.strip() for l in lines if l.strip() and not l.startswith("#")]


def sidecar(root):
    return os.path.join(root, "output_files", "NDS.rbf.stamp")


def age_record(root, days):
    text = io.open(sidecar(root), "rb").read().decode("utf-8")
    when = time.strftime("%Y-%m-%d %H:%M:%S",
                         time.localtime(time.time() - days * 86400))
    out = []
    for line in text.split(chr(13) + chr(10)):
        if line.startswith("recorded:"):
            line = "recorded: " + when
        out.append(line)
    write(sidecar(root), (chr(13) + chr(10)).join(out).encode("utf-8"))


def fields(root):
    found = {}
    if os.path.exists(sidecar(root)):
        text = io.open(sidecar(root), "rb").read().decode("utf-8")
        for line in text.split("\r\n"):
            if ":" in line:
                key, value = line.split(":", 1)
                found[key.strip()] = value.strip()
    return found


def move_pin(root, stamp):
    set_pin(root, stamp)
    write(os.path.join(root, "build_id.v"),
          ('`define BUILD_DATE "%s"' % stamp).encode("utf-8"))
    os.utime(os.path.join(root, "build_id.v"), (1000, 1000))


def tail_lines():
    text = io.open(BUILD_BAT, "rb").read().decode("utf-8", "replace")
    lines = text.splitlines()
    start = [n for n, l in enumerate(lines)
             if l.startswith("echo SUCCESS: output_files")]
    assert len(start) == 1, "build.bat: no single success line"
    tail = lines[start[0]:]
    assert len([l for l in tail if l.startswith("choice ")]) == 1, tail
    return tail


def script_lines():
    text = io.open(BUILD_BAT, "rb").read().decode("utf-8", "replace")
    return text.splitlines()


def fake_quartus(root):
    path = os.path.join(root, "bin")
    if not os.path.isdir(path):
        os.makedirs(path)
    write(os.path.join(path, "quartus_sh.exe"), b"")
    return path


def batch_full(root, quartus_rc, argv=None,
               selftest_rc=0, selftest_python=None):
    """Run build.bat from its first line, with Quartus stubbed out."""
    body = []
    for line in script_lines():
        if line.startswith('"%QUARTUS_BIN%'):
            line = "cmd /c exit %d" % quartus_rc
        elif "test_bump_build_id" in line:
            if selftest_python:
                line = selftest_python + line[6:]
            else:
                line = "cmd /c exit %d" % selftest_rc
        elif line.startswith('python "tools'):
            line = '"%s"' % sys.executable + line[6:]
        body.append(line)
    path = os.path.join(root, "build_all.bat")
    write(path, os.linesep.join(body + [""]).encode("utf-8"))
    if argv is None:
        argv = [fake_quartus(root)]
    done = subprocess.run(["cmd", "/c", path] + argv,
                          cwd=root, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def batch(root, answer, python=None):
    """Run build.bat's success path with the prompt answered."""
    body = []
    for line in tail_lines():
        if line.startswith("choice "):
            line = "cmd /c exit %d" % answer
        elif line.startswith('python "tools'):
            line = (python or '"%s"' % sys.executable) + line[6:]
        body.append(line)
    script = ["@echo off", 'cd /d "%s"' % root,
              'set "BUILD_STAMP=261108"',
              # build.bat --record sets these in the environment; a case that
              # answered N must not inherit them and record anyway.
              'set "SKIP_TEST="', 'set "RECORD_FLAG="',
              'set "VERIFY_FLAG="', 'set "STRICT_FLAG="',
              'set "MAX_AGE="'] + body + [""]
    path = os.path.join(root, "build_tail.bat")
    write(path, os.linesep.join(script).encode("utf-8"))
    done = subprocess.run(["cmd", "/c", path], cwd=root,
                          stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    return done.returncode, done.stdout.decode("utf-8", "replace")


def batch_cases(new):
    if os.name != "nt":
        print("%-48s %s" % ("build.bat cases", "skipped (not Windows)"))
        return

    root = new()
    run(root, "--record")
    rc, out = batch(root, 2)
    check("build.bat decline keeps a good record",
          rc == 0 and "matches NDS.rbf" in out and "Deploy to the" in out,
          out)

    root = new()
    run(root, "--record")
    move_pin(root, "261109")
    rc, out = batch(root, 2)
    check("build.bat fails on a stale record",
          rc == 1 and "ERROR: the recorded stamp" in out
          and "Deploy to the" not in out, out)

    root = new()
    rc, out = batch(root, 2)
    check("build.bat notes a missing record",
          rc == 0 and "No record for this bitstream" in out
          and "Deploy to the" in out, out)

    root = new()
    rc, out = batch(root, 1)
    check("build.bat records when answered yes",
          rc == 0 and "recorded NDS.rbf" in out
          and "matches NDS.rbf" in out, out)

    root = new()
    run(root, "--record")
    move_pin(root, "261109")
    rc, out = batch(root, 1)
    check("build.bat re-records a moved pin",
          rc == 0 and "recorded NDS.rbf" in out
          and "stamp 261109" in out, out)

    root = new()
    run(root, "--record")
    move_pin(root, "261109")
    rc, out = batch(root, 2, python="nosuchpython")
    check("build.bat skips the check without python",
          rc == 0 and "Deploy to the" in out, out)

    root = new()
    rc, out = batch_full(root, 1)
    check("build.bat fails when the compile fails",
          rc == 1 and "COMPILE FAILED" in out and "SUCCESS" not in out,
          out)

    root = new()
    os.remove(os.path.join(root, "output_files", "NDS.rbf"))
    rc, out = batch_full(root, 0)
    check("build.bat fails when no rbf appears",
          rc == 1 and "was not generated" in out
          and "SUCCESS" not in out, out)

    root = new()
    rc, out = batch_full(root, 0)
    check("build.bat completes a full flow",
          rc == 0 and "SUCCESS" in out
          and "Build stamp: 261108" in out
          and "Deploy to the" in out, out)

    root = new()
    missing = os.path.join(root, "no-quartus-here")
    rc, out = batch_full(root, 0, argv=[missing])
    check("build.bat fails without quartus_sh.exe",
          rc == 1 and "quartus_sh.exe not found" in out
          and "Using:" not in out, out)

    root = new()
    rc, out = batch_full(root, 0, selftest_rc=1)
    check("build.bat fails when the self-test fails",
          rc == 1 and "self-test failed" in out
          and "Compiling NDS" not in out, out)

    root = new()
    rc, out = batch_full(root, 0, selftest_python="nosuchpython")
    check("build.bat skips the self-test without python",
          rc == 0 and "skipping the tool self-test" in out
          and "SUCCESS" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--no-test"])
    check("build.bat skips the test after --no-test",
          rc == 0 and "Skipping the tool self-test" in out
          and "Checking the build-stamp tool" not in out
          and "SUCCESS" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=["--no-test", binp])
    check("build.bat takes --no-test before the path",
          rc == 0 and "Skipping the tool self-test" in out
          and "Checking the build-stamp tool" not in out
          and "SUCCESS" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--record"])
    check("build.bat records on --record without a prompt",
          rc == 0 and "recorded NDS.rbf" in out
          and os.path.exists(sidecar(root)) and "SUCCESS" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=["--record", "--verify", binp])
    check("build.bat records and verifies on the flags",
          rc == 0 and "recorded NDS.rbf" in out
          and "matches NDS.rbf" in out and "SUCCESS" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify"])
    check("build.bat fails when --verify has no record",
          rc == 1 and "--verify asked for a record" in out
          and "Deploy to the" not in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--record"])
    block = out[out.find("Deploy to the"):]
    check("build.bat prints the record after the deploy block",
          rc == 0 and "Record for output_files" in block
          and "sha256:" in block and "build stamp: 261108" in block,
          out)

    root = new()
    move_pin(root, "261109")
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=["--record", "--verify", binp])
    check("release chain bumps, builds, records, verifies",
          rc == 0 and "Build stamp: 261109" in out
          and "recorded NDS.rbf" in out
          and "stamp 261109" in out
          and "build stamp: 261109" in out, out)

    root = new()
    run(root, "--record")
    os.utime(sidecar(root), (1000, 1000))
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify"])
    check("build.bat warns on an old record",
          rc == 0 and "warning:" in out and "Deploy to the" in out, out)

    root = new()
    run(root, "--record")
    os.utime(sidecar(root), (1000, 1000))
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify", "--strict"])
    check("build.bat --strict fails on an old record",
          rc == 1 and "older than sys/build_id.txt" in out
          and "Deploy to the" not in out, out)

    root = new()
    run(root, "--record")
    os.utime(sidecar(root), (1000, 1000))
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--strict", "--verify"])
    check("build.bat takes --strict before --verify",
          rc == 1 and "older than sys/build_id.txt" in out, out)

    root = new()
    run(root, "--record")
    rc, out = batch(root, 2)
    block = out[out.find("Deploy to the"):]
    check("build.bat prints the record age without flags",
          rc == 0 and "Record for output_files" in block
          and "less than a minute ago" in block, out)

    root = new()
    run(root, "--record")
    age_record(root, 10)
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify", "--max-age", "5"])
    check("build.bat --max-age fails an old record",
          rc == 1 and "older than --max-age 5 (10 days ago)" in out
          and "Deploy to the" not in out, out)

    root = new()
    run(root, "--record")
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify", "--max-age", "1"])
    check("build.bat --max-age passes a fresh record",
          rc == 0 and "matches NDS.rbf" in out
          and "Deploy to the" in out, out)

    root = new()
    run(root, "--record")
    age_record(root, 10)
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--max-age", "5", "--verify"])
    check("build.bat takes --max-age before --verify",
          rc == 1 and "older than --max-age 5" in out, out)

    root = new()
    run(root, "--record")
    age_record(root, 10)
    os.utime(sidecar(root), (1000, 1000))
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--strict", "--max-age", "5"])
    check("build.bat combines --strict and --max-age",
          rc == 1 and "older than sys/build_id.txt" in out
          and "older than --max-age 5" in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--max-age"])
    check("build.bat needs a value for --max-age",
          rc == 1 and "needs a number of days" in out
          and "Using:" not in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--max-age", "abc"])
    check("build.bat rejects a non-numeric --max-age",
          rc == 1 and 'wants a whole number of days, got "abc"' in out
          and "Compiling NDS" not in out and "Using:" not in out, out)

    root = new()
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--max-age", "-1"])
    check("build.bat rejects a negative --max-age",
          rc == 1 and "wants a whole number of days" in out
          and "Compiling NDS" not in out, out)

    root = new()
    run(root, "--record")
    age_record(root, 10)
    binp = fake_quartus(root)
    rc, out = batch_full(root, 0, argv=[binp, "--verify", "--max-age", "0"])
    check("build.bat --max-age 0 rejects an older record",
          rc == 1 and "older than --max-age 0 (10 days ago)" in out
          and "wants a whole number" not in out
          and "Deploy to the" not in out, out)

    root = new()
    run(root, "--record")
    move_pin(root, "261109")
    os.environ["RECORD_FLAG"] = "1"
    try:
        rc, out = batch(root, 2)
    finally:
        del os.environ["RECORD_FLAG"]
    check("build.bat ignores ambient flags",
          rc == 1 and "ERROR: the recorded stamp" in out
          and "Deploy to the" not in out, out)


def main():
    roots = []

    def new(**kw):
        root = tree(**kw)
        roots.append(root)
        return root

    try:
        root = new()
        rc, out = run(root)
        check("bump to today",
              rc == 0 and pin(root) == [time.strftime("%y%m%d")] and
              "rebuild so the bitstream carries it" in out, out)
        rc, out = run(root)
        check("bump again is a no-op", rc == 0 and "already" in out
              and pin(root) == [time.strftime("%y%m%d")], out)
        rc, out = run(root, "250101")
        check("explicit stamp moves the pin",
              rc == 0 and pin(root) == ["250101"], out)
        raw = io.open(os.path.join(root, "sys", "build_id.txt"), "rb").read()
        check("comments and CRLF survive",
              raw.startswith(b"# pinned") and raw.count(b"\r\n") == 3, raw)
        rc, out = run(root, "abc")
        check("malformed stamp rejected", rc == 2 and "six digits" in out, out)

        root = new()
        rc, out = run(root, "--record")
        got = fields(root)
        want = hashlib.sha256(RBF).hexdigest()
        check("record writes the sidecar",
              rc == 0 and got.get("build stamp") == "261108"
              and got.get("bytes") == "256" and got.get("sha256") == want,
              out)
        rc, out = run(root, "--verify")
        check("verify accepts a matching record",
              rc == 0 and "matches NDS.rbf" in out, out)

        root = new()
        run(root, "--record")
        with io.open(os.path.join(root, "output_files", "NDS.rbf"),
                     "ab") as handle:
            handle.write(b"x")
        rc, out = run(root, "--verify")
        check("verify catches a changed bitstream",
              rc == 1 and "257" in out and "sha256" in out, out)

        root = new()
        run(root, "--record")
        set_pin(root, "261109")
        rc, out = run(root, "--verify")
        check("verify catches a moved pin", rc == 1 and "261109" in out, out)

        root = new()
        run(root, "--record")
        os.utime(sidecar(root), (1000, 1000))
        rc, out = run(root, "--verify")
        check("verify warns when the pin is newer",
              rc == 0 and "warning:" in out and "matches NDS.rbf" in out,
              out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--verify", "--strict")
        check("verify --strict accepts a fresh record",
              rc == 0 and "warning:" not in out and "matches NDS.rbf" in out,
              out)

        root = new()
        run(root, "--record")
        os.utime(sidecar(root), (1000, 1000))
        rc, out = run(root, "--verify", "--strict")
        check("verify --strict fails on an old record",
              rc == 1 and "older than sys/build_id.txt" in out
              and "does not describe" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--strict")
        check("--strict needs --verify",
              rc == 2 and "--strict only applies" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--age")
        check("--age reads a fresh record",
              rc == 0 and "recorded:" in out
              and "less than a minute ago" in out, out)

        root = new()
        when = time.strftime("%Y-%m-%d %H:%M:%S",
                             time.localtime(time.time() - 3 * 3600 - 600))
        write(sidecar(root),
              ("build stamp: 261108" + chr(13) + chr(10)
              + "recorded: " + when + chr(13) + chr(10)).encode("utf-8"))
        rc, out = run(root, "--age")
        check("--age counts hours", rc == 0 and "3 hours ago" in out, out)

        root = new()
        text = "build stamp: 261108" + chr(13) + chr(10)
        write(sidecar(root), text.encode("utf-8"))
        os.utime(sidecar(root), (time.time() - 2 * 86400,) * 2)
        rc, out = run(root, "--age")
        check("--age falls back to the file time",
              rc == 0 and "2 days ago" in out, out)

        root = new()
        when = time.strftime("%Y-%m-%d %H:%M:%S",
                             time.localtime(time.time() + 3600))
        write(sidecar(root),
              ("build stamp: 261108" + chr(13) + chr(10)
              + "recorded: " + when + chr(13) + chr(10)).encode("utf-8"))
        rc, out = run(root, "--age")
        check("--age reports a future timestamp",
              rc == 0 and "in the future" in out, out)

        root = new()
        rc, out = run(root, "--age")
        check("--age needs a record", rc == 1 and "no record at" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--verify", "--max-age", "1")
        check("--max-age accepts a fresh record",
              rc == 0 and "matches NDS.rbf" in out, out)

        root = new()
        run(root, "--record")
        age_record(root, 10)
        rc, out = run(root, "--verify", "--max-age", "5")
        check("--max-age fails an old record",
              rc == 1 and "older than --max-age 5 (10 days ago)" in out
              and "does not describe" in out, out)

        root = new()
        run(root, "--record")
        age_record(root, 10)
        rc, out = run(root, "--verify", "--max-age", "30")
        check("--max-age passes within the limit",
              rc == 0 and "matches NDS.rbf" in out, out)

        root = new()
        run(root, "--record")
        got = fields(root)
        text = ("build stamp: %s" % got["build stamp"]
                + chr(13) + chr(10)
                + "bytes: %s" % got["bytes"]
                + chr(13) + chr(10)
                + "sha256: %s" % got["sha256"])
        write(sidecar(root), text.encode("utf-8"))
        os.utime(sidecar(root), (time.time() - 10 * 86400,) * 2)
        rc, out = run(root, "--verify", "--max-age", "5")
        check("--max-age falls back to the file time",
              rc == 1 and "older than --max-age 5" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--max-age", "5")
        check("--max-age needs --verify",
              rc == 2 and "--max-age only applies" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--verify", "--max-age", "-1")
        check("--max-age rejects a negative limit",
              rc == 2 and "must not be negative" in out, out)

        root = new()
        run(root, "--record")
        age_record(root, 10)
        rc, out = run(root, "--verify", "--max-age", "5",
                      "output_files/NDS.rbf")
        check("verify takes the path after --max-age",
              rc == 1 and "older than --max-age 5" in out, out)

        root = new()
        run(root, "--record")
        os.utime(sidecar(root), (1000, 1000))
        rc, out = run(root, "--verify", "--strict", "output_files/NDS.rbf")
        check("verify takes the path after --strict",
              rc == 1 and "older than sys/build_id.txt" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--verify", "--max-age", "1", "--strict",
                      "output_files/NDS.rbf")
        check("verify takes the path last",
              rc == 0 and "matches NDS.rbf" in out, out)

        root = new()
        run(root, "--record")
        rc, out = run(root, "--verify", "--max-age", "5", "261108")
        check("a mode rejects a stamp where a bitstream goes",
              rc == 2 and "a mode takes a bitstream" in out, out)

        root = new()
        rc, out = run(root, "--verify")
        check("verify reports a missing record",
              rc == 1 and "no record at" in out, out)

        root = new()
        run(root, "--record")
        write(sidecar(root), b"build stamp: 261108\r\n")
        rc, out = run(root, "--verify")
        check("verify reports a truncated record",
              rc == 1 and "sha256 none" in out, out)

        root = new()
        os.remove(os.path.join(root, "output_files", "NDS.rbf"))
        rc, out = run(root, "--record")
        check("record refuses without a bitstream",
              rc == 1 and "build it first" in out, out)

        root = new()
        run(root, "--record")
        os.utime(os.path.join(root, "build_id.v"), (3000, 3000))
        rc, out = run(root, "--record")
        check("record refuses a stale bitstream",
              rc == 1 and "older than build_id.v" in out, out)

        root = new(build_date="261107")
        rc, out = run(root, "--record")
        check("record refuses a disagreeing build_id.v",
              rc == 1 and "261107" in out, out)

        root = new()
        write(os.path.join(root, "sys", "build_id.txt"),
              b"# nothing pinned\r\n")
        rc, out = run(root, "--record")
        check("record needs a pinned stamp",
              rc == 2 and "no pinned stamp" in out, out)

        root = new()
        rc, out = run(root, "--record", "--verify")
        check("record and verify are exclusive",
              rc == 2 and "not allowed" in out, out)

        batch_cases(new)
    finally:
        for root in roots:
            shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        for name, detail in failures:
            print("FAILED: %s" % name)
            if detail:
                print(detail.rstrip())
        print("%d of %d cases failed" % (len(failures), count))
        return 1
    print("%d cases passed" % count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
