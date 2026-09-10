#!/usr/bin/env python3
"""Populate the Windows cache: download the Arch ISO, verify it, extract boot.

Usage:  python test/windows/fetch-iso.py
"""

import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

from winvm import BOOT, CACHE, ISO, die, log

MIRROR = os.environ.get("ARCHWRIGHT_MIRROR",
                        "https://geo.mirror.pkgbuild.com/iso/latest")
# The ISO9660 volume identifier: 32 bytes at offset 32808. Read directly rather
# than depending on blkid or a loop mount, neither of which exists here.
LABEL_OFFSET = 32808
LABEL_LENGTH = 32


def bsdtar():
    """Only bsdtar reads ISO9660. Windows ships it as System32\\tar.exe."""
    candidates = [pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows"))
                  / "System32" / "tar.exe"]
    found = shutil.which("bsdtar") or shutil.which("tar")
    if found:
        candidates.append(pathlib.Path(found))
    for cand in candidates:
        if not cand.is_file():
            continue
        try:
            out = subprocess.run([str(cand), "--version"], capture_output=True,
                                 text=True, timeout=30).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if "bsdtar" in out.lower():
            return str(cand)
    die("no bsdtar found. Windows 10+ ships one at System32\\tar.exe; GNU tar "
        "cannot read ISO9660.")


def fetch(url, dest):
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f, 1024 * 1024)


def download_iso():
    if ISO.is_file():
        log(f"ISO already present: {ISO} ({ISO.stat().st_size} bytes)")
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"{MIRROR}/sha256sums.txt", timeout=60) as r:
        sums = r.read().decode()
    match = re.search(r"^(\S+)\s+(archlinux-[0-9.]+-x86_64\.iso)$", sums, re.M)
    if not match:
        die("could not find an ISO entry in sha256sums.txt")
    want, name = match.group(1), match.group(2)

    part = ISO.with_suffix(".iso.part")
    log(f"downloading {name} ...")
    fetch(f"{MIRROR}/{name}", part)

    log("verifying sha256 ...")
    digest = hashlib.sha256()
    with open(part, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    got = digest.hexdigest()
    if got != want:
        part.unlink(missing_ok=True)
        die(f"CHECKSUM MISMATCH: expected {want}, got {got}")

    part.replace(ISO)
    (CACHE / "archlinux.iso.name").write_text(name + "\n")
    log(f"OK: {ISO} ({name})")


def extract_boot():
    BOOT.mkdir(parents=True, exist_ok=True)
    tar = bsdtar()
    for member, out in (("arch/boot/x86_64/vmlinuz-linux", "vmlinuz-linux"),
                        ("arch/boot/x86_64/initramfs-linux.img",
                         "initramfs-linux.img")):
        target = BOOT / out
        with open(target, "wb") as f:
            rc = subprocess.run([tar, "-xOf", str(ISO), member], stdout=f).returncode
        if rc != 0 or target.stat().st_size == 0:
            die(f"could not extract {member} from the ISO")
        log(f"  {out}  {target.stat().st_size} bytes")

    with open(ISO, "rb") as f:
        f.seek(LABEL_OFFSET)
        label = f.read(LABEL_LENGTH).decode("ascii", "replace").strip()
    if not label:
        die("could not read the ISO volume label")
    (BOOT / "archisolabel.txt").write_text(label)
    log(f"  label     {label}")


def main():
    download_iso()
    extract_boot()
    log(f"cache ready: {CACHE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
