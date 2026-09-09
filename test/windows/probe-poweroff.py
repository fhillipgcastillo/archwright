#!/usr/bin/env python3
"""Isolate whether a WHPX guest powers off cleanly without losing writes.

Two canaries: A is synced before poweroff, B is written immediately before it
and never synced.

Usage:  python test/windows/probe-poweroff.py
"""

import sys

from winvm import (Serial, die, free_port, fresh_run_dir, log,
                   poweroff_and_wait, require_cache, start_qemu,
                   use_utf8_stdout, wait_for_live_shell)


def write_and_poweroff(disk, result):
    sport = free_port()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        wait_for_live_shell(ser)
        for cmd in (
            "mkfs.ext4 -F -q /dev/vda",
            "mkdir -p /mnt/probe && mount /dev/vda /mnt/probe",
            "echo CANARY-A-SYNCED > /mnt/probe/canary-a.txt",
            "sync",
        ):
            rc, _ = ser.run(cmd, 300)
            if rc != 0:
                die(f"guest setup command failed (status {rc}): {cmd}")
        ser.run("echo CANARY-B-UNSYNCED > /mnt/probe/canary-b.txt", 60)
        log("canaries written; requesting poweroff")

        wedged, secs, code = poweroff_and_wait(ser, proc)
        result["wedged"] = wedged
        result["poweroff_seconds"] = secs
        result["exit_code"] = code
        if not wedged:
            log(f"QEMU exited on its own after {secs}s (exit code {code})")
    finally:
        if proc.poll() is None:
            proc.kill()


def read_back(disk, result):
    sport = free_port()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        wait_for_live_shell(ser)
        rc, _ = ser.run("mkdir -p /mnt/probe && mount /dev/vda /mnt/probe", 120)
        result["mountable"] = (rc == 0)
        if rc != 0:
            log("the filesystem written before poweroff will not mount")
            return
        for name, key in (("canary-a.txt", "canary_a"), ("canary-b.txt", "canary_b")):
            rc, out = ser.run(f"cat /mnt/probe/{name} 2>/dev/null", 60)
            result[key] = (rc == 0 and "CANARY-" in out)
            log(f"{name}: {'present' if result[key] else 'LOST'}")
    finally:
        if proc.poll() is None:
            proc.kill()


def main():
    use_utf8_stdout()
    require_cache()
    result = {}
    disk = fresh_run_dir("2G")
    log("=== phase 1: write canaries, then poweroff ===")
    write_and_poweroff(disk, result)
    log("=== phase 2: boot again and read the canaries back ===")
    read_back(disk, result)

    print("\n" + "=" * 62)
    print("  WHPX POWEROFF PROBE - RESULT")
    print("=" * 62)
    print(f"  poweroff wedged        {result.get('wedged')}")
    print(f"  poweroff took          {result.get('poweroff_seconds')}s")
    print(f"  qemu exit code         {result.get('exit_code')}")
    print(f"  filesystem mountable   {result.get('mountable')}")
    print(f"  canary A (synced)      {'present' if result.get('canary_a') else 'LOST'}")
    print(f"  canary B (unsynced)    {'present' if result.get('canary_b') else 'LOST'}")
    print("=" * 62 + "\n")

    return 0 if (result.get("wedged") is False
                 and result.get("mountable") is True
                 and result.get("canary_a") is True) else 1


if __name__ == "__main__":
    sys.exit(main())
