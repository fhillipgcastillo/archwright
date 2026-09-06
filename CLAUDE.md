# Archwright — working notes for AI assistants

Archwright is an opinionated base Arch Linux system (Hyprland on Wayland, a small
curated app set, AI-agent tooling) delivered two ways: a hand-build **guide** and
an automated **installer**.

Read these before changing anything:

| File | What it holds |
|---|---|
| `docs/superpowers/specs/2026-09-06-archwright-design.md` | The specification. What the system is |
| `docs/decisions.md` | Every fork, what was rejected, and why. Read before proposing an alternative — it may already have been considered and ruled out |
| `docs/research-extract.md` | The load-bearing technical facts the build depends on, distilled from prior-art research. Self-contained; do not go looking for the original notes |

---

## ⚠️ The safety rule specific to this repo

**This repository contains code that partitions and formats disks.**

- **Never execute `install.sh`, anything in `lib/`, or any `parted` / `mkfs` /
  `cryptsetup` / `dd` command on the development machine.** Not to "check it
  runs," not with `--dry-run` unless that flag is implemented and verified, not
  ever.
- The **only** place installer code runs is inside the QEMU VM driven by
  `test/vm-install.sh` (or `test/vm-install.ps1`), against a throwaway qcow2.
- When reasoning about installer behaviour, read the script. Do not run it.
- The development host is **Windows**; the installer targets **Arch Linux**. Any
  command in `lib/` is written for the target, never for the host shell.

If a change cannot be verified without running installer code outside a VM, that
is a signal the change needs a test harness, not an exception.

---

## Repository conventions

- **Shell:** POSIX-compatible `bash`, `set -euo pipefail` at the top of every
  script. All scripts must pass `shellcheck` clean.
- **No hardcoded package lists in `lib/`.** Packages come from `manifest/`, read
  at runtime. This is a hard rule — the guide/installer drift check depends on it
  (see D9 in `docs/decisions.md`).
- **No layer outside `config/shell/` and the shell units may name `waybar`,
  `mako`, `walker` or `swaybg`.** The shell is behind a swap boundary
  (D3). Reference `archwright-shell.target` instead.
- **Ownership split is absolute:** `/usr/share/archwright/` is ours and is never
  hand-edited; `~/.config/` is the user's and is never overwritten; generated
  state goes in `~/.local/state/archwright/`. Seeding a user config happens only
  when the target is absent, and any restore leaves a `.bak`.
- **Toggle flags are named for the OFF state** — presence means disabled.
- **Filenames and prose** follow the guide's voice: explain *why*, not just what.

---

<!-- BEGIN vdf-project-specifics -->
## Project specifics

Stack: POSIX `bash` installer scripts targeting Arch Linux, plus a PowerShell
helper for Windows-hosted VM testing. No build step, no package manager, no
compiled artifacts.

| Job | Command | Notes |
|---|---|---|
| **Test** (primary oracle) | `bash test/vm-install.sh` | Full end-to-end: QEMU + OVMF UEFI, blank qcow2, stock Arch ISO, unattended install from `test/answers.example.conf`, reboot, assert LUKS prompt → boot → Hyprland session → snapper snapshot → Limine snapshot entry. Each run uses a throwaway overlay with its own firmware vars |
| **Test** (Windows host) | `pwsh test/vm-install.ps1` | Same flow. Requires `pwsh tools/fetch-qemu-windows.ps1` once, which puts portable QEMU + OVMF in `.tools/` |
| **Lint** | `shellcheck install.sh lib/*.sh hardware/*.sh test/*.sh` | Must be clean. No `# shellcheck disable` without an inline reason |
| **Typecheck** | *n/a* | Shell project |
| **Build** | *n/a* | No build step |
| **Docs check** | `bash test/check-guide-drift.sh` | Verifies the guide's package and hotkey tables match `manifest/`. Non-zero exit on mismatch |
| **Run a single flow** | `bash test/vm-install.sh --phase <n>` | Runs the installer up to milestone *n* and asserts that milestone's gate only. Faster iteration than the full run |

**Oracle by change type:**

- **Installer logic** → the VM run. A milestone is done when its gate in §14 of
  the spec passes, not when the script exits 0.
- **Manifest or package change** → VM run plus `check-guide-drift.sh`.
- **Guide edit** → `check-guide-drift.sh`. Prose changes still need a read-through
  against the spec.
- **Refactor** → the VM run must produce an identical installed system.

**Status:** the commands above are the project's defined interface, specified in
the design. They are implemented milestone by milestone (spec §14) — check
whether a given script exists before assuming it can be run, and implement it as
part of the milestone that needs it rather than stubbing it.
<!-- END vdf-project-specifics -->

---

## Where the guide lives

The guide is **not in this repo**. It is a note in the author's Obsidian vault at
`Operating system/Custom OS Builder/`, following that vault's own conventions
(HQLS frontmatter, Title Case filenames, wiki-links). See D14 in
`docs/decisions.md`.

Practical consequence: `check-guide-drift.sh` needs a path to the guide file,
supplied by `ARCHWRIGHT_GUIDE_PATH` or `--guide <path>`. It skips with a clear
message rather than failing when the guide is not reachable, so the check is safe
to run in CI or on a fresh clone.
