#!/usr/bin/env python3
"""Full install, poweroff, and boot of the installed system on a Windows host.

Usage:  python test/windows/probe-install-boot.py
"""

import sys
import time

from winvm import (BOOT_TIMEOUT, Serial, die, free_port, fresh_run_dir,
                   guest_fetch_repo, log, poweroff_and_wait, require_cache,
                   serve_repo, start_qemu, use_utf8_stdout, wait_for_live_shell)

ANSWERS = "/root/archwright/test/vm/answers.example.conf"

# Budgets are larger than the Linux gate's for base and apps: QEMU for Windows
# has no virtio-9p, so there is no host package cache and every run downloads.
PHASES = (
    ("preflight", 300), ("disk", 900), ("base", 3600), ("boot", 2400),
    ("theme", 600), ("session", 1200), ("shell", 900), ("apps", 3000),
    ("ai", 900), ("hardware", 900),
)


def run_installer(ser, phase, timeout):
    # No --host-pkg-cache: that makes pacstrap use the live environment's cache,
    # which is tmpfs in RAM unless a host directory is mounted over 9p.
    return ser.run(
        f"bash /root/archwright/install.sh --answers {ANSWERS}"
        f" --phase {phase} --yes", timeout)


def do_install(disk, port, result):
    sport = free_port()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        wait_for_live_shell(ser)
        guest_fetch_repo(ser, port)

        t0 = time.time()
        for phase, timeout in PHASES:
            t1 = time.time()
            rc, _ = run_installer(ser, phase, timeout)
            if rc != 0:
                result["failed_phase"] = phase
                die(f"install phase {phase} failed with status {rc}")
            log(f"phase {phase} ok in {round(time.time() - t1, 1)}s")
        result["install_seconds"] = round(time.time() - t0, 1)
        log(f"install complete in {result['install_seconds']}s")

        wedged, secs, code = poweroff_and_wait(ser, proc)
        result["wedged"] = wedged
        result["poweroff_seconds"] = secs
        result["exit_code"] = code
        if not wedged:
            log(f"QEMU exited on its own after {secs}s (exit code {code})")
    finally:
        if proc.poll() is None:
            proc.kill()


def do_boot_installed(disk, port, result):
    sport = free_port()
    proc = start_qemu(disk, sport, iso_boot=False)
    try:
        ser = Serial(sport)
        ser.read_until("passphrase", BOOT_TIMEOUT)
        ser.send("testpassphrase")
        result["luks_prompt"] = True
        log("LUKS passphrase prompt appeared and was answered")

        ser.read_until("login:", BOOT_TIMEOUT)
        ser.send("test")
        ser.read_until("Password:", 120)
        ser.send("testpassword")
        ser.read_until("@archwright-vm", 120)
        rc, _ = ser.run("true", 60)
        result["logged_in"] = (rc == 0)
        if rc != 0:
            die("logged in but could not run a command")
        log("the installed system booted and accepted a login")

        rc, _ = ser.run(
            f"for i in $(seq 1 30); do "
            f"curl -fsS -o /tmp/assertions.sh http://10.0.2.2:{port}/assertions.sh "
            f"&& break; sleep 2; done; test -s /tmp/assertions.sh", 120)
        if rc != 0:
            result["assertions"] = "unreachable"
            log("could not fetch the assertion script into the installed system")
            return
        rc, out = ser.run(
            "echo testpassword | sudo -S bash /tmp/assertions.sh 2>&1", 900)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith(("ok ", "FAIL")) or "ASSERTIONS" in line:
                log(f"  {line}")
        result["assertions"] = ("passed" if "ASSERTIONS-PASSED" in out else "failed")
    finally:
        if proc.poll() is None:
            proc.kill()


def report(result):
    print("\n" + "=" * 62)
    print("  WINDOWS/WHPX FULL-GATE PROBE - RESULT")
    print("=" * 62)
    for label, key in (
        ("install seconds", "install_seconds"),
        ("failed phase", "failed_phase"),
        ("poweroff wedged", "wedged"),
        ("poweroff seconds", "poweroff_seconds"),
        ("qemu exit code", "exit_code"),
        ("LUKS prompt", "luks_prompt"),
        ("login accepted", "logged_in"),
        ("assertions", "assertions"),
    ):
        print(f"  {label:22} {result.get(key)}")
    print("=" * 62)

    mechanics = (result.get("wedged") is False
                 and result.get("luks_prompt") is True
                 and result.get("logged_in") is True)
    if mechanics:
        print("  VERDICT: a Windows host completes install -> poweroff -> boot")
        print("           of the installed encrypted system under WHPX.")
    else:
        print("  VERDICT: the Windows host did NOT complete the gate mechanics.")
    print("=" * 62 + "\n")
    return mechanics and result.get("assertions") == "passed"


def main():
    use_utf8_stdout()
    require_cache()
    result = {}
    disk = fresh_run_dir("20G")
    port, httpd = serve_repo()
    try:
        log("=== phase 1: install from the live ISO, then poweroff ===")
        do_install(disk, port, result)
        if result.get("wedged"):
            report(result)
            return 1
        log("=== phase 2: boot the installed system from disk ===")
        do_boot_installed(disk, port, result)
    finally:
        try:
            httpd.shutdown()
        except Exception:
            pass
    return 0 if report(result) else 1


if __name__ == "__main__":
    sys.exit(main())
