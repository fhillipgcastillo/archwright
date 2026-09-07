# Archwright

An opinionated base **Arch Linux** system: encrypted disk, btrfs with snapshots
you can boot back into, and — eventually — Hyprland on Wayland with a small
curated app set and first-class AI-agent tooling.

Two deliverables, one target system: a **guide** that walks you through building
it by hand, and this **installer** that does it for you.

---

## ⚠️ Status: milestone 2 of 7

**What works today:** a bootable, fully encrypted, snapshot-capable Arch system
that starts a **Hyprland desktop**. UEFI, LUKS2, btrfs subvolumes, Limine with
per-snapshot boot entries, snapper, a deny-all firewall — and a graphical
session with a terminal, audio and desktop portals.

**What does not exist yet:** a status bar, notifications, an app launcher or a
lock screen (milestone 3); applications beyond a terminal (milestone 4); the AI
tooling (milestone 5).

Once you are in the session: `Super + Return` opens a terminal, `Super + Q`
closes a window, `Super + 1..4` switches workspace, `Super + Shift + E` exits.

Verified end-to-end in QEMU on every commit. See "Honest limitations" below for
what that does and does not prove about your hardware.

---

## Before you begin

**This erases the entire target disk.** There is no dual-boot support and no
install-alongside. Back up anything you care about.

You need:

- An x86_64 machine that boots **UEFI** (no BIOS/legacy support at all)
- **At least 16 GiB** of disk, and 4 GB of RAM
- A wired or wireless network connection — packages download during install
- A USB stick, 2 GB or larger

### Turn Secure Boot off

Archwright's bootloader is not signed, so **Secure Boot must be disabled** or
the machine will refuse to boot after installation. It is in your firmware
setup, usually under Security or Boot. The installer checks this and refuses to
continue if it is on.

---

## 1. Write the Arch ISO to a USB stick

Download the official ISO from <https://archlinux.org/download/>. Do not use a
modified or third-party image — Archwright installs *from* the stock medium.

| Host | Command / tool |
|---|---|
| Linux | `sudo dd if=archlinux-*.iso of=/dev/sdX bs=4M status=progress oflag=sync` |
| macOS | `sudo dd if=archlinux-*.iso of=/dev/rdiskN bs=4m` |
| Windows | [Rufus](https://rufus.ie) in **DD mode**, or [Ventoy](https://ventoy.net) |

Verify the download's signature or checksum first if you can — the ISO is going
to become your root filesystem.

## 2. Boot it

Boot the USB from your firmware's boot menu, choosing the **UEFI** entry (it is
usually labelled `UEFI: <your usb>`). If you pick the non-UEFI entry the
installer will stop and tell you.

You land at a root prompt: `root@archiso ~ #`.

## 3. Get on the network

**Wired:** usually already working. Check with `ping -c1 archlinux.org`.

**Wi-Fi:** the ISO ships `iwctl`.

```sh
iwctl
[iwd]# device list                      # find your device, e.g. wlan0
[iwd]# station wlan0 scan
[iwd]# station wlan0 get-networks
[iwd]# station wlan0 connect "Your SSID"
[iwd]# exit
ping -c1 archlinux.org
```

The installer refuses to run without a working connection, because it downloads
every package from Arch's mirrors.

## 4. Fetch Archwright

**The Arch ISO does not ship git**, so install it first:

```sh
pacman -Sy --noconfirm git
git clone https://github.com/fhillipgcastillo/archwright.git
cd archwright
```

No network on the target machine, or you would rather not clone? Put the repo
on a second USB stick and mount it:

```sh
mkdir -p /mnt/usb && mount /dev/sdY1 /mnt/usb && cd /mnt/usb/archwright
```

(You still need a network connection for the install itself — only the *repo*
can come from USB.)

## 5. Find your disk

```sh
lsblk -do NAME,SIZE,MODEL
```

Note the whole-disk name — `/dev/nvme0n1`, `/dev/sda`, `/dev/vda`. **Not** a
partition like `/dev/nvme0n1p1`. Everything on it will be destroyed.

## 6. Write your answer file

The installer is unattended: it reads every choice from a file rather than
prompting. Copy the example and edit it:

```sh
cp test/vm/answers.example.conf /root/answers.conf
nano /root/answers.conf
```

```ini
DISK=/dev/nvme0n1          # from step 5 - this disk gets erased
HOSTNAME=my-laptop
USERNAME=you               # lowercase, your everyday account
USER_PASSWORD=change-me    # login and sudo password
LUKS_PASSPHRASE=change-me  # typed at every boot to unlock the disk
LOCALE=en_US.UTF-8
TIMEZONE=America/New_York  # see: timedatectl list-timezones
KEYMAP=us
AUTOLOGIN=0                # 1 skips the login prompt entirely
SERIAL_CONSOLE=0           # leave at 0 - test builds only
```

Values containing `#` or trailing spaces must be quoted: `USER_PASSWORD="a#b "`.

> The file holds your passwords in plain text. It lives in the live
> environment's RAM and disappears at reboot — but do not copy it onto the
> installed system or a USB stick.

## 7. Install

```sh
bash install.sh --answers /root/answers.conf
```

It will show you the target disk and require you to type `ERASE` to continue.
Expect **20–40 minutes**, mostly package downloads.

Add `--yes` to skip the confirmation, or
`--phase <preflight|disk|base|boot|session>` to run a single stage.

## 8. Reboot

```sh
reboot
```

Remove the USB stick. You should get the Limine boot menu, then a passphrase
prompt, then the greetd login screen. Log in with the username and password
from your answer file and Hyprland starts.

`Super + Return` opens a terminal. Worth trying in it:

```sh
lsblk -f                      # see the LUKS layer and the btrfs subvolumes
snapper -c root list          # the baseline snapshot taken at install
cat /boot/limine.conf         # the boot menu, including the snapshot entry
sudo ufw status verbose       # firewall: deny incoming, allow outgoing
```

### Networking posture

The firewall is on from first boot: **all inbound traffic is denied, no ports
are open**. Outbound is unrestricted.

`openssh` is installed but the service is **not enabled** — a base system that
anyone can install has no business listening on the network unasked. Turn it on
deliberately:

```sh
sudo ufw allow ssh
sudo systemctl enable --now sshd
```

Set up key authentication before you do that on any network you do not control.

---

## Testing in a VM instead

Any hypervisor works, provided you **enable UEFI/EFI firmware** — the default is
often legacy BIOS, which Archwright rejects.

| Hypervisor | Where to enable it |
|---|---|
| VirtualBox | Settings → System → Enable EFI |
| VMware | Options → Advanced → Firmware type → UEFI |
| Hyper-V | Create a **Generation 2** VM |
| QEMU | `-drive if=pflash,...OVMF_CODE.fd` (see `test/vm-install.sh`) |
| Proxmox | BIOS → OVMF (UEFI), plus an EFI disk |

Give it 4 GB RAM and a 20 GB disk, then follow steps 2–8 exactly as above.

**Contributors** have a fully automated harness — `bash test/vm-install.sh
--phase all` builds and boots a throwaway VM and asserts the result. It requires
Linux with KVM. See `CLAUDE.md`.

### The Super key does not work in a VM viewed from Windows

If you run the VM under WSL and look at it from Windows, **`Super + Return` and
every other Super binding will do nothing** — Windows and WSLg both claim the
Super key and it never reaches the guest. `Super + Q` will fire a Windows
shortcut instead.

The configuration is not at fault: `hyprctl binds` shows `modmask: 64` for the
binding, and it works on real hardware. Things that were tried and did **not**
help: QEMU's `Ctrl+Alt+G` input grab, `GDK_BACKEND=x11`, the SDL backend with an
explicit grab modifier, and VNC.

To drive the session anyway, talk to the compositor over the serial console:

```sh
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)
hyprctl dispatch exec foot
hyprctl clients
```

Everything else — the mouse, non-Super bindings, anything launched by dispatch —
behaves normally.

---

## Honest limitations

Milestone 2 is verified in QEMU on every change. That proves the partitioning,
encryption, filesystem, bootloader and session logic is correct. It does **not**
prove these, which no one has yet tested on physical hardware:

- **NVMe disks.** Only `/dev/vda` has ever been exercised. The naming logic for
  `nvme0n1p1` and `mmcblk0p1` is unit-tested but has not touched real hardware.
- **Real firmware.** OVMF is clean, well-behaved reference firmware. Yours may
  refuse the NVRAM boot entry the installer creates. It falls back to the
  removable-media path (`EFI/BOOT/BOOTX64.EFI`), which nearly all firmware
  boots, but this is untested against anything quirky.
- **Graphics drivers.** The test VM uses a virtio GPU. Real machines need real
  drivers: `mesa` covers Intel and AMD, but **NVIDIA cards will not work** until
  the hardware milestone adds driver selection. On an NVIDIA machine, expect the
  base system to boot and the graphical session to fail.
- **Wi-Fi drivers.** Some chipsets need firmware the ISO does not carry.
- **The exact kernel command line.** Test builds set `SERIAL_CONSOLE=1`; a real
  install leaves it at `0`. A one-parameter difference, but a real one.

Known gaps in the software itself are tracked in
[`docs/decisions.md`](docs/decisions.md) under "Known gaps".

---

## If something goes wrong

| Symptom | Cause |
|---|---|
| `not booted in UEFI mode` | You picked the legacy boot entry, or the VM is not set to UEFI |
| `Secure Boot is enabled` | Turn it off in firmware setup |
| `no network` | See step 3; the installer cannot proceed without one |
| `target disk is not a block device` | Typo in `DISK=`, or you gave a partition instead of a whole disk |
| `git: command not found` | `pacman -Sy git` first — see step 4 |
| Boots straight past the menu into firmware | The NVRAM entry was refused; pick the USB/disk manually from the firmware boot menu |

The installer stops on the first error and says what failed. Re-running it is
safe: it tears down its own previous attempt before starting.

---

## Documentation

| File | Contents |
|---|---|
| [`docs/superpowers/specs/`](docs/superpowers/specs/) | What the system is, in full |
| [`docs/decisions.md`](docs/decisions.md) | Every decision, what was rejected, why — plus the implementation log and known gaps |
| [`docs/research-extract.md`](docs/research-extract.md) | The load-bearing technical facts this design rests on |
| [`CLAUDE.md`](CLAUDE.md) | Contributor conventions, test commands, and the disk-safety rule |

## Licence

MIT.
