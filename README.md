# Archwright

An opinionated base **Arch Linux** system: encrypted disk, btrfs with snapshots
you can boot back into, Hyprland on Wayland, a small curated app set, and
first-class AI-agent tooling.

Two deliverables, one target system: a **guide** that walks you through building
it by hand, and this **installer** that does it for you.

---

## Status: all seven milestones complete, verified in QEMU

Every milestone is gated by a run that installs from the stock Arch ISO,
reboots, unlocks the disk, logs in and asserts — 266 assertions at the last
count. Nothing described below is intention; it is what the gate checks.

**It has not been run on physical hardware yet.** See "Honest limitations".

**What works today:** a bootable, fully encrypted, snapshot-capable Arch system
with a **usable Hyprland desktop** — status bar, notifications, app launcher,
wallpaper, idle handling and a lock screen. UEFI, LUKS2, btrfs subvolumes,
Limine with per-snapshot boot entries, snapper, a deny-all firewall, audio and
desktop portals.

**Applications:** Firefox, Neovim, Nautilus, an image viewer, a video player
and a PDF viewer, with sensible defaults — double-clicking a file opens the
right thing. Plus the CLI staples (eza, bat, fd, fzf, lazygit, btop).

**AI tooling:** launchers for Claude Code, Codex, opencode, Crush and pi, plus
the GitHub CLI. Nothing is downloaded at install time — see below.

**Theming:** seven colour palettes with a generated matching wallpaper, GTK
applications included, switchable after install with `aw theme set`.

**Hardware:** GPU driver selection for Intel, AMD and NVIDIA, and a session
lock before suspend on laptops. Re-runnable with `aw hardware`.

**System tasks have graphical answers:** wifi, volume, Bluetooth, monitor
arrangement, archives, a text editor and a calculator. Clicking an indicator on
the bar opens the thing that manages it. `Print` takes a screenshot.

**The guide:** the manual build is written up as a companion document — every
command, and the reasoning behind each decision — so this system can be built
by hand, changed, or read as a reference. `test/check-guide-drift.sh` verifies
the guide's package, theme, group and phase tables still match this repository,
so it cannot quietly go stale.

| Key | Does |
|---|---|
| `Super + Return` | Terminal |
| `Super + Space` | App launcher |
| `Super + Ctrl + L` | Lock the screen |
| `Super + Q` | Close window |
| `Super + 1`…`4` | Switch workspace |
| `Super + ,` | Dismiss a notification |
| `Super + Shift + Ctrl + A` | The default agent, in its own terminal |
| `Print` | Screenshot a region, to the clipboard |
| `Shift + Print` | Screenshot the whole screen, to a file |
| `Super + Shift + S` | Screenshot a region and annotate it |
| `Super + Shift + T` | Pick a colour theme |
| `Super + Shift + B` | Pick a background image |
| `Super + Shift + E` | Exit the session |

The screen locks itself after five minutes idle.

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
THEME=mocha                # colour theme; see the table below
EXTRAS=                    # optional extras, comma separated - see below
SERIAL_CONSOLE=0           # leave at 0 - test builds only
```

Values containing `#` or trailing spaces must be quoted: `USER_PASSWORD="a#b "`.

**Optional extras.** Leave `EXTRAS=` empty for none, or pick groups by name:

| Group | Contains |
|---|---|
| `office` | LibreOffice |
| `media` | OBS Studio, Kdenlive, GIMP |
| `containers` | Docker, Docker Compose, Lazydocker |
| `browsers` | Chromium |
| `ai-local` | Ollama |
| `desktop-tools` | Disks, system monitor, disk usage, keyring GUI, colour picker, screen recorder, clipboard history |
| `theming-gui` | azote (wallpaper browser), nwg-look (GTK settings) |
| `printing` | CUPS and the print dialog — **runs a daemon** |
| `gaming` | Steam, Lutris — **enables the `multilib` repository** |

**Themes.** `THEME=` takes one of `mocha` (default), `rosepine`, `tokyonight`,
`gruvbox`, `nord`, `everforest`, `latte` (light). Change it later with
`aw theme set <name>` or pick one visually with `Super + Shift + T`.

For example `EXTRAS=office,containers`. Nothing outside the groups you name is
installed, and `multilib` is enabled only if you choose `gaming`.

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
`--phase <preflight|disk|base|boot|session|shell>` to run a single stage.

### If the install is interrupted

A dropped connection or a closed lid part-way through does **not** mean starting
again. Archwright records which phases finished on the EFI partition, so:

```sh
bash install.sh --answers /root/answers.conf --resume
```

reopens the encrypted container, remounts everything, and continues from where
it stopped rather than re-downloading hundreds of megabytes. It refuses to touch
a disk it cannot positively identify as an Archwright install in progress.

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

### The AI tooling

Five agent CLIs are available from first login: `claude`, `codex`, `opencode`,
`crush` and `pi`, plus `gh` for GitHub.

**None of them is downloaded at install time.** Each is a small launcher in
`~/.local/bin` that hands the job to `mise`, which fetches and caches the real
package the first time you run it. So the install stays fast, an agent you
never use costs you nothing, and the first run of each one needs a network
connection and takes a minute.

You still have to sign in to each agent yourself — Archwright installs the
command, not your account.

```sh
archwright default agent codex   # change which agent the keybind launches
a                                # run the default agent here in this terminal
archwright mise-install npm:@scope/tool    # add a launcher for anything else
```

`Super + Shift + Ctrl + A` opens the default agent in a terminal of its own.
Both it and `a` read the same setting, so they never disagree.

**Unattended modes ship switched off.** `~/.config/archwright/agents.sh`
contains the aliases that run each agent without stopping to ask before it
edits files or runs commands — written out, commented out, with the warning
attached. Handing a machine you just installed to an agent that never pauses
should be something you chose, not something you inherited. That file is yours;
Archwright writes it once and never touches it again.

**A passwordless sudo window, when you need one:**

```sh
archwright sudo-window 30    # 30 minutes, then it removes itself
```

This exists because a long run of privileged commands otherwise means a
password prompt every few minutes. It is safer than the permanent `NOPASSWD`
line people usually end up with, and the difference is in the failure cases:

- The rule is checked with `visudo` **before** it is installed — a malformed
  file in `/etc/sudoers.d` locks you out of root with no way back.
- The timer is scheduled **before** the grant is written, so there is no moment
  where the grant exists and nothing is due to remove it.
- The revert is scheduled on **two clocks at once** — a countdown and a
  wall-clock deadline, whichever comes first. A countdown alone stops while the
  machine is suspended; a wall-clock deadline alone can be missed entirely if
  the system clock is stepped or the timezone disagrees. Each covers a case the
  other cannot. (Lose the wall-clock trigger *and* then suspend, and the window
  still closes — just late, and at the next boot regardless.)
- It is removed **at every boot** regardless, because a reboot destroys the
  timer but not the file.

It is still real root access with no password for as long as it is open. Ask
for the shortest window that does the job.

Close one early with:

```sh
sudo rm -f /etc/sudoers.d/99-archwright-sudo-window
```

**Every agent finds the same description of this system.** A skill covering the
layout — where configuration lives, what owns what, what not to edit — is
installed once and linked into each agent's skills directory:
`~/.claude/skills`, `~/.codex/skills`, `~/.pi/agent/skills` and
`~/.agents/skills`. So you can ask whichever agent you prefer to restyle the
bar or change a keybind, and it starts out knowing where those things are
rather than guessing. The copy under
`~/.local/share/archwright/agent-skills/` is yours to edit; the links all point
at it.

For a local model instead of a hosted one, install with `EXTRAS=ai-local` to
get Ollama.

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

For a single question rather than the whole gate, `python3
tools/probe-installed.py -c '<command>'` boots the last passing image headless,
runs the command inside it and prints the answer — minutes instead of an hour.
It reports; it asserts nothing, and the disk is never written.

### The Super key, and viewing the VM from Windows

**Solved — use virt-viewer rather than the WSLg window.** With a native SPICE
client every binding works, Super included, and no keyboard grab is needed. See
"A native SPICE client" below for the three commands.

The rest of this section is why, and what does *not* work, because that failure
is easy to re-create by accident.

If you open the QEMU window from WSL and look at it from Windows, **`Super +
Return` and every other Super binding does nothing** — Windows and WSLg both
claim the Super key first, so it never reaches the guest. `Super + Q` fires a
Windows shortcut instead.

The configuration is not at fault: `hyprctl binds` shows `modmask: 64` for the
binding, and it works on real hardware. Things that were tried and did **not**
help: QEMU's `Ctrl+Alt+G` input grab, `GDK_BACKEND=x11`, the SDL backend with an
explicit grab modifier, and VNC.

**This is a QEMU-layer dead end, not an unsolvable one.** Every attempt above
tries to fix it inside QEMU; the working fix lives in the host application.
[Try Omarchy for Windows](https://github.com/omacom/try-omarchy-windows)
delivers Super to a Hyprland guest by installing a low-level Windows keyboard
hook **scoped strictly to window focus** — swallowing Super only while the guest
window is foreground, passing it through otherwise. Their `docs/FINDINGS.md`
also records the trap in the naive version: SDL's own grab keeps suppressing the
Windows key even when the QEMU window is *not* focused, killing the Start menu
and `Win+Shift+S` system-wide until the grab is released with `Ctrl+Alt+G`.
Doing this for Archwright means a host-side launcher, which does not exist
today.

**Two cheaper things to try before writing one.**

*A native SPICE client — this is the recommended way to look at the VM from
Windows.* Every attempt listed above renders through WSLg, which is itself a
Windows application, so Windows claims Super before QEMU is involved at all. A
SPICE client running natively on Windows grabs the keyboard on its own side:
the same mechanism as the Go launcher, in software that already exists.

1. **Install virt-viewer on Windows** — the MSI from
   [virt-manager.org/download](https://virt-manager.org/download), under
   "Virt Viewer". It gives you `remote-viewer`, also in the Start menu as
   *Remote Viewer*.
2. **Start the VM from WSL as usual, with `--spice`:**

   ```sh
   wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash tools/boot-installed.sh --spice'
   ```

   No QEMU window opens. The script prints the exact URI to connect to, and
   **the serial console stays in this terminal** — the LUKS passphrase prompt
   arrives here, not in the graphical client.
3. **Connect from Windows** using the URI it printed, for example:

   ```
   remote-viewer spice://172.23.182.84:5930
   ```

   Or open *Remote Viewer* from the Start menu and paste the URI in.
4. **Press `Ctrl+Alt+G`** in that window to take the keyboard grab, and again
   to release it. That grab is the thing being tested.

> **Not `127.0.0.1`.** WSL2's localhost forwarding relays to the WSL VM's
> address, so a service bound to WSL's own loopback is invisible from Windows —
> measured, not assumed: a listener on `127.0.0.1` inside WSL was unreachable
> from the host while the same listener on the eth0 address answered
> immediately. The script binds to that address and prints it, because it
> changes when WSL restarts.

**What this mode does and does not give you**

| | |
|---|---|
| Graphical output | In the virt-viewer window. Resizes with it. |
| Keyboard, mouse | In that window. `Ctrl+Alt+G` grabs and releases. |
| LUKS passphrase, kernel console | **In the WSL terminal**, not the window — the test image puts the console on `ttyS0` |
| Audio | Routed over SPICE to the client, so virt-viewer plays it on the host. |
| Copy and paste with the host | Not set up — the guest has no `spice-vdagent` |
| `Super` and every binding | **Works.** virt-viewer is a native Windows application and receives the keys directly — no `Ctrl+Alt+G` needed. Focus governs it: click outside the window and Windows gets its keys back. |

Quitting: close the virt-viewer window and the VM keeps running — it is a
client, not the machine. Stop the VM itself with `Ctrl-A` then `X` in the WSL
terminal.

The disk is opened throwaway by default, so anything you break is discarded on
exit. Pass `--write` to keep changes.

*Move the modifier, for testing only.* The bindings are yours once seeded, so
one line at the end of `~/.config/hypr/hyprland.conf` makes all of them
reachable without Super:

```
$mod = ALT
```

`Alt + Return`, `Alt + Space`, `Alt + Q`. It changes nothing that ships and
nothing on real hardware — it is a local edit to a file the installer never
overwrites — and it makes a VM usable in about five seconds. Delete the line to
go back.

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

Every milestone is verified in QEMU on every change. That proves the
partitioning, encryption, filesystem, bootloader, session and application logic
is correct. It does **not** prove these, which no one has yet tested on physical
hardware:

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

The AI layer has its own limits worth stating plainly:

- **No agent is signed in.** Every one needs your own account or API key. The
  launcher is installed; authenticating is your first step.
- **Agent CLIs move fast.** The launchers pin nothing, so you get whatever is
  current the first time you run one. A breaking upstream change reaches you
  directly.
- **The commented auto-approve flags are not verified against every version.**
  They ship switched off, so a stale flag gives you an error rather than wrong
  behaviour — check the agent's own `--help` if one is rejected.
- **`sudo-window` is genuinely passwordless root** for as long as it is open.
  The auto-revert is tested, including that it fires when nothing is left
  running to trigger it. That does not make an open window safe to walk away
  from.

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
