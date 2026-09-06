# Archwright — Design

**Date:** 2026-09-06
**Status:** Approved design, pre-implementation
**Source research:** the nine-part Omarchy investigation in the Main Vault
(`Operating system/Custom OS Builder/Omarchy/`), in particular
`Rebuilding Omarchy From Scratch — Synthesis` and
`Installable Version Roadmap — Synthesis`.

---

## 1. What this is

**Archwright** is an opinionated base Arch Linux system — Hyprland on Wayland,
a small curated application set, and first-class AI-agent tooling — delivered
two ways:

- **Path 1 — The Guide.** A human-readable walkthrough that builds the system
  by hand, explaining *why* at each fork. Written to be published as-is. Lives
  in the Obsidian vault at `Operating system/Custom OS Builder/`.
- **Path 2 — The Installer.** A standalone git repo at `E:\data\dev\archwright`.
  One command, run from the stock Arch ISO, produces the same system.

They describe **one** target system. The Guide is the specification; the
Installer is its automation.

Archwright is *not* a distribution. There is no package repository, no mirror,
no signing key, no release channels. It is Arch plus a decided set of packages
and configuration, installed by a script and documented by a guide.

### The name

`archwright` is the project name, the repo name, the CLI command, and the
`/usr/share` path. A *wright* is a maker (shipwright, wheelwright, playwright);
an archwright builds arches. Frequently-used verbs get short aliases so the
ten-letter command is typed rarely.

---

## 2. Scope

### In scope

Base install (UEFI, LUKS2, btrfs, Limine, snapper), Hyprland session, an
assembled shell layer behind a swap boundary, a two-tier application set, the
AI-agent layer, install-time theming, minimal hardware enablement, the
`archwright` CLI, and the Guide.

### Out of scope

| Excluded | Why |
|---|---|
| Own package repo, mirror, signing key, release channels | This is what makes something a distribution. Explicitly not the goal |
| Custom ISO (`archiso`) | Deferred. The manifest layout is designed so an ISO profile could later consume it |
| Migration system | Not needed until there are installs in the field to migrate |
| Quickshell single-process shell | Deferred behind the shell swap boundary (§6) |
| Crash diagnosis via `systemd-coredump` | Considered and cut — meaningful code for a niche benefit |
| Agent usage/quota tracking panel | Considered and cut — per-vendor API scraping that breaks on every vendor change |
| Runtime theme-switching engine | Install-time palette application only (§8) |
| Dual-boot / install-alongside | v1 wipes the chosen disk. Detecting and preserving existing OSes is a separate project |

---

## 3. The decided opinions

Deciding these *is* the design; configurability is deliberately limited.
Entries marked ⚙️ are single-line changes in `manifest/`.

| Job | Choice | Reasoning |
|---|---|---|
| Base | Arch Linux, official mirrors | No own mirror |
| Firmware | UEFI + GPT only | No BIOS/MBR path |
| Disk encryption | LUKS2 container | |
| Filesystem | btrfs, subvolumes `@ @home @snapshots @log @pkg` | |
| Bootloader | Limine + UKI | The only bootloader in scope that renders a snapshot boot menu |
| Snapshots | snapper; `snapper-timeline.timer` **disabled**, `snapper-cleanup.timer` + `limine-snapper-sync.service` **enabled** | Snapshots on update, not on a clock |
| Initramfs | mkinitcpio → UKI, Plymouth | |
| Login | ⚙️ greetd + tuigreet | One config file, no Qt/GTK dependency chain |
| Session | uwsm → Hyprland | |
| Compositor | Hyprland | |
| Shell layer | waybar · mako · walker · hyprlock · hypridle · swaybg | Behind the swap boundary (§6) |
| Terminal | ⚙️ foot | Small, Wayland-native |
| Browser | ⚙️ Firefox | Chromium available in `extras` |
| Editor | ⚙️ Neovim | |
| File manager | ⚙️ Nautilus | |
| Audio | pipewire, pipewire-pulse, pipewire-alsa, wireplumber | |
| Network | NetworkManager, `NetworkManager-wait-online.service` masked | Masking prevents a boot-time stall |
| Firewall | ufw, deny-all-inbound | |
| Font | JetBrainsMono Nerd Font | |
| Modifier convention | Super is the centre of everything; unified `Super + C/X/V` clipboard that also works in the terminal | |

### Session environment

The environment block is copied verbatim from the research —
`XDG_CURRENT_DESKTOP=Hyprland`, `ELECTRON_OZONE_PLATFORM_HINT=wayland`,
`xwayland.force_zero_scaling` and the rest. These are the small facts that
otherwise take weeks to rediscover.

Autostart runs `systemctl --user import-environment` and
`dbus-update-activation-environment --systemd --all` **before** starting session
services. This is the documented fix for slow application launches.

---

## 4. Repository layout

```
archwright/
├── install.sh                  Entry point. Run from the stock Arch ISO
├── archwright                  The installed CLI (copied to /usr/bin)
├── lib/
│   ├── common.sh               Logging, chroot helper, assertions, rollback tracking
│   ├── 00-preflight.sh         UEFI check, network, clock sync, disk selection
│   ├── 10-disk.sh              GPT, ESP, LUKS2, btrfs subvolumes
│   ├── 20-base.sh              pacstrap from manifest/core.packages
│   ├── 30-boot.sh              mkinitcpio UKI, Limine, snapper, Plymouth
│   ├── 40-desktop.sh           Hyprland, greetd, shell layer + units
│   ├── 50-apps.sh              Core apps, then selected extras
│   ├── 60-ai.sh                Agent stubs, skill symlinks, sudo window, local model
│   └── 70-hardware.sh          Dispatches hardware/*.sh
├── manifest/                   Shared source of truth for both paths
│   ├── core.packages
│   ├── extras.packages
│   ├── subvolumes.tsv
│   └── hotkeys.tsv
├── config/                     Dotfiles installed to /usr/share/archwright/default-config/
│   ├── hypr/  waybar/  mako/  walker/  foot/  greetd/
│   ├── shell/                  The swappable boundary (§6)
│   └── themed/                 Theme templates (§8)
├── hardware/                   One self-detecting script per quirk
├── test/
│   ├── vm-install.sh           QEMU UEFI end-to-end (Linux host) — primary oracle
│   ├── vm-install.ps1          Same flow, Windows host
│   ├── answers.example.conf    Unattended answer file for test runs
│   └── check-guide-drift.sh    Guide tables vs manifest/
├── tools/
│   └── fetch-qemu-windows.ps1  Portable QEMU + OVMF into .tools/, nothing system-wide
├── docs/
└── README.md
```

---

## 5. Ownership split

Established on day one; retrofitting it is painful.

| Path | Owner | Rule |
|---|---|---|
| `/usr/share/archwright/` | Archwright | Ours. Never hand-edited. Replaced wholesale on update |
| `~/.config/` | The user | Never overwritten by an update |
| `~/.local/state/archwright/` | Generated | Current theme, toggle flags, default agent |

Two rules that follow from it:

- The installer seeds `~/.config` from `/usr/share/archwright/default-config/`
  **only when the target is absent**. Any restore or reinstall of a config
  leaves the previous version as `.bak` rather than discarding it.
- Toggle flags are **named for the off state**, so presence means disabled and
  a shell script can branch on `[ -e ... ]`.

---

## 6. The shell swap boundary

The desktop furniture is assembled from separate mature packages, but it is
isolated so it can be replaced as a unit.

- Each component (waybar, mako, walker, swaybg) gets a systemd **user** unit.
- All of them are `WantedBy=archwright-shell.target`.
- Hyprland's autostart starts that one target, and nothing else.
- **No code in the base, apps, AI or hardware layers references waybar, mako or
  walker by name.** Only `config/shell/` and the units do.

Replacing the entire furniture layer later — with Quickshell or anything else —
is then: write one unit, repoint the target. This costs a small amount of
structure now and is the reason it is worth doing now rather than later.

---

## 7. Application set

Two tiers, both defined in `manifest/`.

**Core** (`core.packages`) — installed always. One tool per job: terminal,
browser, editor, file manager, image viewer, video player, PDF viewer, plus the
CLI staples (git, lazygit, btop, ripgrep, fd, fzf, fastfetch), the audio and
network stack, and the shell layer.

**Extras** (`extras.packages`) — offered by the installer, documented as
optional sections in the Guide. Grouped: office, media production, gaming,
containers, Chromium, Ollama, and additional agent CLIs.

Both files are plain newline-delimited package lists with `#` comments and
`## Group:` headers that `check-guide-drift.sh` parses.

---

## 8. Theming

**Install-time only.** One `colors.toml` is fanned out during installation to
foot, Hyprland, waybar CSS, mako, walker, btop and Neovim. There is no runtime
theme-switching engine.

Two things kept from the research because they cost almost nothing:

- **The template escape hatch.** `config/themed/*.tpl` with `{{ background }}`,
  `{{ color0..15 }}` placeholders and `_strip` / `_rgb` modifiers. A user
  template in `~/.config/archwright/themed/` **outranks** the shipped one.
- **Install-time sanitization.** When importing an external theme, every file
  that could execute is stripped — `.lua`, terminal configs, editor JSON.
  Installing a theme changes what the desktop *looks like*, never what it *runs*.

**Firefox is best-effort.** Firefox gets a `policies.json` for sane defaults and
native Wayland, but its chrome does not recolour from `colors.toml` the way the
other targets do. This is an accepted limitation, documented in the Guide.

---

## 9. AI layer

Four pieces, one deliberate divergence from the researched original.

### 9.1 Lazy agent stubs

`mise`-backed stubs in `~/.local/bin/` for `claude`, `codex`, `opencode`, `pi`,
`crush` and `gh`. Nothing downloads until first invocation, so shipping a dozen
costs nothing. `archwright mise-install <package> [command]` wraps any
additional CLI the same way.

### 9.2 Default agent

`archwright default agent <name>` writes to
`~/.local/state/archwright/default-agent`.

- `Super + Shift + Ctrl + A` — launch it in a dedicated terminal window
- `a` — run it inline in the current terminal
- Launches from `$HOME` are redirected to `~/Work`, because agents refuse to
  trust the home directory

**Divergence — auto-approve flags ship commented out.** The researched original
ships aliases that run agents in unattended, don't-stop-to-ask modes
(`--permission-mode auto` and equivalents). Archwright ships those flags present
but commented, with the warning attached. Granting an unattended agent
root-adjacent access to a freshly installed system should be a deliberate choice,
not an inherited default.

### 9.3 Shared agent skill directory

`~/.local/share/archwright/agent-skills/`, symlinked into `~/.claude/skills`,
`~/.codex/skills`, `~/.pi/agent/skills` and `~/.agents/skills`. Ships one skill
describing Archwright's own layout and conventions, so any agent on the system
already knows where things live.

### 9.4 Time-boxed passwordless sudo

`archwright sudo-window [minutes]` (default 15) writes a NOPASSWD drop-in to
`/etc/sudoers.d/`, **validated with `visudo -c` before it is moved into place**,
and schedules a transient systemd timer to remove it. Auto-reverting, so a
crashed or abandoned session cannot leave the window open. Strictly better than
a permanent NOPASSWD line for agent work.

### 9.5 Local models

Ollama lives in `extras`, not core — it is multi-gigabyte and not everyone wants
it. The Guide documents pointing the agent CLIs at a local endpoint, cross-linked
to the existing vault notes `Setup Local AI en mi PC` and
`Connect Claude Code, opencode & Pi to Local llama.cpp`.

---

## 10. Hardware enablement

Deliberately minimal, and structured to grow one fix at a time.

- Target is **generic x86_64 UEFI**. No vendor matrix.
- `hardware/*.sh`, each script: **detect → apply, or no-op when the hardware is
  absent.** Ordering is explicit and numbered, because it matters.
- Ships with GPU driver selection (Intel / AMD / NVIDIA) and placeholders for
  suspend/resume and audio — the three that cover most of the pain.
- Re-runnable after install via `archwright hardware`.
- **Mask the mkinitcpio install hook during the hardware phase.** Otherwise every
  firmware and DKMS package triggers a full initramfs + UKI rebuild for every
  installed kernel, all of it discarded by the final unconditional rebuild.

---

## 11. Installer behaviour

### Partitioning rule

**Never predict a partition number.** `parted` fills the lowest free GPT slot.
The installer reads back what was actually created, asserts the number is
genuinely new, verifies the size within tolerance, and records exactly what this
run created so a rollback undoes only that.

### Phase ordering

Two orderings are load-bearing:

1. **Install skeleton-seeding packages before `useradd`**, so `/etc/skel` is
   populated when the home directory is created.
2. **Mask the mkinitcpio install hook during the hardware phase** (§10).

### Unattended installs

`install.sh --answers <file>` reads a plain key=value answer file (disk,
hostname, username, locale, timezone, extras selection). This is what the VM
oracle drives, and it makes the same script usable for repeatable installs.

### Update guard

`archwright update` snapshots, then updates, then runs any pending work. The
Guide documents intercepting bare `pacman -Syu` so a user cannot silently skip
the snapshot — with a documented bypass for a single transaction.

---

## 12. The `archwright` CLI

Subcommand dispatch, `--help` at every level, `--json` where output is
structured. Self-documenting, which also makes it the machine-readable interface
the AI agents use.

| Command | Purpose |
|---|---|
| `archwright update` | Snapshot, then update |
| `archwright snapshot [list\|create\|restore]` | Snapper wrapper |
| `archwright default <browser\|editor\|agent\|terminal> <value>` | Set an XDG or Archwright default |
| `archwright agent [prompt <text>]` | Launch the default agent |
| `archwright theme <name>` | Re-apply the palette fan-out |
| `archwright sudo-window [minutes]` | Time-boxed passwordless sudo |
| `archwright hardware` | Re-run hardware detection |
| `archwright mise-install <pkg> [cmd]` | Add a lazy CLI stub |

Short aliases are installed for the frequent verbs so the ten-letter name is
rarely typed in full: `awu` (update), `aws` (snapshot), `awa` (agent),
`a` (run the default agent inline). These are shell aliases in the shipped
bash/zsh config, not separate binaries, so they never collide on `PATH`.

---

## 13. Verification

Nothing is "done" on inspection. Every milestone ends in a boot that either
works or does not.

### Primary oracle — `test/vm-install.sh`

QEMU with OVMF UEFI firmware and a blank qcow2. Boots the stock Arch ISO, runs
`install.sh --answers test/answers.example.conf`, reboots, and asserts:

1. The LUKS passphrase prompt appears
2. The system boots to a login greeter
3. A Hyprland session starts (`hyprctl version` succeeds in the session)
4. `snapper list` shows at least one snapshot
5. The Limine boot menu contains a snapshot entry

### Supporting checks

| Check | What it proves |
|---|---|
| `test/check-guide-drift.sh` | The Guide's package and hotkey tables match `manifest/`. Non-zero exit on mismatch |
| `shellcheck` across all scripts | No shell footguns |
| Idempotency run | Re-running post-install phases changes nothing |

### Host support for the oracle

- **Linux host:** `qemu-system-x86_64` + `edk2-ovmf` from the distro's package
  manager. `test/vm-install.sh`.
- **Windows host:** `tools/fetch-qemu-windows.ps1` downloads a portable QEMU
  build and OVMF firmware into `.tools/` inside the repo — nothing installed
  system-wide, nothing added to `PATH`, deleting the folder undoes it.
  `test/vm-install.ps1` then runs the same flow.
- **WSL2:** documented as a fallback only. Nested virtualization must be enabled
  or the VM runs unaccelerated and is impractically slow.

---

## 14. Build order

Each milestone is gated on its own VM boot.

| # | Milestone | Gate |
|---|---|---|
| 1 | Base install: UEFI, LUKS2, btrfs subvolumes, Limine, snapper. No desktop | VM boots to a TTY after a LUKS prompt; `snapper list` non-empty; Limine shows a snapshot entry |
| 2 | Session stack: greetd → uwsm → Hyprland | VM reaches a Hyprland session |
| 3 | Shell layer behind `archwright-shell.target` | Bar, launcher, notifications, lock all functional; target stop/start cycles them cleanly |
| 4 | Applications: core, then extras selection | Core apps launch; extras selection honoured from the answer file |
| 5 | AI layer: stubs, skills, sudo window, Ollama in extras | A stub installs on first run; skill symlinks resolve; sudo window grants and auto-reverts |
| 6 | Hardware hooks, `archwright` CLI, install-time theming | `archwright --help` at every level; palette fan-out lands in all targets; hardware scripts no-op cleanly in a VM |
| 7 | **The Guide**, written against the verified installer | `check-guide-drift.sh` exits zero |

The Guide is written **last, from a system that provably works**, so it documents
reality rather than intention. Last in sequence, not last in importance.

---

## 15. Guide structure (Path 1)

Vault note in `Operating system/Custom OS Builder/`, following the vault's
conventions: Title Case filename, HQLS frontmatter (`type: note`, `origin: ai`,
`ai/draft`, `Links: "[[HQLS + LLM-Wiki Adaptation]]"`), linked from
`Custom OS Build Guides — MOC` and the Omarchy MOC.

Structure mirrors the build order:

1. What you are building, and the decisions behind it
2. Preparing the install medium
3. Disk: GPT, ESP, LUKS2, btrfs subvolumes
4. Base system and `pacstrap`
5. Boot: mkinitcpio UKI, Limine, snapper, Plymouth
6. Session: greetd, uwsm, Hyprland
7. The shell layer
8. Applications — core, then optional extras
9. The AI layer
10. Theming
11. Hardware notes
12. **Appendix: try it in a VM first** — Linux track and Windows track
13. **Appendix: the automated path** — pointer to the installer repo

The main body assumes bare metal on any UEFI machine and makes no host-OS
assumptions. The VM appendix is where Windows and WSL2 are addressed.

---

## 16. Sync model

Both paths read the same facts from `manifest/`:

- The installer reads `manifest/*.packages` at runtime — no package list is
  hardcoded in `lib/`.
- **Hyprland's keybind block is generated from `manifest/hotkeys.tsv`** at
  install time, not hand-written in `config/hypr/`. The generated file carries a
  "do not edit" header and user overrides go in a separate sourced file. This
  makes the manifest authoritative for what the system actually does, rather
  than a third copy that can disagree with both the config and the Guide.
- The Guide's package and hotkey tables are checked against `manifest/` by
  `test/check-guide-drift.sh`, which exits non-zero on mismatch.

Prose stays hand-written. Only the facts are pinned. The same manifest files are
what an `archiso` profile would consume if the ISO path is ever taken up.

---

## 17. Open items

None blocking. Deferred decisions are recorded in §2 as out of scope.

Before the repo is published, check GitHub and the AUR for an existing
`archwright` so the name is genuinely free.
