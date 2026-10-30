#!/usr/bin/env python3
"""Show where this machine's memory is going, grouped by process name.

Useful before a build: on an 8 GB box the commit limit (RAM + pagefile) is
reachable by Quartus alone, and Windows answers that with a freeze and a
bugcheck rather than an allocation failure.
"""
import ctypes
import os
import subprocess
import sys


class _MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]


class _PMC(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]


def stats():
    st = _MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
    return st


def main():
    st = stats()
    print("RAM %d MB, available %d MB, load %d%%" % (st.ullTotalPhys >> 20, st.ullAvailPhys >> 20, st.dwMemoryLoad))
    print("commit limit %d MB, headroom %d MB" % (st.ullTotalPageFile >> 20, st.ullAvailPageFile >> 20))
    if os.name != "nt":
        return 0

    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Get-CimInstance Win32_Process | Select-Object Name,WorkingSetSize,PagefileUsage | "
         "ForEach-Object { '{0}|{1}|{2}' -f $_.Name,$_.WorkingSetSize,$_.PagefileUsage }"],
        capture_output=True, text=True).stdout
    agg = {}
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 3:
            continue
        name, ws, pf = parts
        try:
            ws, pf = int(ws), int(pf)
        except ValueError:
            continue
        a = agg.setdefault(name, [0, 0, 0])
        a[0] += ws
        a[1] += pf
        a[2] += 1
    rows = sorted(agg.items(), key=lambda kv: -kv[1][1])[:12]
    print("\n%-24s %9s %9s %5s" % ("process", "private", "working", "n"))
    for name, (ws, pf, n) in rows:
        print("%-24s %8dM %8dM %5d" % (name[:24], pf >> 20, ws >> 20, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
