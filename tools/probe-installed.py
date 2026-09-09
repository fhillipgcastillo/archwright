#!/usr/bin/env python3
"""Ask the installed system a question, without reinstalling it.

THE PROBLEM THIS SOLVES

There were two ways to look at an Archwright system and a large gap between
them. `test/vm-install.sh --phase all` installs from a stock ISO and runs the
whole gate: an hour, and the right tool when the question is "did I break the
install". `tools/boot-installed.sh` opens a window on the last passing image:
immediate, and the right tool when the question is "how does this look".

Neither answers "does the compositor accept this config line", "which
namespace does mako register", "do these pixels change". Those are two-minute
questions that cost an hour through the gate, and an hour is expensive enough
that the honest answer gets replaced by a guess written from memory. A line
guessed that way is what painted six config errors across the desktop in
milestone 6.

So: boot the archived image headless, run a script inside it, print what it
said, exit with its status. Four to five minutes.

WHAT IT IS NOT

Not a gate. Nothing here asserts anything; it reports. A probe that passes
proves the guest answered, not that Archwright is correct - `test/vm-install.sh
--phase all` remains the oracle.

Not real hardware either. It answers "what does this software do", never "what
does this laptop do".

THE DISK IS NEVER WRITTEN

QEMU runs with -snapshot and the firmware vars are a throwaway copy, so the
archived image is exactly as it was when the probe exits, however badly the
script inside it behaved. There is deliberately no --write: the archive is what
`boot-installed.sh` shows you and what the next probe starts from.

CARRYING A CHANGE IN

The image is whatever the last passing run installed, so it does NOT contain
your uncommitted work. Send the file with the probe:

    tools/probe-installed.py --file config/hypr/hyprland.conf:/home/test/.config/hypr/hyprland.conf \\
        -c 'runuser -u test -- hyprctl reload; runuser -u test -- hyprctl configerrors'

That is how a config file added today gets tested inside a system installed
last week.

EXAMPLES

    # a one-liner
    tools/probe-installed.py -c 'aw version; hyprctl version | head -1'

    # a script, with a file it needs
    tools/probe-installed.py probe.sh --file manifest/palettes/latte.palette

Must run inside Linux with KVM (WSL2 on this machine), like the rest of the VM
tooling - see D13 in docs/decisions.md.
"""
import argparse
import http.server
import pathlib
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "test" / "vm"))
import drive_vm as D  # noqa: E402  (path has to be set first)

DEFAULT_ANSWERS = REPO / "test" / "vm" / "answers.example.conf"
GUEST_DIR = "/tmp/probe"
BEGIN = "AW-PROBE-BEGIN"
END = "AW-PROBE-END:"


def guest(ser, cmd, timeout=600):
    """Like drive_vm's Serial.run, but silent.

    Serial.run echoes everything it reads to stdout, which is right for a gate
    transcript and wrong here: this tool's output IS the guest's output, and
    echoing it as well as printing it prints everything twice.
    """
    head, tail = "AWPR", str(int(time.time() * 1000) % 1000000)
    marker = f"{head}{tail}:"
    ser.send(f'{cmd}; echo "{head}""{tail}:$?"')
    out = ser.read_until(marker, timeout, echo=False)
    status = ser.read_until("\n", 30, echo=False).strip()
    try:
        return int(status), out
    except ValueError:
        return 1, out


def die(msg):
    print(f"probe-installed: {msg}", file=sys.stderr)
    raise SystemExit(2)


def read_answers(path):
    """The credentials the image was installed with.

    Read rather than hardcoded: an image built from a different answer file has
    different ones, and a wrong password shows up as a boot timeout several
    minutes later, which reads like the VM failed to start.
    """
    if not path.is_file():
        die(f"no answer file at {path}")
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip()
    for key in ("USERNAME", "USER_PASSWORD", "LUKS_PASSPHRASE", "HOSTNAME"):
        if not values.get(key):
            die(f"{path} does not set {key}")
    return values


def stage(work, specs):
    """Copy each --file into the served directory. Returns (name, dest) pairs.

    Numbered rather than named, so two files with the same basename from
    different directories do not overwrite each other on the way in.
    """
    files_dir = work / "files"
    files_dir.mkdir()
    staged = []
    for i, spec in enumerate(specs):
        src, sep, dest = spec.partition(":")
        # A Windows-style path would split on its drive letter. This tooling is
        # Linux-only, but the mistake is worth naming rather than mangling.
        if sep and not dest.startswith("/"):
            die(f"--file destination must be an absolute guest path: {spec}")
        src_path = pathlib.Path(src)
        if not src_path.is_file():
            die(f"--file source does not exist: {src}")
        name = f"{i:03d}"
        shutil.copy(src_path, files_dir / name)
        staged.append((name, dest or f"{GUEST_DIR}/{src_path.name}",
                       src_path.stat().st_mode & 0o777))
    return staged


def serve(directory):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            """Silent. How a file reached the guest is not the answer the probe
            was run to get, and a GET line per staged file buries the one that
            is."""

    def handler(*a, **kw):
        return Handler(*a, directory=str(directory), **kw)

    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    httpd.allow_reuse_address = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def boot(disk, vars_file, serial_port):
    code = D._first_existing(D.OVMF_CODE_CANDIDATES, "OVMF firmware",
                             "ARCHWRIGHT_OVMF_CODE")
    acc = D.accel()
    args = [
        D.qemu_binary(),
        "-machine", f"q35,accel={acc}",
        "-cpu", "host" if acc == "kvm" else "qemu64",
        "-m", "4096", "-smp", "2",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={vars_file}",
        "-drive", f"file={disk},if=virtio,format=qcow2",
        # Every write goes to a temporary overlay that is discarded on exit.
        "-snapshot",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-serial", f"tcp:127.0.0.1:{serial_port},server=on,wait=off",
        # The same hardware the gate installs against: a GPU with a render
        # node, and a sound card. A probe answering a question about a system
        # that differs from the tested one answers the wrong question.
        "-device", "virtio-vga",
        "-display", "none",
        "-audiodev", "none,id=snd0",
        "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd0",
    ]
    return subprocess.Popen(args, stdout=subprocess.DEVNULL,
                            stderr=subprocess.STDOUT)


def log_in(ser, answers, quiet):
    def note(msg):
        if not quiet:
            print(f"probe-installed: {msg}", flush=True)

    note("waiting for the LUKS passphrase prompt")
    ser.read_until("passphrase", D.BOOT_TIMEOUT, echo=False)
    ser.send(answers["LUKS_PASSPHRASE"])
    note("unlocked; waiting for a login prompt")
    ser.read_until("login:", D.BOOT_TIMEOUT, echo=False)
    ser.send(answers["USERNAME"])
    ser.read_until("Password:", 120, echo=False)
    ser.send(answers["USER_PASSWORD"])
    ser.read_until("@" + answers["HOSTNAME"], 120, echo=False)
    rc, _ = guest(ser, "true", 60)
    if rc != 0:
        die("logged in but could not run a command")
    note("logged in")


def wait_for_session(ser, quiet):
    """Give Hyprland a moment to come up.

    Bounded and non-fatal: most probes want the session, some only want the
    filesystem, and a probe that refuses to run because a compositor was slow
    would be worse than one that reports what it found.
    """
    guest(ser, "for i in $(seq 1 30); do "
               "ls /run/user/1000/hypr >/dev/null 2>&1 && break; sleep 2; done", 120)
    rc, _ = guest(ser, "ls /run/user/1000/hypr >/dev/null 2>&1", 30)
    if rc != 0 and not quiet:
        print("probe-installed: no Hyprland instance yet - "
              "running the probe anyway", flush=True)


def fetch(ser, port, url_path, dest):
    """Fetch one file into the guest, retrying while NetworkManager gets DHCP.

    Always to a path the login user can write. Fetching straight to the final
    destination looked simpler and failed on the first destination outside the
    user's home: curl cannot write /etc as the user, and the retry loop turned
    one permission error into thirty of them.
    """
    rc, _ = guest(
        ser,
        f"mkdir -p \"$(dirname '{dest}')\" && "
        f"for i in $(seq 1 30); do "
        f"curl -fsS -o '{dest}' http://10.0.2.2:{port}/{url_path} && break; "
        f"sleep 2; done; test -s '{dest}'", 180)
    if rc != 0:
        die(f"could not fetch {url_path} into the guest as {dest}")


def place(ser, staged, dest, mode, password):
    """Move a staged file to where the probe wants it, as root.

    Ownership is inherited from whatever is already there - the file being
    replaced, or failing that its directory - so a config dropped into a user's
    home stays the user's and one dropped into /etc stays root's. A file that
    lands root-owned in someone's home is the kind of detail that makes a probe
    report a failure the real system does not have.
    """
    rc, out = guest(
        ser,
        f"own=$(stat -c '%U:%G' '{dest}' 2>/dev/null "
        f"     || stat -c '%U:%G' \"$(dirname '{dest}')\" 2>/dev/null "
        f"     || echo root:root); "
        f"echo {password} | sudo -S install -D -m {mode:o} "
        f"-o \"${{own%:*}}\" -g \"${{own#*:}}\" '{staged}' '{dest}'", 120)
    if rc != 0:
        die(f"could not put the staged file at {dest}: {out[-300:]}")


def main():
    ap = argparse.ArgumentParser(
        description="Run a script inside the last passing installed image.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="The disk is never written: QEMU runs with -snapshot.")
    ap.add_argument("script", nargs="?",
                    help="script to run inside the guest")
    ap.add_argument("-c", "--command",
                    help="run this shell command instead of a script")
    ap.add_argument("--file", action="append", default=[], metavar="SRC[:DEST]",
                    help="copy a file into the guest before running "
                         f"(default destination {GUEST_DIR}/<name>); repeatable")
    ap.add_argument("--timeout", type=int, default=600, metavar="SECONDS",
                    help="how long the probe may run inside the guest (600)")
    ap.add_argument("--answers", type=pathlib.Path, default=DEFAULT_ANSWERS,
                    help="answer file the image was installed with")
    ap.add_argument("--latest", action="store_true",
                    help="use the most recent run's disk instead of the last "
                         "PASSING one; that disk is rebuilt by every test run")
    ap.add_argument("--as-user", action="store_true",
                    help="run as the login user rather than through sudo")
    ap.add_argument("-q", "--quiet", action="store_true",
                    help="print only what the guest printed")
    args = ap.parse_args()

    if bool(args.script) == bool(args.command):
        die("give exactly one of a script path or -c COMMAND")

    answers = read_answers(args.answers)
    src_dir = D.VMRUN if args.latest else D.LASTGOOD
    disk = src_dir / "disk.qcow2"
    vars_src = src_dir / "OVMF_VARS.fd"
    if not disk.is_file():
        die(f"no installed disk at {disk}\n"
            "  Produce one with:  bash test/vm-install.sh --phase all\n"
            "  (--latest uses the in-progress run's disk instead.)")
    if not vars_src.is_file():
        die(f"missing firmware vars at {vars_src}")

    work = pathlib.Path(tempfile.mkdtemp(prefix="aw-probe-"))
    proc = None
    httpd = None
    try:
        # The archive's own vars file is never opened: a probe must not be able
        # to rewrite the NVRAM of the image everything else starts from.
        shutil.copy(vars_src, work / "OVMF_VARS.fd")
        if args.script and not pathlib.Path(args.script).is_file():
            die(f"no script at {args.script}")
        body = (pathlib.Path(args.script).read_text() if args.script
                else args.command + "\n")
        (work / "probe.sh").write_text(body)
        staged = stage(work, args.file)

        httpd, hport = serve(work)
        sport = D.free_port()
        if not args.quiet:
            print(f"probe-installed: booting {disk.parent.name} read-only "
                  f"(serial {sport})", flush=True)
        proc = boot(disk, work / "OVMF_VARS.fd", sport)

        ser = D.Serial(sport)
        log_in(ser, answers, args.quiet)
        wait_for_session(ser, args.quiet)

        fetch(ser, hport, "probe.sh", "/tmp/probe.sh")
        for name, dest, mode in staged:
            tmp = f"/tmp/probe-staged/{name}"
            fetch(ser, hport, f"files/{name}", tmp)
            place(ser, tmp, dest, mode, answers["USER_PASSWORD"])
            if not args.quiet:
                print(f"probe-installed: staged {dest}", flush=True)

        runner = f"AW_PROBE_DIR={GUEST_DIR} bash /tmp/probe.sh"
        if not args.as_user:
            runner = (f"echo {answers['USER_PASSWORD']} | "
                      f"sudo -S env AW_PROBE_DIR={GUEST_DIR} bash /tmp/probe.sh")
        if not args.quiet:
            print("probe-installed: running the probe\n", flush=True)
        # Markers rather than trusting the prompt: the guest's shell echoes the
        # command it was given, so without them the command text and its output
        # are indistinguishable in the transcript.
        _, out = guest(
            ser, f"echo {BEGIN}; {runner} 2>&1; echo {END}$?", args.timeout)

        body_out = out.split(BEGIN + "\n")[-1]
        body_out, _, tail = body_out.partition(END)
        print(body_out.rstrip("\n"))
        status = tail.strip().split()[0] if tail.strip() else ""
        if not status.isdigit():
            die("the probe did not report an exit status - it may have timed out")
        return int(status)
    finally:
        if proc is not None:
            proc.kill()
        if httpd is not None:
            httpd.shutdown()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
