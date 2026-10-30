#!/usr/bin/env python3
"""Run one simulation step with a memory and time guard.

A testbench that allocates without bound can push this machine (8 GB, small
pagefile) into virtual-memory exhaustion, and Windows then reboots it: the
event log shows vvp.exe holding 28 GB and a bugcheck 0xa5 shortly after. The
guard polls available physical memory while the step runs and kills the whole
process tree before that can happen, so a bad bench costs a line of output
instead of the session.

No psutil and no PowerShell: the numbers come straight from the two Win32
calls that also back Task Manager, and output is streamed to a file so a
runaway `$display` loop cannot fill memory here either.
"""
import ctypes
import os
import subprocess
import sys
import time

IS_WIN = os.name == "nt"

if IS_WIN:
    class _MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ("dwLength", ctypes.c_ulong),
            ("dwMemoryLoad", ctypes.c_ulong),
            ("ullTotalPhys", ctypes.c_ulonglong),
            ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong),
            ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong),
            ("ullAvailVirtual", ctypes.c_ulonglong),
            ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    class _PROCESS_MEMORY_COUNTERS(ctypes.Structure):
        _fields_ = [
            ("cb", ctypes.c_ulong),
            ("PageFaultCount", ctypes.c_ulong),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    _k32 = ctypes.windll.kernel32
    _psapi = ctypes.windll.psapi
    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def available_mb():
    """Physical memory Windows can hand out now (free + standby)."""
    if not IS_WIN:
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemAvailable:"):
                        return int(line.split()[1]) // 1024
        except OSError:
            return None
        return None
    st = _MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
    if not _k32.GlobalMemoryStatusEx(ctypes.byref(st)):
        return None
    return int(st.ullAvailPhys // (1024 * 1024))


def commit_mb():
    """Commit headroom: this is what actually runs out first on a small box."""
    if not IS_WIN:
        return None
    st = _MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
    if not _k32.GlobalMemoryStatusEx(ctypes.byref(st)):
        return None
    return int(st.ullAvailPageFile // (1024 * 1024))


def peak_mb(pid):
    """Peak working set of a live process, or 0 if it cannot be read."""
    if not IS_WIN:
        return 0
    h = _k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return 0
    try:
        pmc = _PROCESS_MEMORY_COUNTERS()
        pmc.cb = ctypes.sizeof(_PROCESS_MEMORY_COUNTERS)
        if not _psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
            return 0
        return int(pmc.PeakWorkingSetSize // (1024 * 1024))
    finally:
        _k32.CloseHandle(h)


def _kill_tree(pid):
    if IS_WIN:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def find_bash():
    """A real bash. `bash` on PATH is often the WSL relay, which has no
    /bin/bash and fails every command with a CreateProcessCommon error."""
    if not IS_WIN:
        return "bash"
    local = os.environ.get("LOCALAPPDATA", "")
    for c in (os.path.join(os.environ.get("PROGRAMFILES", "C:/Program Files"),
                           "Git", "bin", "bash.exe"),
              os.path.join(local, "Programs", "Git", "bin", "bash.exe"),
              os.path.join(os.environ.get("PROGRAMFILES", "C:/Program Files"),
                           "Git", "usr", "bin", "bash.exe")):
        if os.path.isfile(c):
            return c
    return "bash"


def _shell_env():
    """bash reaches /tmp and the OSS CAD Suite; a native tool needs the same
    directories in Windows form on PATH."""
    env = dict(os.environ)
    tmp = env.get("TEMP") or env.get("TMP") or ""
    suite = os.path.join(tmp, "oss-cad-suite")
    # always in Windows form: the tools are native binaries, so a POSIX
    # /tmp/... entry inherited from a shell is invisible to them. lib is on
    # PATH too because vvp.exe loads its shared libraries from there.
    if os.path.isdir(suite):
        want = [os.path.join(suite, "lib"), os.path.join(suite, "bin")]
        have = env.get("PATH", "").lower()
        add = [p for p in want if p.lower() not in have]
        if add:
            env["PATH"] = os.pathsep.join(add + [env.get("PATH", "")])
    return env


class Result:
    def __init__(self, rc, seconds, peak, low, low_commit, aborted, why, log):
        self.rc, self.seconds, self.peak, self.low = rc, seconds, peak, low
        self.low_commit = low_commit
        self.aborted, self.why, self.log = aborted, why, log

    @property
    def ok(self):
        return self.rc == 0 and not self.aborted

    def line(self):
        low = "n/a" if self.low is None else "%d MB" % self.low
        com = "n/a" if self.low_commit is None else "%d MB" % self.low_commit
        s = "%.1f s, peak %d MB, low available %s, low commit %s, exit %d" % (
            self.seconds, self.peak, low, com, self.rc)
        if self.aborted:
            s += "  [%s]" % self.why
        return s


def run(cmd, log, min_free_mb=0, max_seconds=180, poll=0.05, cwd=None,
        min_commit_mb=600):
    """Run `cmd` (a shell line) with output to `log`; kill it on trouble.

    Commit headroom is the guard that matters, and it is the only one on by
    default. A build step is a paged workload: it holds several GB of commit
    while physical memory sits at a few hundred MB, and that is normal once the
    pagefile is sized for it — a Quartus run here was killed with 273 MB
    available and 15.3 GB of commit still free. Running out of commit is what
    produces the freeze and the bugcheck; `min_free_mb` is opt-in for machines
    whose pagefile is still small."""
    os.makedirs(os.path.dirname(log) or ".", exist_ok=True)
    with open(log, "wb") as fh:
        p = subprocess.Popen([find_bash(), "-c", cmd], stdout=fh,
                             stderr=subprocess.STDOUT, cwd=cwd,
                             env=_shell_env())
        t0 = time.time()
        peak, low, low_commit, aborted, why = 0, None, None, False, ""
        while p.poll() is None:
            m = peak_mb(p.pid)
            if m > peak:
                peak = m
            c = commit_mb()
            if c is not None:
                low_commit = c if low_commit is None else min(low_commit, c)
                if min_commit_mb and c < min_commit_mb:
                    aborted, why = True, "killed at %d MB commit headroom" % c
            a = available_mb()
            if a is not None:
                low = a if low is None else min(low, a)
                if not aborted and min_free_mb and a < min_free_mb:
                    aborted, why = True, "killed at %d MB available" % a
            if not aborted and max_seconds and time.time() - t0 > max_seconds:
                aborted, why = True, "killed after %d s" % max_seconds
            if aborted:
                _kill_tree(p.pid)
                p.wait()
                break
            time.sleep(poll)
        secs = time.time() - t0
    return Result(p.returncode, secs, peak, low, low_commit, aborted, why, log)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="run one step under the guard")
    ap.add_argument("-o", "--log", default=os.path.join(os.environ.get("TEMP", "/tmp"), "guard.log"))
    ap.add_argument("--min-free", type=int, default=0,
                    help="optional physical floor; 0 = commit only (default)")
    ap.add_argument("--min-commit", type=int, default=600)
    ap.add_argument("--max-seconds", type=int, default=180)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = " ".join(a.cmd).strip()
    if cmd.startswith("-- "):
        cmd = cmd[3:]
    r = run(cmd, a.log, a.min_free, a.max_seconds, min_commit_mb=a.min_commit)
    print(cmd.split()[0] + ": " + r.line())
    sys.exit(0 if r.ok else 1)
