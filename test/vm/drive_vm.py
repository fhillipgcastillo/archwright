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
# Survives across runs, unlike VMRUN which is wiped every time. Shared into
# the guest over 9p so pacstrap reads packages from local disk instead of
# re-downloading ~500MB of Arch mirrors on every single run.
PKGCACHE = CACHE / "pkgcache"
# A passing gate's disk is archived here so there is always a bootable,
# known-good image to look at. VMRUN is wiped at the start of every run, which
# previously meant starting a test destroyed the very thing you wanted to boot.
LASTGOOD = CACHE / "last-good"

# Not shipped into the guest: documentation and local build artifacts. Anything
# else in the repo root goes, so a new directory the installer reads does not
# need this file edited to reach the VM.
SERVE_EXCLUDE = {"docs", "__pycache__"}

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
    # Pack everything except the excluded set, rather than an allowlist of
    # directories. An allowlist silently omitted bin/ once (L15) and config/
    # once, each time producing a failure several layers away from the cause.
    # Adding a new top-level directory should not require remembering this.
    with tarfile.open(tar_path, "w") as tar:
        for entry in sorted(REPO.iterdir()):
            if entry.name.startswith(".") or entry.name in SERVE_EXCLUDE:
                continue
            tar.add(entry, arcname=entry.name)
    # Also served standalone: the installed system fetches this directly
    # rather than unpacking the whole tree just to run one script.
    shutil.copy(REPO / "test" / "vm" / "assertions.sh", VMRUN / "assertions.sh")
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

        That applies to a partial OSC BODY too, not just a partial escape
        introducer. An OSC is `ESC ] text BEL-or-ST`, and sudo emits a long one
        per session on systemd 257 - a hundred-odd characters of user,
        hostname, machine id and pid. Split one across two reads and _ANSI sees
        an ESC ] with no terminator, strips nothing, and the next pass sees a
        body with no ESC and strips nothing again: the whole thing lands in the
        transcript as `3008;start=...;type=session`. Holding back from the last
        unterminated `ESC ]` costs one read of latency and removes the only
        source of junk in an otherwise clean capture.
        """
        data = self._pending + chunk
        self._pending = ""
        start = data.rfind("\x1b]")
        if start != -1:
            rest = data[start:]
            if "\x07" not in rest and "\x1b\\" not in rest[2:]:
                self._pending = rest
                data = data[:start]
        m = _ESC_TAIL.search(data)
        if m:
            self._pending = data[m.start():] + self._pending
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
    PKGCACHE.mkdir(parents=True, exist_ok=True)
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
        # One GPU that is BOTH VGA-compatible and virtio-gpu.
        #
        # QEMU's default bochs display gives a card and a connected connector
        # but NO render node, which is what EGL/GBM needs - Hyprland would
        # silently software-render and the harness would be testing a path no
        # real machine takes. Plain `-vga none -device virtio-gpu-pci` fixes
        # that but removes the only framebuffer firmware and the bootloader
        # know how to draw on, so nothing is visible until Linux loads
        # virtio_gpu.
        #
        # virtio-vga is a single device that is both: firmware and Limine
        # paint normally, Linux still gets renderD128, and there is still
        # exactly one card and one connector. It is also closer to real
        # hardware, which does show you boot output on the screen.
        "-device", "virtio-vga",
        # A sound card with the output discarded. The gate cannot listen to
        # anything, but without a card the guest has no audio hardware at all -
        # and "pipewire is running" was the only thing ever asserted about
        # audio, which is a process check, not a sound. With a card present the
        # gate can assert a sink exists and that something played to it.
        "-audiodev", "none,id=snd0",
        "-device", "intel-hda",
        "-device", "hda-duplex,audiodev=snd0",
        # Persistent pacman cache, shared read-write from the host. security_model
        # =none keeps ownership as the host user rather than trying to map
        # guest uids, which is what we want for a plain package cache.
        "-fsdev", f"local,id=pkgcache,path={PKGCACHE},security_model=none",
        "-device", "virtio-9p-pci,fsdev=pkgcache,mount_tag=awpkgcache",
        "-display", "none",
    ]
    extra = os.environ.get("AW_EXTRA_QEMU_ARGS", "").split()
    if extra:
        log(f"extra qemu args: {extra}")
        args += extra
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
    mount_pkg_cache(ser)


def mount_pkg_cache(ser):
    """Mount the host's pacman cache over the live environment's own.

    Not fatal if it fails: the install still works, just slowly. Losing an
    optimisation should never turn into a failed test run.
    """
    rc, _ = ser.run(
        "mkdir -p /var/cache/pacman/pkg && "
        "mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 "
        "awpkgcache /var/cache/pacman/pkg", 120)
    if rc != 0:
        log("WARNING: could not mount the host package cache; "
            "packages will be re-downloaded")
        return False
    _, out = ser.run("ls /var/cache/pacman/pkg | wc -l", 60)
    # The output carries the echoed command and the sentinel too, so pick the
    # last purely numeric line rather than assuming a position.
    counts = [ln.strip() for ln in out.splitlines() if ln.strip().isdigit()]
    log(f"host package cache mounted ({counts[-1] if counts else '?'} cached files)")
    return True


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
        f"bash /root/archwright/install.sh --answers {answers} --phase {phase}"
        f" --yes --host-pkg-cache",
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


def phase_base():
    stack = []
    try:
        ser, _, _ = boot_live(stack)
        for phase, timeout in (("preflight", 300), ("disk", 900), ("base", 2400)):
            rc, _ = run_installer(ser, phase, timeout)
            if rc != 0:
                die(f"phase {phase} failed with status {rc}")

        check_guest(ser, [
            # Assert the property, not a line count: genfstab writes one entry
            # per mounted subvolume, and 'subvol=/@' is a substring of
            # 'subvol=/@home'. What matters is that / is mounted from @.
            ("awk '$2==\"/\" && $4 ~ /(^|,)subvol=\\/@(,|$)/ {f=1}"
             " END {if (f) print \"ROOTFSTAB-OK\"}' /mnt/etc/fstab", "ROOTFSTAB-OK"),
            ("awk '$2==\"/home\" {f=1} END {if (f) print \"HOMEFSTAB-OK\"}' /mnt/etc/fstab",
             "HOMEFSTAB-OK"),
            ("awk '$2==\"/boot\" && $3==\"vfat\" {f=1}"
             " END {if (f) print \"ESPFSTAB-OK\"}' /mnt/etc/fstab", "ESPFSTAB-OK"),
            ("cat /mnt/etc/hostname", "archwright-vm"),
            ("cat /mnt/etc/locale.conf", "en_US.UTF-8"),
            ("arch-chroot /mnt id -u test >/dev/null && echo USER-OK", "USER-OK"),
            ("test -d /mnt/home/test && echo HOME-OK", "HOME-OK"),
            # Proves /etc/skel was populated BEFORE useradd ran. If skeleton
            # seeding ever drifts below useradd, this is what catches it.
            ("test -d /mnt/home/test/.local/state/archwright && echo SKEL-OK", "SKEL-OK"),
            ("arch-chroot /mnt id -nG test", "wheel"),
            ("arch-chroot /mnt systemctl is-enabled NetworkManager.service", "enabled"),
            ("arch-chroot /mnt systemctl is-enabled ufw.service", "enabled"),
            ("grep '^DEFAULT_INPUT_POLICY=' /mnt/etc/default/ufw", "DROP"),
            ("grep '^DEFAULT_OUTPUT_POLICY=' /mnt/etc/default/ufw", "ACCEPT"),
            ("grep '^ENABLED=' /mnt/etc/ufw/ufw.conf", "yes"),
            # sshd must NOT be enabled: a base install should not start
            # listening on the network without being asked.
            ("arch-chroot /mnt systemctl is-enabled sshd.service || true", "disabled"),
            # `systemctl is-enabled` exits non-zero for a masked unit even
            # while printing 'masked', so this one is asserted on output only.
            ("arch-chroot /mnt systemctl is-enabled NetworkManager-wait-online.service"
             " || true", "masked"),
            ("cat /mnt/usr/share/archwright/VERSION", "milestone-1"),
            ("arch-chroot /mnt pacman -Q linux >/dev/null && echo KERNEL-OK", "KERNEL-OK"),
            ("arch-chroot /mnt pacman -Q limine >/dev/null && echo LIMINE-OK", "LIMINE-OK"),
            ("arch-chroot /mnt pacman -Q snapper >/dev/null && echo SNAPPER-OK", "SNAPPER-OK"),
        ], "base")
        log("PASS: base system installed and configured")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


def phase_boot():
    """Install through the boot phase and inspect the target, without rebooting.

    Much faster to iterate on than the full gate: it skips the second boot,
    which is the slow part, while still exercising everything that writes the
    bootloader, the UKI and the snapper configuration.
    """
    stack = []
    try:
        ser, _, _ = boot_live(stack)
        for phase, timeout in (("preflight", 300), ("disk", 900),
                               ("base", 2400), ("boot", 2400), ("theme", 600),
                               ("session", 1200), ("shell", 900),
                               ("apps", 1800), ("ai", 900),
                               ("hardware", 900)):
            rc, _ = run_installer(ser, phase, timeout)
            if rc != 0:
                die(f"phase {phase} failed with status {rc}")

        check_guest(ser, [
            ("ls /mnt/boot/vmlinuz-linux >/dev/null && echo KERNEL-OK", "KERNEL-OK"),
            ("ls /mnt/boot/initramfs-linux.img >/dev/null && echo INITRAMFS-OK",
             "INITRAMFS-OK"),
            ("test -f /mnt/boot/EFI/BOOT/BOOTX64.EFI && echo LIMINE-EFI-OK",
             "LIMINE-EFI-OK"),
            ("test -f /mnt/boot/limine.conf && echo LIMINECONF-OK", "LIMINECONF-OK"),
            ("grep -c 'rd.luks.name' /mnt/etc/archwright/cmdline", "1"),
            ("grep -c 'protocol: linux' /mnt/boot/limine.conf", "2"),
            ("grep -c 'rootflags=subvol=@snapshots/' /mnt/boot/limine.conf", "1"),
            ("test -f /mnt/etc/snapper/configs/root && echo SNAPPERCFG-OK",
             "SNAPPERCFG-OK"),
            ("arch-chroot /mnt snapper --no-dbus -c root list"
             " | grep -cE '^[[:space:]]*[1-9]'", "1"),
            ("mountpoint -q /mnt/.snapshots && echo SNAPMOUNT-OK", "SNAPMOUNT-OK"),
            # Tested INSIDE the chroot: the symlink target is absolute, so from
            # the host it resolves against the host root and looks broken even
            # when it is correct in the target.
            ("arch-chroot /mnt test -x /usr/bin/archwright-limine-update && echo CLI-OK", "CLI-OK"),
            # --- session phase ---
            ("arch-chroot /mnt systemctl is-enabled greetd.service", "enabled"),
            ("grep -c 'tuigreet' /mnt/etc/greetd/config.toml", "1"),
            ("grep -c 'initial_session' /mnt/etc/greetd/config.toml", "1"),
            ("test -f /mnt/usr/share/wayland-sessions/hyprland.desktop && echo SESSDESK-OK",
             "SESSDESK-OK"),
            ("test -f /mnt/home/test/.config/hypr/hyprland.conf && echo HYPRCFG-OK",
             "HYPRCFG-OK"),
            ("test -f /mnt/home/test/.config/foot/foot.ini && echo FOOTCFG-OK",
             "FOOTCFG-OK"),
            ("test -f /mnt/usr/share/archwright/default-config/hypr/hyprland.conf"
             " && echo DEFAULTS-OK", "DEFAULTS-OK"),
            ("stat -c %U /mnt/home/test/.config/hypr/hyprland.conf", "test"),
            # --- shell phase ---
            ("test -f /mnt/etc/systemd/user/archwright-shell.target && echo TARGET-OK",
             "TARGET-OK"),
            ("ls /mnt/etc/systemd/user/archwright-shell.target.wants/ | wc -l", "5"),
            # A .wants symlink starts a unit but does NOT stop it with the
            # target. PartOf, via a drop-in, is what makes the boundary work in
            # both directions.
            ("ls -d /mnt/etc/systemd/user/*.service.d 2>/dev/null | wc -l", "4"),
            ("grep -l 'PartOf=archwright-shell.target'"
             " /mnt/etc/systemd/user/*.service.d/*.conf | wc -l", "4"),
            ("test -f /mnt/home/test/.config/waybar/config.jsonc && echo WAYBAR-OK",
             "WAYBAR-OK"),
            ("test -f /mnt/home/test/.config/mako/config && echo MAKO-OK", "MAKO-OK"),
            ("test -f /mnt/home/test/.config/hypr/shell.conf && echo SHELLCONF-OK",
             "SHELLCONF-OK"),
            ("grep -c 'archwright-shell.target' /mnt/home/test/.config/hypr/shell.conf",
             "1"),
            ("stat -c %U /mnt/home/test/.config/waybar/config.jsonc", "test"),
            ("grep -c '\"on-click\": \"fuzzel\"'"
             " /mnt/home/test/.config/waybar/config.jsonc", "1"),
            # --- apps phase ---
            ("test -f /mnt/etc/xdg/mimeapps.list && echo MIME-OK", "MIME-OK"),
            ("arch-chroot /mnt pacman -Q firefox >/dev/null && echo FF-OK", "FF-OK"),
            ("arch-chroot /mnt pacman -Q docker >/dev/null && echo DOCKER-OK",
             "DOCKER-OK"),
            # Not selected, so it must be ABSENT. This is what proves the
            # selection is real rather than 'install everything'.
            ("arch-chroot /mnt pacman -Q libreoffice-fresh >/dev/null 2>&1"
             " && echo PRESENT || echo ABSENT", "ABSENT"),
            ("grep -c '^.multilib.' /mnt/etc/pacman.conf || true", "0"),
        ], "boot")
        log("PASS: bootloader, initramfs and snapper are configured in the target")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


def archive_last_good(disk):
    """Keep a copy of the disk from the most recent PASSING run.

    VMRUN is destroyed at the start of every run, so without this, kicking off
    a test deletes the image you wanted to inspect - which is exactly what
    happened once and cost a confusing debugging session.
    """
    try:
        LASTGOOD.mkdir(parents=True, exist_ok=True)
        for name in ("disk.qcow2", "OVMF_VARS.fd"):
            src = VMRUN / name
            if src.exists():
                shutil.copy2(src, LASTGOOD / name)
        log(f"archived a known-good image to {LASTGOOD}")
    except OSError as exc:
        log(f"WARNING: could not archive the disk: {exc}")


def phase_resume():
    """Prove an interrupted install can continue instead of starting over.

    Installs up to and including `base` - the expensive phase - then simulates
    an interruption by tearing the mounts down and discarding /run, which is
    what a reboot would do. A resumed run must then skip disk and base and
    finish the rest.
    """
    stack = []
    try:
        ser, _, _ = boot_live(stack)
        for phase, timeout in (("preflight", 300), ("disk", 900), ("base", 2400)):
            rc, _ = run_installer(ser, phase, timeout)
            if rc != 0:
                die(f"phase {phase} failed with status {rc}")

        rc, out = ser.run("cat /mnt/boot/archwright/install-state", 60)
        if "disk" not in out or "base" not in out:
            die(f"install state does not record the finished phases: {out!r}")
        log("state file records disk and base")

        # Simulate the interruption: everything /run held is gone, nothing is
        # mounted, the container is closed. Exactly the state after a reboot.
        log("simulating an interruption (unmount, close LUKS, discard /run state)")
        ser.run("umount -R /mnt", 120)
        ser.run("cryptsetup close cryptroot", 60)
        ser.run("rm -rf /run/archwright", 60)
        rc, out = ser.run("mountpoint -q /mnt && echo STILL-MOUNTED || echo CLEAN", 60)
        if "CLEAN" not in out:
            die("could not tear the mounts down to simulate an interruption")

        log("resuming ...")
        rc, out = ser.run(
            "bash /root/archwright/install.sh"
            f" --answers {ANSWERS} --yes --host-pkg-cache --resume", 2400)
        if rc != 0:
            die(f"resumed install failed with status {rc}")

        for phase in ("disk", "base"):
            if f"phase: {phase} (already done, skipping)" not in out:
                die(f"resume did not skip the completed '{phase}' phase")
        log("resume skipped disk and base")
        for phase in ("boot", "session", "shell"):
            if f"=== phase: {phase} ===" not in out:
                die(f"resume did not run the remaining '{phase}' phase")
        log("resume ran boot, session and shell")

        check_guest(ser, [
            ("cat /mnt/boot/archwright/install-state | tr '\n' ' '", "shell"),
            ("test -f /mnt/boot/limine.conf && echo LIMINE-OK", "LIMINE-OK"),
            ("test -f /mnt/etc/systemd/user/archwright-shell.target && echo SHELL-OK",
             "SHELL-OK"),
        ], "resume")

        # Refusing to adopt a disk that is not ours is the safety property that
        # makes --resume acceptable at all.
        rc, out = ser.run("umount -R /mnt; cryptsetup close cryptroot;"
                          " rm -rf /run/archwright;"
                          " mount /dev/vda1 /tmp/esp2 2>/dev/null || "
                          " { mkdir -p /tmp/esp2 && mount /dev/vda1 /tmp/esp2; };"
                          " mv /tmp/esp2/archwright /tmp/esp2/archwright.hidden;"
                          " umount /tmp/esp2", 120)
        rc, out = ser.run(
            "bash /root/archwright/install.sh"
            f" --answers {ANSWERS} --yes --resume 2>&1 | tail -3", 300)
        if "refusing to touch this disk" not in out:
            die("resume adopted a disk with no Archwright state - the safety "
                f"check did not fire. Output: {out[-400:]!r}")
        log("resume correctly refused a disk with no Archwright state")

        log("PASS: an interrupted install resumes, and refuses unknown disks")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


def phase_all():
    """The full gate: install, reboot, unlock, log in, assert everything."""
    disk = fresh_run_dir()
    port, httpd = serve_repo()
    proc = None
    proc2 = None
    try:
        # ---- install, from the live ISO ----
        sport = free_port()
        proc = start_qemu(disk, sport)
        ser = Serial(sport)
        wait_for_live_shell(ser)
        guest_fetch_repo(ser, port)
        for phase, timeout in (("preflight", 300), ("disk", 900),
                               ("base", 2400), ("boot", 2400), ("theme", 600),
                               ("session", 1200), ("shell", 900),
                               ("apps", 1800), ("ai", 900),
                               ("hardware", 900)):
            rc, _ = run_installer(ser, phase, timeout)
            if rc != 0:
                die(f"install phase {phase} failed with status {rc}")
        log("install complete; powering down the live environment")
        ser.send("sync; systemctl poweroff -i")
        try:
            proc.wait(timeout=180)
        except subprocess.TimeoutExpired:
            log("live environment did not power off in time; killing it")
            proc.kill()
        proc = None

        # ---- boot what we just installed ----
        # Same disk, same OVMF vars (so the NVRAM entry written during install
        # is present), and no ISO: nothing to fall back on.
        log("booting the installed system from disk")
        sport = free_port()
        proc2 = start_qemu(disk, sport, iso_boot=False)
        ser = Serial(sport)

        log("gate 2: waiting for the LUKS passphrase prompt")
        ser.read_until("passphrase", BOOT_TIMEOUT)
        ser.send("testpassphrase")
        log("gate 2 met: passphrase prompt appeared and was answered")

        log("gate 3: waiting for a login prompt")
        ser.read_until("login:", BOOT_TIMEOUT)
        ser.send("test")
        ser.read_until("Password:", 120)
        ser.send("testpassword")
        ser.read_until("@archwright-vm", 120)
        rc, _ = ser.run("true", 60)
        if rc != 0:
            die("logged in but could not run a command")
        log("gate 3 met: the installed system booted and accepted a login")

        # NetworkManager needs a moment for DHCP; retry rather than assume.
        rc, _ = ser.run(
            f"for i in $(seq 1 30); do "
            f"curl -fsS -o /tmp/assertions.sh http://10.0.2.2:{port}/assertions.sh "
            f"&& break; sleep 2; done; test -s /tmp/assertions.sh", 120)
        if rc != 0:
            die("could not fetch the assertion script into the installed system")

        rc, out = ser.run(
            # Generous, and deliberately so. The milestone 5 assertions do two
            # slow things on purpose: one stub resolves its package for real
            # over the network, and the sudo window is waited out rather than
            # inspected, because auto-revert is the property that makes it
            # safe to ship.
            "echo testpassword | sudo -S bash /tmp/assertions.sh 2>&1", 900)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith(("ok ", "FAIL", "  ")) or "ASSERTIONS" in line:
                log(f"  {line}")
        if "ASSERTIONS-PASSED" not in out:
            die("installed-system assertions failed - see the report above")

        log("PASS: gate met - encrypted base, desktop, shell layer, applications, AI layer")
        archive_last_good(disk)
    finally:
        for p in (proc, proc2):
            if p is not None:
                try:
                    p.kill()
                except Exception:
                    pass
        try:
            httpd.shutdown()
        except Exception:
            pass


def phase_probe_gpu():
    """Report what graphics hardware a guest actually sees in this harness.

    Hyprland needs a DRM device with a connected output. Whether QEMU provides
    one with -display none is the question that decides milestone 2's shape,
    and it is cheaper to answer than to assume.
    """
    stack = []
    try:
        ser, _, _ = boot_live(stack)
        for label, cmd in [
            ("PCI display devices", "lspci | grep -i -E 'vga|display|gpu' || echo none"),
            ("/dev/dri contents", "ls -l /dev/dri 2>&1 || echo none"),
            ("loaded drm modules", "lsmod | grep -E '^(virtio_gpu|bochs|drm)' || echo none"),
            ("DRM connectors", "for c in /sys/class/drm/*/status; do "
                               "echo \"$c=$(cat $c)\"; done 2>/dev/null || echo none"),
            ("a drm card exists", "ls /dev/dri/card* >/dev/null 2>&1 && echo CARD-YES || echo CARD-NO"),
            ("a render node exists", "ls /dev/dri/renderD* >/dev/null 2>&1 && echo RENDER-YES || echo RENDER-NO"),
        ]:
            _, out = ser.run(cmd, 60)
            log(f"--- {label} ---")
            for line in out.splitlines():
                line = line.strip()
                if line and not line.startswith(("root@", "#")):
                    log(f"    {line}")
        log("PASS: probe complete - read the output above")
    finally:
        for fn in reversed(stack):
            try:
                fn()
            except Exception:
                pass


PHASES = {
    "iso-smoke": phase_iso_smoke,
    "probe-gpu": phase_probe_gpu,
    "preflight": phase_preflight,
    "disk": phase_disk,
    "base": phase_base,
    "boot": phase_boot,
    "resume": phase_resume,
    "all": phase_all,
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
