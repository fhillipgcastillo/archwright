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

**Where things run.** The repo lives on a Windows drive; the VM oracle runs in
**WSL2 Ubuntu** (see D13). Unit tests and lint run fine on either. Anything
involving QEMU must be invoked inside WSL:

```
wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash test/vm-install.sh --phase all'
```

Large artifacts (ISO, extracted kernel, VM disks) live in `$ARCHWRIGHT_CACHE`
(default `~/.cache/archwright`) on the WSL native filesystem, **not** in the
repo — `/mnt` I/O is too slow for them.

| Job | Command | Notes |
|---|---|---|
| **Unit tests** | `bash test/run-unit.sh` | Fast, no VM. Covers `lib/common.sh`, `lib/manifest.sh`, `lib/answers.sh`, `lib/partition.sh` |
| **Lint** | `bash test/lint.sh` | The single source of truth for the shellcheck invocation — runs `shellcheck -x` over every tracked `*.sh`. Must be clean. No `# shellcheck disable` without an inline reason on the line above |
| **Test** (primary oracle) | `bash test/vm-install.sh --phase all` | Full end-to-end in QEMU: OVMF UEFI, blank qcow2, stock Arch ISO, unattended install from `test/vm/answers.example.conf`, reboot, then assert the milestone gate. Each run gets a throwaway disk and its own copy of the firmware vars |
| **Look at the VM from Windows** | `bash tools/boot-installed.sh --spice` | Boots the last passing image with a SPICE display instead of a WSLg window, and prints the URI to connect to with virt-viewer on Windows. The WSLg window cannot receive the Super key; a native client can. Console and LUKS prompt stay in the WSL terminal. No audio - the VM has no sound card (P3) |
| **Run a single phase** | `bash test/vm-install.sh --phase <name>` | `iso-smoke`, `preflight`, `disk`, `base`, `all`. Far faster than the full run while iterating |
| **Typecheck** | *n/a* | Shell project |
| **Build** | *n/a* | No build step |
| **Docs check** | `bash test/check-guide-drift.sh` | Verifies the guide's package and hotkey tables match `manifest/`. Not written until milestone 7 — there is no guide to check against before then |
| **One-time setup** | `tools/fetch-arch-iso.sh`, `tools/extract-iso-boot.sh` | Populate the cache. `test/vm-install.sh` calls them if the cache is empty |

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

### How to use the adversarial reviewer without it eating the milestone

Milestone 5 spent more wall-clock on review-and-fix than on building: three
serial rounds of ~13 minutes each, over a change of roughly 600 lines. The
rounds were worth running — two of them found permanent passwordless root — but
the way they were run was wasteful. Every blocker across all rounds lived in one
file. The rest of the diff was re-read from scratch each time, and a fresh
reviewer spends most of its runtime orienting.

**Route by blast radius, not by diff size.**

| Change touches | Oracle |
|---|---|
| `/etc/sudoers.d`, disk/partitioning, bootloader, LUKS, credentials, anything that runs as root on the installed system | Full adversarial review, every time, no exceptions |
| Generated shell, or any value interpolated into a command | Adversarial review, scoped to that function |
| Manifest parsing, config seeding, symlinks, docs, tests | Unit tests + lint. No reviewer |

**Review the dangerous file when it is written, not at the end of the
milestone.** The sudo window was reviewable the moment it existed. Reviewing it
then overlaps with building the rest; reviewing it at the end blocks everything.

**Scope the prompt to one artifact and a short list of attacks.** "Review this
diff" over seven categories produces a long run and a long report in which two
blockers hide among nine nits. Name the file, name the failure modes worth
hunting (what survives a reboot? a suspend? a signal? a second invocation?),
and say what is already covered by tests so it is not re-derived.

**Fan out rather than iterate.** Two or three narrow reviewers in parallel — one
on the privileged path, one asking "would this assertion fail if the feature
were deleted?", one on file-ownership — finish in the time of one broad
reviewer and do not serialise behind each other.

**A re-review is scoped to the fix commit**, never the whole branch again. It
still happens: a fix to a security bug is a new change (D-log L56), and two of
this feature's three defects were introduced while fixing the first.

**Spend a unit test before a gate run.** A VM gate is ~6 minutes; two of
milestone 5's five runs died on things a unit test now catches in a second
(`--phase ai` missing from the whitelist). Anything checkable statically gets a
unit test *before* the gate is started, not after it fails.
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
