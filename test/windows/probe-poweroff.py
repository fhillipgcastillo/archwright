#!/usr/bin/env python3
"""Answer one question: can a WHPX guest power off cleanly on this Windows host?

The Linux gate (test/vm/drive_vm.py, phase_all) ends its install with
`sync; systemctl poweroff -i`, waits for QEMU to exit, then boots the same
qcow2 a second time to prove the installed system comes up. Try Omarchy's
docs/FINDINGS.md reports that on stock QEMU under WHPX a guest-initiated
poweroff *wedges* - the guest shuts down, QEMU hangs at the final ACPI
transition at ~0% CPU, and the process must be force-killed - and that the
force-kill can discard writes the guest issued ~20s earlier. If that holds
here, a Windows host cannot run the gate, because the gate's entire second
half depends on that handoff surviving.

Nothing else about a Windows path matters until this is settled, so this
probe answers only this.

DELIBERATELY STANDALONE. It shares no code with drive_vm.py. The Linux oracle
works, and bending it around a second host is how a working harness gets
broken. The serial handling below is a reimplementation of the same technique
(including the ANSI-stripping and echoed-sentinel subtleties that file
documents) - that duplication is the price of the separation, and is not a
defect to be "fixed" by importing across the boundary.

Two canaries separate the write-loss half of the question from the wedge half:

  A  written, then `sync`                      - models what the gate does
  B  written immediately before poweroff, never
     synced                                    - models the loss Try Omarchy
                                                 reported

A clean result needs both a QEMU that exits on its own and a surviving
canary A. Canary B is diagnostic: if A lives and B dies, `sync` is sufficient
protection and the gate's existing discipline is enough.

Usage:  python test/windows/probe-poweroff.py

Requires (all verified present on the dev host):
  - QEMU for Windows with the whpx accelerator and edk2 firmware in share/
  - %USERPROFILE%\\.cache\\archwright-win\\archlinux.iso plus boot/ populated
    with vmlinuz-linux, initramfs-linux.img and archisolabel.txt
"""

import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import time

CACHE = pathlib.Path(os.environ.get(
    "ARCHWRIGHT_WIN_CACHE", pathlib.Path.home() / ".cache" / "archwright-win"))
ISO = CACHE / "archlinux.iso"
BOOT = CACHE / "boot"
RUN = CACHE / "probe-run"

# Try Omarchy's proven ceiling for stock WHPX (their docs/FINDINGS.md, "the
# XSAVE cliff"): any AVX-class feature is accepted at launch and then panics
# the guest kernel at ~0.25s in fpstate_reset. Do not widen this without a
# guest that boots to prove it.
CPU = "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes"

BOOT_TIMEOUT = 420
# The same budget phase_all allows before it gives up and force-kills.
POWEROFF_WAIT = 180

LIVE_PROMPT = "root@archiso ~ #"
LIVE_LOGIN = "archiso login:"

# The guest prompt is colourised, so on the wire 'root' and '@archiso' are
# separated by escape sequences and a literal match never succeeds. Match
# against an ANSI-stripped copy; raw bytes still reach stdout so the log
# stays readable.
_ANSI = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"   # OSC ... terminated by BEL or ST
    r"|\x1b\[[0-9;?]*[ -/]*[@-~]"          # CSI
    r"|\x1b[()][0-9A-Za-z]"                # charset selection
    r"|\x1b[@-Z\\-_]"                      # other two-byte escapes
)
# A trailing fragment that may be an escape sequence split across two reads.
_ESC_TAIL = re.compile(r"\x1b(?:[\[\]()][0-9;?]*)?$")


def log(msg):
    print(f"[probe] {msg}", flush=True)


def die(msg):
    print(f"[probe] FATAL: {msg}", file=sys.stderr, flush=True)
    sys.exit(2)


class Serial:
    """Line-oriented conversation with the guest over a TCP serial port."""

    def __init__(self, port):
        self.buf = ""
        self._pending = ""
        deadline = time.time() + 60
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(1.0)

    def _feed(self, chunk):
        # An escape sequence can be split across two recv() calls, so hold
        # back a trailing partial rather than stripping it incorrectly.
        data = self._pending + chunk
        self._pending = ""
        m = _ESC_TAIL.search(data)
        if m:
            self._pending = data[m.start():]
            data = data[:m.start()]
        self.buf += _ANSI.sub("", data).replace("\r", "")

    def _recv_once(self, echo):
        try:
            chunk = self.sock.recv(4096).decode("utf-8", "replace")
        except socket.timeout:
            return
        except OSError as exc:
            raise TimeoutError(f"serial connection lost: {exc}") from exc
        if not chunk:
            time.sleep(0.1)
            return
        if echo:
            sys.stdout.write(chunk)
            sys.stdout.flush()
        self._feed(chunk)

    def _take(self, needle):
        idx = self.buf.index(needle) + len(needle)
        seen, self.buf = self.buf[:idx], self.buf[idx:]
        return seen

    def read_until(self, needle, timeout, echo=True):
        deadline = time.time() + timeout
        while needle not in self.buf:
            if time.time() > deadline:
                raise TimeoutError(
                    f"timed out after {timeout}s waiting for {needle!r}\n"
                    f"--- last guest output ---\n{self.buf[-4000:]}\n--- end ---")
            self._recv_once(echo)
        return self._take(needle)

    def read_until_any(self, needles, timeout, echo=True):
        deadline = time.time() + timeout
        while True:
            for n in needles:
                if n in self.buf:
                    return n, self._take(n)
            if time.time() > deadline:
                raise TimeoutError(
                    f"timed out after {timeout}s waiting for any of {needles!r}\n"
                    f"--- last guest output ---\n{self.buf[-4000:]}\n--- end ---")
            self._recv_once(echo)

    def send(self, line):
        self.sock.sendall((line + "\n").encode())

    def run(self, cmd, timeout=600):
        """Run a command; return (exit_status, output).

        The sentinel is unique per call so a slow command's output is not
        mistaken for the next command's completion, and it is split across a
        concatenation because the console echoes what we type - an
        un-split sentinel would match its own echo and every command would
        report status 1.
        """
        head, tail = "AWDN", str(int(time.time() * 1000) % 1000000)
        marker = f"{head}{tail}:"
        self.send(f'{cmd}; echo "{head}""{tail}:$?"')
        out = self.read_until(marker, timeout)
        status = self.read_until("\n", 30).strip()
        try:
            return int(status), out
        except ValueError:
            return 1, out


def qemu_binary():
    found = os.environ.get("ARCHWRIGHT_QEMU") or shutil.which("qemu-system-x86_64")
    if not found:
        default = pathlib.Path(r"C:\Program Files\qemu\qemu-system-x86_64.exe")
        if default.is_file():
            found = str(default)
    if not found:
        die("qemu-system-x86_64 not found. Install QEMU for Windows, or set "
            "ARCHWRIGHT_QEMU to its full path.")
    return found


def qemu_img():
    found = os.environ.get("ARCHWRIGHT_QEMU_IMG") or shutil.which("qemu-img")
    if not found:
        cand = pathlib.Path(qemu_binary()).parent / "qemu-img.exe"
        if cand.is_file():
            found = str(cand)
    if not found:
        die("qemu-img not found alongside qemu-system-x86_64.")
    return found


def firmware():
    """QEMU for Windows ships edk2 firmware in share/ next to the binary.

    Derived from the resolved binary rather than a fixed path list, so a
    portable or non-default install works without editing this file.
    """
    share = pathlib.Path(qemu_binary()).parent / "share"
    code = share / "edk2-x86_64-code.fd"
    varsf = share / "edk2-i386-vars.fd"
    for f in (code, varsf):
        if not f.is_file():
            die(f"firmware missing: {f}")
    return code, varsf


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def fresh_run_dir():
    if RUN.exists():
        shutil.rmtree(RUN)
    RUN.mkdir(parents=True)
    _, varsf = firmware()
    shutil.copy(varsf, RUN / "OVMF_VARS.fd")
    disk = RUN / "disk.qcow2"
    subprocess.check_call([qemu_img(), "create", "-f", "qcow2", str(disk), "2G"],
                          stdout=subprocess.DEVNULL)
    log(f"fresh run dir {RUN} (2G dynamic qcow2, own copy of the OVMF vars)")
    return disk


def start_qemu(disk, serial_port):
    """Boot the live ISO with the device set the gate uses, minus the 9p share.

    virtio-9p is not compiled into QEMU for Windows (`-fsdev help` reports
    "fsdev support is disabled"), and it is only a package cache anyway. Every
    other device matches phase_all so a clean result here transfers.

    -no-reboot is deliberately NOT passed: it changes what a guest *reset*
    does, and the question here is what a guest *poweroff* does on stock
    settings.
    """
    code, _ = firmware()
    label = (BOOT / "archisolabel.txt").read_text().strip()
    args = [
        qemu_binary(),
        "-machine", "q35,accel=whpx",
        "-cpu", CPU,
        "-m", "4096", "-smp", "2",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={RUN / 'OVMF_VARS.fd'}",
        "-drive", f"file={disk},if=virtio,format=qcow2",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-serial", f"tcp:127.0.0.1:{serial_port},server=on,wait=off",
        "-device", "virtio-vga",
        "-audiodev", "none,id=snd0",
        "-device", "intel-hda",
        "-device", "hda-duplex,audiodev=snd0",
        "-display", "none",
        "-cdrom", str(ISO),
        "-kernel", str(BOOT / "vmlinuz-linux"),
        "-initrd", str(BOOT / "initramfs-linux.img"),
        "-append", f"archisobasedir=arch archisolabel={label} console=ttyS0,115200",
    ]
    log(f"launching qemu (accel=whpx, cpu={CPU})")
    return subprocess.Popen(args)


def wait_for_live_shell(ser):
    """archiso autologins root on tty1, but serial-getty presents a login.

    Root has no password on the official medium, so answering it is enough.
    Both shapes are handled rather than assuming one.
    """
    marker, _ = ser.read_until_any([LIVE_LOGIN, LIVE_PROMPT], BOOT_TIMEOUT)
    if marker == LIVE_LOGIN:
        log("serial getty presented a login prompt; logging in as root")
        ser.send("root")
        ser.read_until(LIVE_PROMPT, 120)
    rc, _ = ser.run("true", 60)
    if rc != 0:
        die("could not establish a usable shell in the live environment")
    log("live root shell established")


def phase_write_and_poweroff(disk):
    """Write both canaries, then ask the guest to power off. Returns a dict."""
    result = {}
    sport = free_port()
    proc = start_qemu(disk, sport)
    t0 = time.time()
    try:
        ser = Serial(sport)
        wait_for_live_shell(ser)
        result["boot_seconds"] = round(time.time() - t0, 1)
        log(f"gate 1 met: live shell in {result['boot_seconds']}s under WHPX")

        for cmd in (
            "mkfs.ext4 -F -q /dev/vda",
            "mkdir -p /mnt/probe && mount /dev/vda /mnt/probe",
            "echo CANARY-A-SYNCED > /mnt/probe/canary-a.txt",
            "sync",
        ):
            rc, _ = ser.run(cmd, 300)
            if rc != 0:
                die(f"guest setup command failed (status {rc}): {cmd}")
        log("canary A written and synced")

        # B is written with no sync and no settling time: this is the write
        # Try Omarchy reported losing.
        ser.run("echo CANARY-B-UNSYNCED > /mnt/probe/canary-b.txt", 60)
        log("canary B written, not synced; requesting poweroff now")

        # Exactly what phase_all sends.
        t1 = time.time()
        ser.send("sync; systemctl poweroff -i")
        try:
            proc.wait(timeout=POWEROFF_WAIT)
            result["wedged"] = False
            result["poweroff_seconds"] = round(time.time() - t1, 1)
            result["exit_code"] = proc.returncode
            log(f"QEMU exited on its own after {result['poweroff_seconds']}s "
                f"(exit code {proc.returncode})")
        except subprocess.TimeoutExpired:
            result["wedged"] = True
            result["poweroff_seconds"] = None
            result["exit_code"] = None
            log(f"WEDGE: QEMU still alive {POWEROFF_WAIT}s after poweroff; "
                f"force-killing (this is the Try Omarchy failure)")
            proc.kill()
            proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
    return result


def phase_read_back(disk):
    """Boot the live ISO again and see which canaries survived."""
    result = {}
    sport = free_port()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        wait_for_live_shell(ser)
        rc, _ = ser.run("mkdir -p /mnt/probe && mount /dev/vda /mnt/probe", 120)
        if rc != 0:
            result["mountable"] = False
            log("the filesystem written before poweroff will not mount")
            return result
        result["mountable"] = True
        for name, key in (("canary-a.txt", "canary_a"), ("canary-b.txt", "canary_b")):
            rc, out = ser.run(f"cat /mnt/probe/{name} 2>/dev/null", 60)
            result[key] = (rc == 0 and "CANARY-" in out)
            log(f"{name}: {'present' if result[key] else 'LOST'}")
    finally:
        if proc.poll() is None:
            ser.send("sync; systemctl poweroff -i")
            try:
                proc.wait(timeout=POWEROFF_WAIT)
            except subprocess.TimeoutExpired:
                proc.kill()
    return result


def main():
    # Windows Python encodes stdout as cp1252 by default. The guest's serial
    # stream is not all valid UTF-8 - undecodable bytes become U+FFFD, which
    # cp1252 cannot encode, and the whole probe dies mid-boot with a
    # UnicodeEncodeError. The Linux harness never sees this because it runs
    # under a UTF-8 locale.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

    for path in (ISO, BOOT / "vmlinuz-linux", BOOT / "initramfs-linux.img",
                 BOOT / "archisolabel.txt"):
        if not path.is_file():
            die(f"missing {path}. Populate {CACHE} first.")

    disk = fresh_run_dir()
    log("=== phase 1: write canaries, then poweroff ===")
    off = phase_write_and_poweroff(disk)
    log("=== phase 2: boot again and read the canaries back ===")
    back = phase_read_back(disk)

    print("\n" + "=" * 62)
    print("  WHPX POWEROFF PROBE - RESULT")
    print("=" * 62)
    print(f"  boot to live shell     {off.get('boot_seconds')}s")
    print(f"  poweroff wedged        {off.get('wedged')}")
    print(f"  poweroff took          {off.get('poweroff_seconds')}s")
    print(f"  qemu exit code         {off.get('exit_code')}")
    print(f"  filesystem mountable   {back.get('mountable')}")
    print(f"  canary A (synced)      {'present' if back.get('canary_a') else 'LOST'}")
    print(f"  canary B (unsynced)    {'present' if back.get('canary_b') else 'LOST'}")
    print("=" * 62)

    clean = (off.get("wedged") is False
             and back.get("mountable") is True
             and back.get("canary_a") is True)
    if clean:
        print("  VERDICT: a WHPX guest powers off cleanly and synced writes")
        print("           survive. The gate's install -> reboot handoff is")
        print("           viable on this Windows host.")
    else:
        print("  VERDICT: the handoff the gate depends on does NOT hold here.")
        print("           A Windows host cannot run the full gate unchanged.")
    print("=" * 62 + "\n")
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
