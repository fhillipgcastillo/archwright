#!/usr/bin/env python3
"""QEMU/WHPX plumbing shared by the Windows-host probes.

Standalone by design: shares no code with test/vm/drive_vm.py.
"""

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
CACHE = pathlib.Path(os.environ.get(
    "ARCHWRIGHT_WIN_CACHE", pathlib.Path.home() / ".cache" / "archwright-win"))
ISO = CACHE / "archlinux.iso"
BOOT = CACHE / "boot"
RUN = CACHE / "probe-run"

SERVE_EXCLUDE = {"docs", "__pycache__"}

# Any AVX-class feature is accepted at launch and then panics the guest kernel
# at ~0.25s in fpstate_reset. Do not widen without a guest that boots to prove it.
CPU = "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes"

BOOT_TIMEOUT = 420
POWEROFF_WAIT = 180

LIVE_PROMPT = "root@archiso ~ #"
LIVE_LOGIN = "archiso login:"

# The prompt is colourised, so matching runs against an ANSI-stripped copy.
_ANSI = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|\x1b\[[0-9;?]*[ -/]*[@-~]"
    r"|\x1b[()][0-9A-Za-z]"
    r"|\x1b[@-Z\\-_]"
)
_ESC_TAIL = re.compile(r"\x1b(?:[\[\]()][0-9;?]*)?$")


def use_utf8_stdout():
    """Windows Python defaults to cp1252, which cannot encode U+FFFD."""
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


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
        # An escape sequence can straddle two recv() calls; hold back a partial.
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
        """Run a command in the guest; return (exit_status, output)."""
        # The sentinel is unique per call, and split across a concatenation so
        # the console's echo of the command cannot match it.
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
        die("qemu-system-x86_64 not found. Set ARCHWRIGHT_QEMU to its full path.")
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
    """Return (code, vars) from QEMU's own share/, not a fixed path list."""
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


def require_cache():
    for path in (ISO, BOOT / "vmlinuz-linux", BOOT / "initramfs-linux.img",
                 BOOT / "archisolabel.txt"):
        if not path.is_file():
            die(f"missing {path}. Populate {CACHE} first.")


def fresh_run_dir(size="20G"):
    if RUN.exists():
        shutil.rmtree(RUN)
    RUN.mkdir(parents=True)
    _, varsf = firmware()
    shutil.copy(varsf, RUN / "OVMF_VARS.fd")
    disk = RUN / "disk.qcow2"
    subprocess.check_call([qemu_img(), "create", "-f", "qcow2", str(disk), size],
                          stdout=subprocess.DEVNULL)
    log(f"fresh run dir {RUN} (dynamic qcow2 {size}, own copy of the OVMF vars)")
    return disk


def start_qemu(disk, serial_port, iso_boot=True):
    """Launch QEMU under WHPX with the gate's device set, minus the 9p share."""
    code, _ = firmware()
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
    ]
    if iso_boot:
        label = (BOOT / "archisolabel.txt").read_text().strip()
        args += [
            "-cdrom", str(ISO),
            "-kernel", str(BOOT / "vmlinuz-linux"),
            "-initrd", str(BOOT / "initramfs-linux.img"),
            "-append",
            f"archisobasedir=arch archisolabel={label} console=ttyS0,115200",
        ]
    log(f"launching qemu (accel=whpx, iso_boot={iso_boot})")
    return subprocess.Popen(args)


def serve_repo():
    """Pack the working tree and serve it on loopback. Returns (port, httpd)."""
    RUN.mkdir(parents=True, exist_ok=True)
    tar_path = RUN / "repo.tar"
    with tarfile.open(tar_path, "w") as tar:
        for entry in sorted(REPO.iterdir()):
            if entry.name.startswith(".") or entry.name in SERVE_EXCLUDE:
                continue
            tar.add(entry, arcname=entry.name)
    shutil.copy(REPO / "test" / "vm" / "assertions.sh", RUN / "assertions.sh")
    log(f"packed working tree -> {tar_path} ({tar_path.stat().st_size} bytes)")

    def handler(*a, **kw):
        return http.server.SimpleHTTPRequestHandler(*a, directory=str(RUN), **kw)

    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    httpd.allow_reuse_address = True
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"serving {RUN} on host port {port} (guest sees 10.0.2.2:{port})")
    return port, httpd


def wait_for_live_shell(ser):
    """archiso autologins on tty1 but serial-getty presents a login prompt."""
    marker, _ = ser.read_until_any([LIVE_LOGIN, LIVE_PROMPT], BOOT_TIMEOUT)
    if marker == LIVE_LOGIN:
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


def poweroff_and_wait(ser, proc):
    """Send the gate's poweroff line. Returns (wedged, seconds, exit_code)."""
    t0 = time.time()
    ser.send("sync; systemctl poweroff -i")
    try:
        proc.wait(timeout=POWEROFF_WAIT)
        return False, round(time.time() - t0, 1), proc.returncode
    except subprocess.TimeoutExpired:
        log(f"WEDGE: QEMU still alive {POWEROFF_WAIT}s after poweroff; force-killing")
        proc.kill()
        proc.wait(timeout=30)
        return True, None, None
