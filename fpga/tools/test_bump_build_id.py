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
              'set "BUILD_STAMP=261108"'] + body + [""]
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
