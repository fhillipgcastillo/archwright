# Research Extract

Load-bearing facts distilled from a nine-part investigation of **Omarchy 4**
(v4.0.2, researched 2026-09-06) held in the author's Obsidian vault at
`Operating system/Custom OS Builder/Omarchy/`.

**Why this file exists.** Archwright's design references these facts. The vault
is not part of this repo and is not available to everyone who clones it, so
anything the build depends on is reproduced here. Each entry names its source
note so the original can be consulted when it is available.

**What this file is not.** It is not a description of Omarchy, and Archwright is
not a clone of it. Omarchy is MIT-licensed prior art that was studied; the facts
below are the transferable engineering knowledge extracted from that study.
Which of them Archwright actually adopts — and which were deliberately
rejected — is recorded in [`decisions.md`](decisions.md).

Source notes are cited as **P1**–**P9** (Omarchy Part 1 … Part 9) and **S**
(*Rebuilding Omarchy From Scratch — Synthesis*).

---

## 1. Session environment — the highest-value block in the whole extract

These are the variables that make Wayland behave. **P3**, from
`default/hypr/envs.lua`:

```
GDK_BACKEND=wayland,x11,*
QT_QPA_PLATFORM=wayland;xcb
QT_QPA_PLATFORMTHEME=gtk3
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
OZONE_PLATFORM=wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=Hyprland
XDG_SESSION_DESKTOP=Hyprland
XCURSOR_SIZE=24
HYPRCURSOR_SIZE=24
XCOMPOSEFILE=$HOME/.XCompose
```

Plus the compositor-side setting `xwayland = { force_zero_scaling = true }`.

Two facts about this block:

- **`XDG_CURRENT_DESKTOP=Hyprland` is what makes screen sharing work** in Google
  Meet and Discord (**P3**). Without it the portal cannot advertise the right
  backend.
- **`MOZ_ENABLE_WAYLAND=1` matters more to Archwright than to the source**, since
  Archwright defaults to Firefox rather than Chromium.

## 2. The slow-app-launch fix

**P3**, from `default/hypr/autostart.lua`. On session start, **before** starting
any session service:

```sh
systemctl --user import-environment $(env | cut -d'=' -f 1)
dbus-update-activation-environment --systemd --all
```

Commented in the source as the fix for slow application launches: systemd user
services and D-Bus activation need the session's environment, and they do not
inherit it automatically.

The rest of that autostart sequence, for shape: launch the shell, run first-run
provisioning, initialise power profiles, start the monitor watcher, start
`udiskie --automount --no-notify --no-tray`, then fire a `post-boot` hook after a
2-second delay.

## 3. Look-and-feel defaults

**P3**, from `default/hypr/looknfeel.lua`:

```lua
general    = { gaps_in = 5, gaps_out = 10, border_size = 2, layout = "dwindle" }
decoration = { rounding = 0, shadow = { enabled = false }, blur = { enabled = false } }
dwindle    = { preserve_split = true, force_split = 2 }
```

Square corners, **no blur, no shadows**. Animations on, with hand-tuned bezier
curves (`easeOutQuint`, `quick`, `almostLinear`), but **workspace animations
disabled** — instant jumps, no delay.

Also set: `disable_hyprland_logo`, `disable_splash_rendering`,
`cursor.hide_on_key_press`, `warp_on_change_workspace` (focus moves the cursor to
the newly focused window), and `allow_session_lock_restore` (lets a fresh shell
re-acquire the session lock if the lock client died — a real lockout-avoidance
measure).

## 4. Input and the compose key

**P3**, from `~/.config/hypr/input.lua`:

```
kb_options = "compose:caps,shift:both_capslock_cancel"
```

CapsLock becomes the XCompose key. This powers sequences like `CapsLock M S` → 😄
and `CapsLock Space E` → your email address, defined in `~/.XCompose`.

**It is also the source of a recurring "why isn't Caps Lock working?" support
question** (**P3**). `compose:ralt` moves it to right-Alt and gives CapsLock back.

`fcitx5` runs in every session and is what backs the compose sequences; CJK input
is then an added package away (`fcitx5-mozc`, `fcitx5-chinese-addons`).

## 5. Storage stack and bootstrap package set

**P2**. The `pacstrap` set laid down before anything else
(`builder/archinstall.packages`):

```
alsa-firmware   amd-ucode      base        base-devel
efibootmgr      intel-ucode    linux       linux-firmware
limine          omarchy-keyring            openssh
pipewire        snapper        sof-firmware
tailscale
```

Note what is **absent**: no GRUB, no systemd-boot. `snapper` is present in the
very first transaction so snapshots work from the start.

| Layer | Choice | Stated reason |
|---|---|---|
| Encryption | LUKS full-disk, default on | "Losing a laptop can't lead to a security emergency" |
| Filesystem | btrfs with subvolumes | Required for snapshots |
| Snapshots | snapper + `limine-snapper-sync` | Boot-menu-selectable rollback |
| Bootloader | **Limine** | The only bootloader supporting the snapshot boot menu |
| Boot image | UKI via mkinitcpio | `etc/mkinitcpio.conf.d/*_hooks.conf` |
| Splash | Plymouth | Themed unlock screen |
| Swap | zram (`zram-generator`) | archinstall's own zram config is removed and replaced |

**Snapper timer configuration** (**P2**, **S**): disable
`snapper-timeline.timer`; enable only `snapper-cleanup.timer` and
`limine-snapper-sync.service`. Snapshots are taken **on updates, not on a clock**.

**Snapshot limits** (**P8**): a restore covers `/` but **not `/home`**, so
`~/.config` survives a rollback. Rolling back to an older library version whose
config format differs must then be reconciled by hand. Snapshot rollback is
**unavailable on GRUB and systemd-boot** — this is the single reason Limine is
non-negotiable.

## 6. Never predict a partition number

**P2**, from `disk-partitioning.sh`, quoted directly:

> "Never predict a partition number. `parted` fills the lowest free GPT slot,
> not 'highest existing + 1', so any disk whose numbering has a hole — exactly
> what deleting a partition to free space leaves behind — hands back a number we
> did not choose."

The defensive sequence that follows from it:

1. Read back what was actually created via `parted -ms … print`.
2. Assert the returned number is genuinely new. *This is the safety property
   that stops the installer ever formatting someone else's partition.*
3. Verify created size against requested size within a 1 MiB tolerance.
4. Handle NVMe / mmcblk `pN` naming, which differs from `sdaN`.
5. Track `created_parts[]` so a rollback undoes **exactly** what this run made.

## 7. Two orderings that are load-bearing

**P2**:

**Packages before `useradd`.** Packages that populate `/etc/skel` must be
installed *before* the user is created, or the new home directory is seeded
wrong. There is no second chance — `useradd` copies `/etc/skel` once.

**Mask the mkinitcpio install hook during the hardware phase.** The
`limine-entry-tool` hook triggers on `usr/lib/firmware/*`,
`usr/src/*/dkms.conf` and `usr/lib/modules/*/pkgbase`. The hardware phase
routinely installs exactly such packages (`sof-firmware`, `nvidia-open-dkms`,
patched kernels), and each one would trigger **a full initramfs + UKI rebuild for
every installed kernel** — all discarded by the final unconditional rebuild.
Kernel *removal* hooks must stay live.

**P9** adds two more from the hardware sequence itself:

- **Swap the kernel before anything pulls DKMS modules.** Building DKMS modules
  against the stock kernel and then rebuilding them against a patched one cost
  ~25 s of install time in the measured case.
- **Anything that rebuilds the boot image runs after the kernel swap**, which is
  why one vendor script is deliberately separated from its siblings in the
  sequence.

The general principle: *group operations by the expensive artifact they
invalidate, and rebuild that artifact once at the end.*

## 8. Services, masks and firewall

**P2**. Services enabled at install (enabled, not started — install is followed
by a reboot):

```
NetworkManager.service        systemd-resolved.service   systemd-oomd.service
power-profiles-daemon.service cups.service               avahi-daemon.service
docker.socket                 sddm.service               linux-modules-cleanup.service
```

**`NetworkManager-wait-online.service` is masked** so `graphical.target` never
blocks on DHCP or Wi-Fi association — "nothing in the session needs to block on
the network." This is a visible boot-time win.

Firewall, configured at install:

```sh
ufw default deny incoming
ufw default allow outgoing
ufw allow 53317/udp && ufw allow 53317/tcp   # LocalSend, the only open port
```

`ufw` is **enabled but not started** during install (`ENABLED=yes` in
`/etc/ufw/ufw.conf` plus `systemctl enable ufw`), because the target chroot
shares the live installer's kernel firewall and activating it would mutate the
live session. Archwright inherits this constraint exactly — the same chroot
situation applies.

## 9. System tuning worth setting

**P2**, the `etc/` drop-ins a polished system bothers to ship:

- `sysctl.d/` — inotify watcher limits (dev tooling hits these constantly), plus
  general tuning
- `systemd/system.conf.d/` and `user@.service.d/` — shorter shutdown timeouts
- `systemd/*/20-*-nofile.conf` — raised file descriptor limits
- `systemd/oomd.conf.d/` — kill one runaway app scope rather than letting reclaim
  thrashing take the whole session down
- `systemd/logind.conf.d/` — ignore power button, inhibit delay
- `systemd/resolved.conf.d/` — disable multicast
- `modprobe.d/` — USB autosuspend
- `security/faillock.conf` — lockout policy
- `NetworkManager/conf.d/` — Wi-Fi powersave
- `sudoers.d/` — **narrow, single-purpose grants**, never blanket ones

## 10. The ownership contract

**P6**. The single most important structural rule:

| Path | Owner | Rule |
|---|---|---|
| `~/.config/**` | The user | Never overwritten by updates |
| `/usr/share/<name>/**` | The system | Package-owned. Edits lost on next update |
| `~/.bashrc` | The user | Explicitly never overwritten — where user aliases live |

> "If you need to change anything in `/usr/share/omarchy`, you should be
> overwriting the value in `~/.config` instead."

**The Lua search path that enforces it** (**P6**), in priority order:

```lua
~/.local/state/?.lua   -- generated state (theme output, toggles)
~/.config/?.lua        -- the user's modules
$SYSTEM_PATH/?.lua     -- shipped defaults
```

`package.loaded` is cleared for the relevant prefixes on reload, so a config
reload genuinely re-reads files rather than serving cached modules.

**Config restore leaves a `.bak`** (**P6**, **P8**) rather than discarding the
user's version.

## 11. Toggle flags named for the off state

**P7**. Toggles are flag files under `~/.local/state/<name>/toggles/`, named for
the **off** state — `screensaver-off`, `suspend-off`, `bar-off` — so *presence
means disabled*. Scripts branch on an exit code:

```sh
<name>-toggle-enabled screensaver-off && echo "screensaver is off"
```

Why this is the right way round: the default state needs no file, so a fresh
install and a reset install are byte-identical, and a missing state directory
degrades to "everything on" rather than "everything off."

## 12. Theming

**P6**. One `colors.toml` regenerates configuration for: Hyprland borders;
terminals (Foot, Alacritty, Ghostty, Kitty); btop; the browser; Neovim; Helix;
VSCode; Obsidian; the shell (bar, menu, notifications, OSD, lock); Plymouth boot
unlock; the login greeter; icons; and the AI agent CLIs.

**The user-template escape hatch.** Templates in `~/.config/<name>/themed/`,
named after the config they generate plus `.tpl`:

```
{{ background }} {{ foreground }} {{ accent }} {{ red }}
{{ color0 }} … {{ color15 }}      with _strip and _rgb modifiers
```

Regenerated on every theme switch. **User templates take priority over shipped
ones**, so this also overrides how a built-in target is themed. A commented
`.tpl.sample` ships in that folder as documentation.

**Install-time sanitization — the security rule.** A theme installed from
someone else's repo loses **every file that could execute**:

| Stripped | Why |
|---|---|
| any `.lua` | A theme's `hyprland.lua` is Lua the compositor runs at login |
| `alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf` | A terminal config names the program the terminal starts |
| `vscode.json` | Names a VSCode extension to install |

Everything colour-bearing survives, and the stripped files are regenerated from
`colors.toml` locally.

> "Installing someone's theme should change what your desktop looks like, never
> what it runs."

## 13. Display scaling

**P6**. The most common "why is everything huge" complaint comes from a default
that assumes a retina-class display (`GDK_SCALE = 2`).

```lua
-- 27"/32" 4K — fractional scaling
gdk_scale = 2 ; monitor_scale = 1.6
-- 1080p / 1440p
gdk_scale = 1 ; monitor_scale = 1
```

**GTK honours only whole numbers for `GDK_SCALE`**, so it must be set to the
nearest integer of the monitor scale — they are not the same knob. Scale changes
apply only to applications started *after* the change.

## 14. The unified clipboard

**P7**. The signature ergonomic, and the cheapest large win in the whole system:

| Key | Action |
|---|---|
| `Super + C` | Copy |
| `Super + X` | Cut (not in terminal) |
| `Super + V` | Paste |
| `Super + Ctrl + V` | Clipboard history, text and images, searchable |

The problem it solves: on Linux you normally need `Ctrl + Shift + C/V` in the
terminal and `Ctrl + C/V` everywhere else. These work **everywhere, including the
terminal**.

Caveat worth carrying forward: most AI agent harnesses still use `Ctrl + V` for
pasting images.

## 15. Hardening decisions and their reasons

**P8**. Each is a case where friction was chosen over convenience, with a stated
reason — the reasons are the transferable part.

| Decision | Reason |
|---|---|
| **User NOT added to the `docker` group** | "That group is effectively passwordless root — anything in it can `docker run -v /:/host` and take over the machine. So a single rogue script or dependency running as you would otherwise be one command away from root." |
| `ufw-docker` rules installed | Containers cannot accidentally publish past the firewall |
| Privileged compose files root-owned | So a process running as the user cannot rewrite one and have a privileged bring-up mount the whole disk |
| Bind-mount by inode onto root-owned anchors | Prevents another process swapping a checked path before a privileged consumer reads it (a TOCTOU defence) |
| QR decode output goes only to the clipboard, marked sensitive | QR codes routinely carry `otpauth://` 2FA secrets; never log them |
| Installed themes stripped of executables | §12 |
| Plugin install never runs plugin code | Clone, validate manifest, flip a bit over IPC. No install hook, no sudo |
| Login-manager PAM keyring lines removed | Prevents password logins creating an encrypted keyring that conflicts with the passwordless default |
| `faillock` lockout tuned at install | With a documented recovery path: `Ctrl + Alt + F2`, log in as root, `faillock --reset --user <name>` |

## 16. Time-boxed passwordless sudo

**P8**. Turns `sudo` prompts off for **15 minutes and then puts them back
automatically**. A different window can be requested; running the command again
ends it early.

Framed explicitly for "when an AI agent is doing a long stretch of system work
for you," with the risk stated plainly:

> "while it's on, anything running as your user can do anything as root without
> being asked."

This is strictly better than a permanent `NOPASSWD` line because it fails closed:
an abandoned or crashed session reverts on its own.

## 17. The update guard

**P8**. Everything goes through one command, which:

1. Takes a snapshot
2. Installs the latest release
3. Runs pending migrations
4. Updates system packages

A bare `pacman -Syu` is **actively blocked**, because it would skip the snapshot,
the migrations and the config updates. The guard documents how to bypass it for a
single transaction.

**Escape hatches, in order of severity** — a good model for what a recovery story
should cover:

| Problem | Fix |
|---|---|
| Bad update | Boot the pre-update snapshot from the bootloader menu |
| One broken config | Restore that individual file |
| All configs broken | Reinstall configs |
| Everything broken | Full reinstall: default packages restored, anything too new downgraded, every config reset |

## 18. Self-documenting CLI

**P7**. ~450 scripts behind a single dispatcher. Every command carries metadata:
group, summary, usage, args, examples, whether it needs sudo, aliases. So
`--help` works at every level, and there is a `--check` that **validates command
metadata and route collisions**.

The stated reason this design exists is worth quoting:

> "This is particularly helpful when you're having an AI agent work with you on
> customization or configuration."

The CLI *is* the machine-readable API the agent skill uses. `--json` output is
part of that contract, not a nicety.

## 19. Package choices worth carrying over

**P4**. The modern CLI replacement set, with what each replaces:

| Package | Replaces |
|---|---|
| `eza` | `ls` |
| `bat` | `cat` (also colours man pages) |
| `fd` | `find` |
| `ripgrep` | `grep` |
| `fzf` | — (fuzzy finder, paired with `bat` preview) |
| `zoxide` | `cd` |
| `dua-cli` | `du` |
| `btop` | `top` |
| `tldr` | `man` |
| `fastfetch` | `neofetch` |

Font: **JetBrainsMono Nerd Font**, terminal *and* system. When offering
alternative fonts, offer **Nerd Font versions**, or the glyphs in the bar and
terminal break.

Terminal: **Foot** — "fast, lightweight, and compatible with even old computers",
at the cost of no native tabs or splits, which is why a multiplexer is paired
with it. Also noted (**P6**): **Foot cannot reload its config**, so running
terminals keep the old settings after a font or theme change.

## 20. Hardware enablement — the honest scope

**P9**, **S**. Roughly 45 detection scripts, two patched kernels, a dozen DKMS
packages and per-model speaker tunings.

> "None of this is visible in a screenshot, and all of it is why 'just install
> Arch + Hyprland yourself' gets you 80% of the look and maybe 30% of the
> hardware reliability."

The structural pattern, which is what transfers:

- One script per fix. Each **probes for its hardware and does nothing if
  absent**, so the whole set can run unconditionally.
- The sequence is fixed and explicitly ordered, not alphabetical (§7).
- A separate **user-level** pass for fixes belonging to the session rather than
  the system.

The advice from **S** is to scope this to *one machine* and grow it only when
something breaks — "it is the accumulated residue of a user base, not a design."
The three to get right first: **GPU driver selection, suspend/resume, audio**.

Graphics selection, for reference: NVIDIA picks among `nvidia-open-dkms`,
`nvidia-dkms` and a legacy branch, plus `egl-wayland` for Wayland; Intel takes
`vulkan-intel`, `intel-media-driver`, `libva-intel-driver`; AMD takes
`vulkan-radeon`.

## 21. How they know it works

**P8**. Unusual for a project of this size, and the part a rebuild is most likely
to skip:

- A real interactive install driven in a **headless VM**, reading each screen via
  QMP screendumps plus OCR and answering with virtual keystrokes — so the
  installer wizard, dashboard, reboot prompt and login are exercised as a user
  would.
- It then boots the installed system, sends real keyboard shortcuts, and runs an
  acceptance suite against session health, the package manifest, defaults,
  applications, menus, panels, launchers, notifications and clipboard.
- Visual checkpoints saved as `success-<step>.png` / `failure-<step>.png`.
- **Independent tests continue after a failure**, "so one broken surface does not
  hide the rest of the report."
- Integration scenarios boot from a generated unattended-config drive, each on a
  **throwaway overlay with its own firmware vars**, so no disk or NVRAM state
  leaks between runs.

The throwaway-overlay-plus-separate-firmware-vars detail is directly applicable
to Archwright's VM oracle and easy to get wrong.

## 22. Unattended install via a `cidata` drive

**P2**. A second drive labelled `cidata` — the cloud-init *NoCloud* label, which
Proxmox, libvirt and Packer already understand — skips the interactive wizard
entirely.

Two caveats stated outright in the source:

- **Encrypted unattended installs are not fully unattended** — someone still
  types the LUKS passphrase at first boot.
- The config file carries that passphrase **in plaintext**. Treat the drive as
  the secret it is.

## 23. Scoping guidance

**S**. Three scopes, to be chosen *before* starting:

| Scope | What it is | Effort |
|---|---|---|
| **A** — "for me" | A dotfiles repo plus an install script. Skip delivery and hardware layers entirely | A weekend, then ongoing tinkering |
| **B** — "for my machines" | A + reproducible installs: an ISO profile, unattended config, snapshots. Still no package repo | Weeks |
| **C** — "a distribution others install" | Everything: signing packages, running a mirror, hardware bug reports, migrations forever | Months, ongoing |

> "The failure mode is starting at scope C and discovering scope A's problems."

The central finding, which is why Archwright is scoped where it is:

> "The hard part is not the desktop. It's the delivery system." Roughly **80% of
> the engineering** is in the package repo, mirror, ISO, migrations, snapshot
> wiring and hardware scripts — "and none of it shows up in a screenshot."

**Archwright is scope A, with two deliberate borrowings from B**: snapshots, and
an unattended answer file. See [`decisions.md`](decisions.md).
