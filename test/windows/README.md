# Testing Archwright in a VM on Windows

A complete walkthrough, assuming no prior knowledge of this project, of QEMU, or
of Linux installers. If you already know all three, skip to
[Path A: the automated run](#path-a-the-automated-run).

---

## 1. What this is, and why it exists

**Archwright** is an installer. It takes a blank disk, partitions it, encrypts
it, and installs Arch Linux with the Hyprland desktop on top.

That is a destructive program. It erases whatever disk you point it at. So you
never test it on a real computer — you test it on a *pretend* computer, called a
**virtual machine**, whose "hard disk" is just a file on your desktop. If the
installer wipes that, you delete the file and make another one.

The project's official test runs that pretend computer inside WSL2 (Linux on
Windows). **This folder is the other way: running it on Windows directly, with
no WSL at all.**

Both do the same thing to the same installer. The Linux one
(`test/vm-install.sh`) is the project's *gate* — the check that decides whether a
change is good. This one is a second opinion that happens to be easier to look at
on a Windows machine.

## 2. Words you will see

| Term | What it means here |
|---|---|
| **QEMU** | The program that pretends to be a computer. Everything below is QEMU |
| **Host** | Your real Windows machine |
| **Guest** | The pretend computer running inside QEMU |
| **WHPX** | Windows' hardware acceleration for VMs. With it the guest runs at near-native speed; without it QEMU emulates every instruction and is roughly twenty times slower |
| **ISO** | The Arch Linux installer image — the equivalent of a setup CD |
| **Live ISO** | The temporary Linux that boots off that CD. It is where the installer runs *from*. Nothing you do in it survives a reboot |
| **qcow2** | The guest's pretend hard disk: one file that starts tiny and grows as the guest writes. A 20 GiB disk begins life at about 192 KiB |
| **UEFI / OVMF** | The guest's firmware — its BIOS. It comes as two files: `edk2-x86_64-code.fd` (read-only program) and a writable copy of `edk2-i386-vars.fd` that remembers which disk to boot. Keeping that second file is what proves the installer registered itself correctly |
| **Serial console** | A plain-text pipe into the guest, with no graphics. Scripts drive the guest this way |
| **`/dev/vda`** | What the guest calls its disk. Your `disk.qcow2` appears there |

## 3. What you need

| Requirement | Notes |
|---|---|
| Windows 10 or 11, 64-bit | |
| ~30 GB free disk | 1.6 GB ISO, plus a VM disk that grows to roughly 5.5 GB per install |
| 8 GB RAM or more | The guest is given 4 GB |
| QEMU for Windows, version 11 or newer | `winget install qemu`. Installs to `C:\Program Files\qemu` |
| Python 3 | For the scripts in this folder |
| An internet connection | The guest downloads packages during the install |

Everything else — the UEFI firmware, and the `bsdtar` needed to open an ISO —
you already have. QEMU ships the firmware in its own `share\` folder, and
Windows 10+ ships bsdtar as `C:\Windows\System32\tar.exe`.

### Check that acceleration works — do this first

```powershell
& 'C:\Program Files\qemu\qemu-system-x86_64.exe' -accel help
```

You want **`whpx`** in the output:

```
Accelerators supported in QEMU binary:
tcg
whpx
```

If you see only `tcg`, enable the Windows Hypervisor Platform and reboot:

```powershell
# Run as Administrator
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
```

It often already works without that, because Windows 11's Memory Integrity keeps
the hypervisor running anyway.

## 4. One-time setup

```powershell
cd <the archwright repo>
python test\windows\fetch-iso.py
```

This downloads the current Arch ISO (~1.6 GB) into
`%USERPROFILE%\.cache\archwright-win`, checks it against the mirror's published
SHA-256, then pulls the Linux kernel and startup image out of it and records the
ISO's volume label. Run it once; it skips the download if the ISO is already
there.

Nothing large is ever written into the repo.

**Environment overrides**, if the defaults do not suit you:
`ARCHWRIGHT_WIN_CACHE`, `ARCHWRIGHT_MIRROR`, `ARCHWRIGHT_QEMU`,
`ARCHWRIGHT_QEMU_IMG`.

---

## Path A: the automated run

Three scripts, in increasing cost. Each one prints a result block and exits
non-zero on failure.

```powershell
python test\windows\test_serial.py          # seconds, no VM at all
python test\windows\probe-poweroff.py       # ~2 minutes
python test\windows\probe-install-boot.py   # ~8 minutes, the whole thing
```

**`test_serial.py`** checks the code that reads text out of the guest. Run it
first: it costs a second, and it catches a class of bug that otherwise shows up
as garbled output ten minutes into a VM run.

**`probe-poweroff.py`** answers one narrow question — can the guest shut itself
down cleanly without losing data that was just written? It writes two marker
files, powers off, boots again, and reports whether they survived.

**`probe-install-boot.py`** is the full exercise: install all ten phases from the
ISO, shut down, boot the installed encrypted system, type the disk passphrase,
log in, and run the project's assertion suite inside it. A good run ends:

```
  install seconds        311.8
  poweroff wedged        False
  LUKS prompt            True
  login accepted         True
  assertions             passed
```

Each run wipes `%USERPROFILE%\.cache\archwright-win\probe-run` and starts from a
fresh disk.

---

## Path B: doing it by hand

Use this when you want to *watch* the install, poke at the guest, or debug
something the automated run only reports.

Every command below is PowerShell, run from the repo root.

### Step 1 — set up a working folder

```powershell
$repo  = (Get-Location).Path
$cache = "$env:USERPROFILE\.cache\archwright-win"
$qemu  = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$qimg  = 'C:\Program Files\qemu\qemu-img.exe'
$share = 'C:\Program Files\qemu\share'
$vm    = "$cache\manual"

New-Item -ItemType Directory -Force $vm | Out-Null
```

### Step 2 — create the virtual disk and the firmware memory

```powershell
& $qimg create -f qcow2 "$vm\disk.qcow2" 20G
Copy-Item "$share\edk2-i386-vars.fd" "$vm\OVMF_VARS.fd" -Force
```

The disk file will report 20 GiB but occupy about 192 KiB until the guest starts
writing. `OVMF_VARS.fd` is your VM's private firmware memory — **your own copy**,
never the one in `share\`, because the guest writes to it.

### Step 3 — package the project

The guest cannot see your Windows folders. There is no shared drive; QEMU for
Windows has no folder-sharing support at all. So you hand the project over as a
single archive, downloaded through the guest's network connection.

```powershell
& "$env:SystemRoot\System32\tar.exe" -cf "$vm\repo.tar" `
    --exclude=./.git --exclude=./.tools --exclude=./docs --exclude=__pycache__ .
```

Use `System32\tar.exe` explicitly. If you have Git for Windows installed, a
different `tar` (GNU tar) may come first on your PATH, and it cannot do this job
later when reading the ISO.

Build it into `$vm`, **not** into the repo — an archive of the repo sitting
inside the repo is easy to commit by accident.

Expect roughly 780 KB and about 130 files. Check it:

```powershell
& "$env:SystemRoot\System32\tar.exe" -tf "$vm\repo.tar" | Select-String 'install.sh$'
```

> A `.zip` will not work here: the Arch live system has `tar` but not
> `unzip`. Use `.tar` as above.

### Step 4 — serve the archive to the guest

In a **second PowerShell window**, leave this running for as long as the VM
needs it:

```powershell
cd "$env:USERPROFILE\.cache\archwright-win\manual"
python -m http.server 8000 --bind 127.0.0.1
```

The guest reaches your host at the fixed address **`10.0.2.2`**, which is QEMU's
built-in router pointing back at you.

### Step 5 — boot the installer medium

Back in the first window:

```powershell
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
  -serial stdio `
  -cdrom "$cache\archlinux.iso" `
  -kernel "$cache\boot\vmlinuz-linux" `
  -initrd "$cache\boot\initramfs-linux.img" `
  -append "archisobasedir=arch archisolabel=$label console=ttyS0,115200"
```

A window opens and Linux boots. It takes about 30 seconds.

Why `-kernel` and `-initrd` when the ISO already contains them: passing them
directly is the only way to add `console=ttyS0,115200` to the boot options, which
is what makes the guest scriptable. It also skips the boot menu.

**`-serial stdio` matters.** That `console=ttyS0,115200` sends the system console
to the serial port, and `-serial stdio` is what connects that port to the
PowerShell window you launched from. Kernel messages appear there, not in the VM
window. You will need it again, and for a more painful reason, at step 10.

The Arch live ISO happens to log you in automatically on the graphical screen as
well, so you can work in the VM window regardless. The installed system does
not — see step 10.

### Step 6 — log in

At `archiso login:` type **`root`** and press Enter. There is no password on the
official Arch medium.

You should land at a prompt like `root@archiso ~ #`.

### Step 7 — pull the project into the guest

Type these **in the guest window**:

```sh
curl -fsS -o /tmp/repo.tar http://10.0.2.2:8000/repo.tar
mkdir -p /root/archwright
tar -xf /tmp/repo.tar -C /root/archwright
ls /root/archwright/install.sh
```

If `curl` hangs, the web server in step 4 is not running, or it was started in a
different folder.

### Step 8 — run the installer

```sh
cd /root/archwright
bash install.sh --answers test/vm/answers.example.conf --yes
```

**There is no `--phase all`.** Leaving `--phase` off runs every phase in order,
which is what you want. Naming a single phase (`--phase disk`) runs just that
one, and the only accepted names are `preflight disk base boot theme session
shell apps ai hardware`.

`--yes` skips the "this will erase the disk" confirmation. That is safe here
because the answer file targets `/dev/vda`, which is the pretend disk.

**Do not add `--host-pkg-cache`.** On a real Arch ISO the package cache lives in
RAM, and filling it will run the guest out of memory. The Linux test only uses
that flag because it mounts real storage there first, which QEMU for Windows
cannot do.

Expect about five minutes. The long part is `base`, which downloads packages.

`test/vm/answers.example.conf` holds the test settings: disk `/dev/vda`, hostname
`archwright-vm`, user `test` with password `testpassword`, disk passphrase
`testpassphrase`. **These are throwaway test credentials. Never use them on a
real machine.**

### Step 9 — shut the guest down

```sh
sync
systemctl poweroff -i
```

The QEMU window closes on its own after a few seconds. Wait for it — that is the
guest flushing to disk.

### Step 10 — boot what you just installed

Same command as step 5, **minus the last four lines** — no `-cdrom`, no
`-kernel`, no `-initrd`, no `-append`:

```powershell
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
  -serial stdio
```

Keep the **same `OVMF_VARS.fd`**. It holds the boot entry the installer wrote,
and reusing it is exactly what proves that entry works.

> **Do not drop `-serial stdio` here.** `answers.example.conf` sets
> `SERIAL_CONSOLE=1`, which puts `console=ttyS0,115200` on the kernel command
> line. Linux then sends the console to the serial port and *nothing* to the VM's
> screen. Without a serial backend the VM window freezes on Limine's last
> message, `Loading Kernel...`, and stays there forever — while the kernel sits
> waiting at a passphrase prompt you cannot see. Typing in the VM window does not
> help: those keystrokes go to `tty0`, and the prompt is on `ttyS0`.

**Watch the PowerShell window, not the VM window**, for the first two steps:

1. `Please enter passphrase for disk...` — type **`testpassphrase`** into the
   PowerShell window. Nothing appears as you type; that is normal.
2. A login prompt — user **`test`**, password **`testpassword`**.
3. The Hyprland desktop, which appears in the **VM window**.

That sequence is the whole point of the exercise: an encrypted disk that
unlocks, a bootloader the installer registered, and a desktop that starts.

### Getting the passphrase prompt onto the VM's own screen

Typing the passphrase into the host terminal is an artifact of the test answer
file, not how Archwright behaves normally. Two ways out:

**For a fresh install** — copy `test/vm/answers.example.conf`, delete the
`SERIAL_CONSOLE=1` line, and install with your copy. The prompt then renders on
the VM's screen. Delete `AUTOLOGIN=1` too if you want the real login greeter.
Both settings exist only so the automated harness can drive the guest.

**For a disk you already installed** — the command line stays editable after the
fact, which is why Archwright deliberately avoids a unified kernel image. Boot
once with `-serial stdio`, then in the guest:

```sh
sudo sed -i 's/ console=ttyS0,115200//' /etc/archwright/cmdline
sudo archwright-limine-update
```

Reboot, and the passphrase prompt is on the VM's screen.

### Starting over

Delete the disk and firmware memory and repeat from step 2:

```powershell
Remove-Item "$vm\disk.qcow2","$vm\OVMF_VARS.fd" -Force
```

Close the QEMU window first — Windows will not delete a file QEMU still holds
open, and the error is `Device or resource busy`.

---

## Troubleshooting

| What you see | What it is |
|---|---|
| `-accel help` lists only `tcg` | Windows Hypervisor Platform is off. See §3. Running under `tcg` works but takes hours instead of minutes |
| Guest panics about a quarter-second into boot | Someone widened the `-cpu` line. Any AVX-class feature is accepted at launch and then kills the guest kernel. Keep `qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes` exactly |
| Stuck forever on `Loading Kernel...`, seems very slow | Almost always a missing `-serial stdio` when booting a system installed from `answers.example.conf`. The console is on the serial port, so the screen never updates past Limine's last message and the kernel is waiting at an unseen passphrase prompt. Nothing is actually slow. See step 10 |
| Black window, no text ever | Usually the `-append` line lost its `archisolabel=`. The value must match `boot\archisolabel.txt` |
| `curl` in the guest hangs or 404s | The host web server is not running, or is serving the wrong folder. It must be the folder containing `repo.tar` |
| `unknown phase: all` | There is no `all`. Omit `--phase` to run everything |
| Guest runs out of memory during `base` | `--host-pkg-cache` was passed. Do not pass it here |
| `Device or resource busy` deleting a disk | QEMU still has it open. Close the VM window |
| The **Super** key does nothing in the guest | Windows keeps that key for itself. This is a known limitation of viewing the VM from Windows and applies to the WSL path too |
| The window is too small | Add `-full-screen`, or swap `-display gtk` for `-display sdl` |
| `Failed to enable nested virtualization` | Some laptops advertise it and then refuse. Add `kernel-irqchip=off` to the `-machine` option |

---

## Four things that are different on Windows

These are not preferences; each one will break a run if ignored.

1. **There is no folder sharing.** The stock Windows QEMU is built without
   virtio-9p — `-fsdev help` reports *"fsdev support is disabled"*. That is why
   step 3 packages the project and step 4 serves it over HTTP.
2. **Never pass `--host-pkg-cache`.** Explained in step 8.
3. **The `-cpu` line is a ceiling, not a suggestion.** Explained in the
   troubleshooting table.
4. **Python's console encoding here is cp1252**, which cannot represent some of
   what the guest emits. Every script in this folder sets UTF-8 before writing
   anything; a new one must call `use_utf8_stdout()` too.

## How this relates to the Linux test

| | Linux (`test/vm-install.sh`) | Windows (this folder) |
|---|---|---|
| Runs in | WSL2 Ubuntu | Windows directly |
| Acceleration | KVM | WHPX |
| Package cache | Shared from the host over 9p | None; downloads each run |
| Project reaches guest | HTTP | HTTP |
| Status | **The gate.** A change is good when this passes | A second host |

`winvm.py` reimplements the guest-conversation code that `test/vm/drive_vm.py`
already has, on purpose: the Linux path is the trusted check, and threading a
second operating system's special cases through it would put that check at risk
to serve an experiment.

The cost is that fixes do not travel between them. When `drive_vm.py`'s reader
changes, check whether `winvm.py` needs the same change. `test_serial.py` here
mirrors `test/unit/test_serial.sh` so the two can be compared directly.
