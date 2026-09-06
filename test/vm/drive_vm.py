#!/usr/bin/env python3
"""Drive an Archwright install inside QEMU over a serial console.

Design notes worth knowing before changing anything here:

* The guest reaches the host at 10.0.2.2 under QEMU user-mode networking, so
  the working tree is served over plain HTTP rather than baked into an image.
  Every run therefore tests what is on disk, not what was last committed.

* The Arch ISO is booted with -kernel/-initrd rather than as a plain CD, which
  is what lets us append console=ttyS0,115200. Without that there is no way to
  reach a serial console except editing the boot menu by hand.

* Every run gets a fresh qcow2 AND a fresh copy of the OVMF variables. Reusing
  the vars file leaks NVRAM boot entries between runs and produces confusing
  false passes.
"""
import argparse
import http.server
import os
import pathlib
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tarfile
import threading
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
CACHE = pathlib.Path(os.environ.get("ARCHWRIGHT_CACHE",
                                    pathlib.Path.home() / ".cache" / "archwright"))
ISO = CACHE / "archlinux.iso"
BOOT = CACHE / "boot"
VMRUN = CACHE / "vmrun"

# The guest prompt is colourised, so on the wire 'root' and '@archiso' are
# separated by escape sequences and a literal match for "root@archiso" never
# succeeds. Matching therefore runs against an ANSI-stripped copy of the
# stream; raw bytes still go to stdout so the log stays readable.
_ANSI = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"   # OSC ... terminated by BEL or ST
    r"|\x1b\[[0-9;?]*[ -/]*[@-~]"          # CSI
    r"|\x1b[()][0-9A-Za-z]"                # charset selection
    r"|\x1b[@-Z\\-_]"                      # other two-byte escapes
)
# A trailing fragment that may be an escape sequence split across two reads.
_ESC_TAIL = re.compile(r"\x1b(?:[\[\]()][0-9;?]*)?$")

LIVE_PROMPT = "root@archiso ~ #"
LIVE_LOGIN = "archiso login:"
BOOT_TIMEOUT = int(os.environ.get("AW_BOOT_TIMEOUT", "420"))

OVMF_CODE_CANDIDATES = [
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd",
    "/usr/share/edk2/x64/OVMF_CODE.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
]
OVMF_VARS_CANDIDATES = [
    "/usr/share/OVMF/OVMF_VARS_4M.fd",
    "/usr/share/OVMF/OVMF_VARS.fd",
    "/usr/share/edk2/x64/OVMF_VARS.4m.fd",
    "/usr/share/edk2/x64/OVMF_VARS.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
]


def log(msg):
    print(f"[drive_vm] {msg}", flush=True)


def die(msg):
    print(f"[drive_vm] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def _first_existing(candidates, what, env_var):
    override = os.environ.get(env_var)
    if override:
        return override
    for c in candidates:
        if pathlib.Path(c).is_file():
            return c
    die(f"no {what} found. On Debian/Ubuntu: apt install ovmf (or set {env_var})")


def qemu_binary():
    found = os.environ.get("ARCHWRIGHT_QEMU") or shutil.which("qemu-system-x86_64")
    if not found:
        die("qemu-system-x86_64 not found. On Debian/Ubuntu: apt install qemu-system-x86")
    return found


def qemu_img():
    found = os.environ.get("ARCHWRIGHT_QEMU_IMG") or shutil.which("qemu-img")
    if not found:
        die("qemu-img not found. On Debian/Ubuntu: apt install qemu-utils")
    return found


def accel():
    kvm = pathlib.Path("/dev/kvm")
    if kvm.exists() and os.access(kvm, os.R_OK | os.W_OK):
        return "kvm"
    log("WARNING: /dev/kvm unavailable, falling back to tcg. This will be slow.")
    return "tcg"


def serve_repo():
    """Pack the working tree and serve it. Returns (port, httpd)."""
    VMRUN.mkdir(parents=True, exist_ok=True)
    tar_path = VMRUN / "repo.tar"
    with tarfile.open(tar_path, "w") as tar:
        for name in ("install.sh", "lib", "manifest", "test"):
            src = REPO / name
            if src.exists():
                tar.add(src, arcname=name)
    log(f"packed working tree -> {tar_path} ({tar_path.stat().st_size} bytes)")

    def handler(*a, **kw):
        return http.server.SimpleHTTPRequestHandler(*a, directory=str(VMRUN), **kw)

    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    httpd.allow_reuse_address = True
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"serving {VMRUN} on host port {port} (guest sees 10.0.2.2:{port})")
    return port, httpd


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
        """Append to the match buffer with ANSI removed.

        A sequence can be split across two recv() calls, so a trailing partial
        escape is held back rather than being stripped incorrectly.
        """
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
        """Wait for whichever of several markers appears first.

        Returns (matched_needle, text). Used at boot, where the guest may
        present either a login prompt or an already-logged-in shell.
        """
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

        Two subtleties:

        * A unique sentinel per call stops a slow command's output being
          mistaken for the next command's completion.
        * The serial console ECHOES what we type. If the sentinel appeared
          literally in the command line, read_until would match the echo
          rather than the result and every command would report status 1.
          Splitting it across a concatenation makes the echoed form
          ('AWDN""123:$?') differ from the printed form ('AWDN123:0').
        """
        head, tail = "AWDN", str(int(time.time() * 1000) % 1000000)
        marker = f"{head}{tail}:"
        self.send(f'{cmd}; echo "{head}""{tail}:$?"')
        # Everything up to the marker is the command's own output; the marker
        # is followed by the exit status and a newline.
        out = self.read_until(marker, timeout)
        status = self.read_until("\n", 30).strip()
        try:
            return int(status), out
        except ValueError:
            return 1, out

    def run_checked(self, cmd, timeout=600):
        rc, out = self.run(cmd, timeout)
        if rc != 0:
            die(f"guest command failed (status {rc}): {cmd}")
        return out


def fresh_run_dir(size="20G"):
    if VMRUN.exists():
        shutil.rmtree(VMRUN)
    VMRUN.mkdir(parents=True)
    shutil.copy(_first_existing(OVMF_VARS_CANDIDATES, "OVMF vars template",
                                "ARCHWRIGHT_OVMF_VARS"),
                VMRUN / "OVMF_VARS.fd")
    disk = VMRUN / "disk.qcow2"
    subprocess.check_call([qemu_img(), "create", "-f", "qcow2", str(disk), size],
                          stdout=subprocess.DEVNULL)
    log(f"fresh run dir {VMRUN} (disk {size}, own copy of OVMF vars)")
    return disk


def start_qemu(disk, serial_port, iso_boot=True):
    code = _first_existing(OVMF_CODE_CANDIDATES, "OVMF firmware", "ARCHWRIGHT_OVMF_CODE")
    acc = accel()
    args = [
        qemu_binary(),
        "-machine", f"q35,accel={acc}",
        "-cpu", "host" if acc == "kvm" else "qemu64",
        "-m", "4096", "-smp", "2",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={VMRUN / 'OVMF_VARS.fd'}",
        "-drive", f"file={disk},if=virtio,format=qcow2",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-serial", f"tcp:127.0.0.1:{serial_port},server=on,wait=off",
        "-display", "none",
    ]
    if iso_boot:
        if not ISO.is_file():
            die(f"{ISO} missing: run tools/fetch-arch-iso.sh")
        label_file = BOOT / "archisolabel.txt"
        if not label_file.is_file():
            die(f"{label_file} missing: run tools/extract-iso-boot.sh")
        label = label_file.read_text().strip()
        args += [
            "-cdrom", str(ISO),
            "-kernel", str(BOOT / "vmlinuz-linux"),
            "-initrd", str(BOOT / "initramfs-linux.img"),
            "-append", f"archisobasedir=arch archisolabel={label} console=ttyS0,115200",
        ]
    log(f"launching qemu (accel={acc}, iso_boot={iso_boot})")
    return subprocess.Popen(args)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_live_shell(ser):
    """Get to a usable root shell in the live environment.

    archiso autologins root on tty1, but serial-getty@ttyS0 presents an
    ordinary login prompt. Root has no password on the official medium, so
    answering it is enough. Both shapes are handled rather than assuming one,
    since the ISO's getty configuration is not ours to control.
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


def guest_fetch_repo(ser, port):
    rc, _ = ser.run(f"curl -fsS -o /tmp/repo.tar http://10.0.2.2:{port}/repo.tar", 180)
    if rc != 0:
        die("guest could not fetch the repo tarball from the host")
    rc, _ = ser.run("mkdir -p /root/archwright && tar -xf /tmp/repo.tar -C /root/archwright", 120)
    if rc != 0:
        die("guest could not unpack the repo tarball")
    log("working tree delivered to the guest at /root/archwright")


def phase_iso_smoke():
    """Prove the harness can boot a guest and run commands in it.

    This exists so later failures can be attributed to the installer rather
    than to the harness.
    """
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        log("waiting for the live environment ...")
        wait_for_live_shell(ser)

        rc, _ = ser.run("test -d /sys/firmware/efi", 60)
        if rc != 0:
            die("guest did not boot in UEFI mode - Archwright is UEFI-only")
        log("confirmed: guest booted in UEFI mode")

        guest_fetch_repo(ser, port)

        rc, _ = ser.run("bash /root/archwright/test/run-unit.sh", 300)
        if rc != 0:
            die("unit tests failed inside the guest")
        log("confirmed: unit suite passes inside the guest")

        log("PASS: harness can boot UEFI, log in, deliver the tree and run it")
    finally:
        httpd.shutdown()
        proc.kill()


ANSWERS = "/root/archwright/test/vm/answers.example.conf"


def run_installer(ser, phase, timeout=1800, answers=ANSWERS):
    return ser.run(
        f"bash /root/archwright/install.sh --answers {answers} --phase {phase} --yes",
        timeout)


def boot_live(stack):
    """Boot the ISO, log in, deliver the tree. Returns (ser, port)."""
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    stack.append(httpd.shutdown)
    stack.append(proc.kill)
    ser = Serial(sport)
    wait_for_live_shell(ser)
    guest_fetch_repo(ser, port)
    return ser, port, disk


def phase_preflight():
    stack = []
    try:
        ser, _, _ = boot_live(stack)

        rc, _ = run_installer(ser, "preflight", 300)
        if rc != 0:
            die(f"preflight failed with status {rc}")
        log("confirmed: preflight succeeds on a valid target")

        # A preflight that passes on garbage is worse than no preflight, so
        # assert the refusals too rather than only the happy path.
        refusals = [
            ("DISK=/dev/does-not-exist", "not a block device"),
            ("DISK=/dev/vda1", "partition"),
            ("DISK=/dev/vda; rm -rf /", "invalid"),
            ("HOSTNAME=", "required"),
        ]
        for override, expected in refusals:
            ser.run(f"sed 's|^DISK=.*|DISK=/dev/vda|' {ANSWERS} > /tmp/bad.conf", 60)
            key = override.split("=", 1)[0]
            ser.run(f"sed -i '/^{key}=/d' /tmp/bad.conf && echo '{override}' >> /tmp/bad.conf", 60)
            rc, out = run_installer(ser, "preflight", 300, answers="/tmp/bad.conf")
            if rc == 0:
                die(f"preflight ACCEPTED a bad answer file ({override!r}) - it must refuse")
            if expected not in out:
                log(f"  note: refused {override!r} but the message did not mention {expected!r}")
            else:
                log(f"  confirmed: refused {override!r}")

        log("PASS: preflight accepts a valid target and refuses invalid ones")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


def check_guest(ser, checks, what):
    for cmd, expect in checks:
        rc, out = ser.run(cmd, 120)
        if rc != 0 or expect not in out:
            die(f"{what} check failed: {cmd!r} did not yield {expect!r} (status {rc})")
        log(f"  ok: {expect}")


def phase_disk():
    stack = []
    try:
        ser, _, _ = boot_live(stack)
        for phase in ("preflight", "disk"):
            rc, _ = run_installer(ser, phase, 900)
            if rc != 0:
                die(f"phase {phase} failed with status {rc}")

        check_guest(ser, [
            ("findmnt -no FSTYPE /mnt", "btrfs"),
            ("findmnt -no OPTIONS /mnt | tr ',' '\\n' | grep '^subvol=/@$'", "subvol=/@"),
            ("findmnt -no FSTYPE /mnt/boot", "vfat"),
            ("findmnt -no TARGET /mnt/home", "/mnt/home"),
            ("findmnt -no TARGET /mnt/.snapshots", "/mnt/.snapshots"),
            ("findmnt -no TARGET /mnt/var/log", "/mnt/var/log"),
            ("cryptsetup status cryptroot | head -1", "is active"),
            ("cryptsetup luksDump /dev/vda2 | awk '/^Version:/{print $2}'", "2"),
            ("parted -ms /dev/vda print | awk -F: 'NR==2{print $6}'", "gpt"),
            ("parted -ms /dev/vda print | grep -c '^[0-9]*:'", "2"),
        ], "disk")
        log("PASS: GPT + ESP + LUKS2 + btrfs subvolumes are correct")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


PHASES = {
    "iso-smoke": phase_iso_smoke,
    "preflight": phase_preflight,
    "disk": phase_disk,
}


def main():
    ap = argparse.ArgumentParser(description="Archwright VM oracle")
    ap.add_argument("--phase", default="iso-smoke", choices=sorted(PHASES))
    args = ap.parse_args()
    try:
        PHASES[args.phase]()
    except TimeoutError as exc:
        die(str(exc))


if __name__ == "__main__":
    main()
