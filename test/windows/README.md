# Running the VM on Windows, without WSL

A second host path for the QEMU work. It runs the **same installer** against the
**same stock Arch ISO** as `test/vm-install.sh`, but on Windows directly, using
QEMU's `whpx` accelerator instead of KVM.

This does **not** replace the Linux oracle. `test/vm/drive_vm.py` remains the
gate. Nothing here imports it and nothing here is imported by it — see "Why the
duplication" at the bottom.

---

## Prerequisites

| Need | Where it comes from |
|---|---|
| QEMU for Windows ≥ 11 | `winget install qemu`, default `C:\Program Files\qemu` |
| `whpx` accelerator | Windows Hypervisor Platform. Usually already live: VBS / Memory Integrity keeps the hypervisor running even with the optional feature off |
| UEFI firmware | ships with QEMU, in its own `share\` — nothing to install |
| bsdtar | ships with Windows 10+ as `System32\tar.exe`. GNU tar cannot read ISO9660 |
| Python 3 | for the scripts here |

Check the accelerator before anything else:

```
& 'C:\Program Files\qemu\qemu-system-x86_64.exe' -accel help
```

`whpx` must appear. If only `tcg` is listed, enable the Windows Hypervisor
Platform optional feature and reboot.

## One-time setup

```
python test\windows\fetch-iso.py
```

Downloads the current ISO to `%USERPROFILE%\.cache\archwright-win`, verifies its
SHA-256 against the mirror, extracts `vmlinuz-linux` and `initramfs-linux.img`,
and records the ISO9660 volume label. About 1.6 GB.

Override the location with `ARCHWRIGHT_WIN_CACHE`, the mirror with
`ARCHWRIGHT_MIRROR`, and QEMU's location with `ARCHWRIGHT_QEMU` /
`ARCHWRIGHT_QEMU_IMG`.

## Automated runs

```
python test\windows\test_serial.py          # seconds, no VM
python test\windows\probe-poweroff.py       # ~2 min, one question
python test\windows\probe-install-boot.py   # ~8 min, the full gate
```

- **`test_serial.py`** — escape handling in the serial reader. Run it before a
  VM run; it costs a second and catches a class of failure that otherwise shows
  up as corrupted guest output minutes in.
- **`probe-poweroff.py`** — isolates whether a WHPX guest powers off cleanly
  without losing writes. Two canaries, one synced and one not.
- **`probe-install-boot.py`** — installs all ten phases from the live ISO,
  powers off, boots the installed encrypted system, answers the LUKS prompt,
  and runs `test/vm/assertions.sh` inside it.

Each run wipes `%USERPROFILE%\.cache\archwright-win\probe-run` and creates a
fresh qcow2 and its own copy of the firmware vars.

## Manual testing — driving it yourself

The probes run headless and talk over a serial socket. To sit in front of the
machine instead, build a disk and launch QEMU with a display.

Create a disk (dynamic — a 20 GiB image starts at ~192 KiB):

```
$cache = "$env:USERPROFILE\.cache\archwright-win"
$vm    = "$cache\manual"
New-Item -ItemType Directory -Force $vm | Out-Null
& 'C:\Program Files\qemu\qemu-img.exe' create -f qcow2 "$vm\disk.qcow2" 20G
Copy-Item 'C:\Program Files\qemu\share\edk2-i386-vars.fd' "$vm\OVMF_VARS.fd"
```

Boot the live ISO (the installer medium):

```
$qemu  = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$share = 'C:\Program Files\qemu\share'
$label = Get-Content "$cache\boot\archisolabel.txt"

& $qemu `
  -machine q35,accel=whpx `
  -cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes `
  -m 4096 -smp 2 `
  -drive "if=pflash,format=raw,readonly=on,file=$share\edk2-x86_64-code.fd" `
  -drive "if=pflash,format=raw,file=$vm\OVMF_VARS.fd" `
  -drive "file=$vm\disk.qcow2,if=virtio,format=qcow2" `
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 `
  -device virtio-vga `
  -audiodev dsound,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 `
  -display gtk `
  -cdrom "$cache\archlinux.iso" `
  -kernel "$cache\boot\vmlinuz-linux" `
  -initrd "$cache\boot\initramfs-linux.img" `
  -append "archisobasedir=arch archisolabel=$label console=ttyS0,115200"
```

To boot **the system you installed**, drop the last four lines
(`-cdrom` / `-kernel` / `-initrd` / `-append`) and keep everything else,
including the same `OVMF_VARS.fd` — that file holds the NVRAM boot entry the
installer wrote, and reusing it is what proves the entry works.

Getting the tree into the guest, once it has a shell:

```
python -m http.server 8000        # in the repo root, on the host
```

then inside the guest, where `10.0.2.2` is the host as seen through QEMU's NAT:

```
curl -fsS -o /tmp/repo.tar http://10.0.2.2:8000/repo.tar
```

### Notes on driving it by hand

- **`-kernel`/`-initrd` are what give you a serial console.** They let
  `console=ttyS0,115200` onto the command line. Booting the ISO's own
  bootloader instead means no scriptable console.
- **The Super key does not reach the guest** through a normal QEMU window on
  Windows; the host claims it. Same limitation the WSLg path has.
- Swap `-display gtk` for `-display sdl` if GTK misbehaves, or
  `-display none -serial stdio` for a console-only session.

## Windows-specific constraints

Four things differ from the Linux path, all verified rather than assumed:

- **No virtio-9p.** `-fsdev help` reports *"fsdev support is disabled"* in the
  stock Windows build. There is no folder share. The probes hand the repo to the
  guest over HTTP through QEMU's NAT instead, which needs nothing extra.
- **Never pass `--host-pkg-cache`.** It makes pacstrap use the live
  environment's cache with `-c`, which on a stock ISO is tmpfs in RAM. The Linux
  harness only survives it because it mounts a host directory there over 9p
  first. Without that mount it fills RAM and fails. The cost is that every run
  re-downloads: about 4½ extra minutes.
- **The CPU model is a ceiling, not a preference.**
  `qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes` is the most upstream WHPX
  survives. Any AVX-class feature is accepted at launch and then panics the
  guest kernel at ~0.25s in `fpstate_reset`, so a bad value looks like a hang,
  not a rejection.
- **Python's stdout is cp1252 here.** The guest's serial stream is not all valid
  UTF-8, and the undecodable bytes become U+FFFD, which cp1252 cannot re-encode.
  Every entry point calls `use_utf8_stdout()` first.

## Why the duplication

`winvm.py` reimplements the serial conversation that `test/vm/drive_vm.py`
already has. That is deliberate: the Linux path is the working oracle, and
threading a second host's conditionals through it would put the trusted check at
risk to serve an experiment.

The cost is that fixes do not propagate on their own. When `drive_vm.py`'s
reader changes, check whether `winvm.py` needs the same change — `test_serial.py`
here mirrors `test/unit/test_serial.sh` so the two can be compared directly.
