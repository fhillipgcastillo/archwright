#!/usr/bin/env python3
"""Escape handling in winvm.Serial._feed, mirroring test/unit/test_serial.sh.

Usage:  python test/windows/test_serial.py
"""

import sys

from winvm import Serial

OSC = ("\x1b]3008;start=960e2fb6;user=test;hostname=archwright-vm;"
       "machineid=500307df;bootid=2e7aba1d;pid=931;comm=sudo;"
       "targetuser=root;type=session\x1b\\")


def feed(chunks):
    ser = Serial.__new__(Serial)
    ser.buf = ""
    ser._pending = ""
    for chunk in chunks:
        ser._feed(chunk)
    return ser.buf


def main():
    half = len(OSC) // 2
    cases = (
        ("whole", ["before" + OSC + "after"]),
        ("split", ["before" + OSC[:half], OSC[half:] + "after"]),
        ("introducer", ["before" + OSC[:2], OSC[2:] + "after"]),
        ("csi", ["be\x1b[32mfore", "after"]),
        ("plain", ["before", "after"]),
    )
    failed = 0
    for name, chunks in cases:
        got = feed(chunks)
        if got == "beforeafter":
            print(f"ok    _feed strips it: {name}")
        else:
            print(f"FAIL  _feed strips it: {name}: got {got!r}")
            failed += 1
    print(f"test_serial.py: {len(cases)} run, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
