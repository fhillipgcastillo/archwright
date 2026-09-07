# Decision Record

Every fork taken while designing Archwright, what was chosen, what was rejected,
and why. The spec records *what* the system is; this file records *why it isn't
something else* — which is the part that gets lost first.

Decided 2026-09-06 in a design session with the author. Facts referenced here are
in [`research-extract.md`](research-extract.md); the system itself is specified
in [`superpowers/specs/2026-09-06-archwright-design.md`](superpowers/specs/2026-09-06-archwright-design.md).

Format: **Chosen** · **Rejected** · **Why** · **Would change if**.

---

## D1 — Two deliverables, not one

**Chosen.** A hand-build guide *and* an automated installer, treated as equal
first-class outputs of one design.

**Rejected.** Installer only, with a README. A guide only.

**Why.** The two serve different people and different moments. Someone who wants
to *understand* an Arch + Hyprland system is badly served by `curl | bash`;
someone who wants a working machine this afternoon is badly served by forty
manual steps. Shipping only the installer also means the reasoning behind every
choice lives nowhere.

**Would change if.** The guide proves impossible to keep honest against the
installer — but D9 exists to prevent exactly that.

---

## D2 — Base layer: LUKS2 + btrfs + snapper + Limine

**Chosen.** The full storage stack: GPT/ESP, LUKS2 container, btrfs subvolumes
(`@ @home @snapshots @log @pkg`), Limine, snapper with snapshots on update.

**Amended 2026-09-06 during implementation: no Unified Kernel Image.** The
original entry specified a UKI, following the researched design. Building
milestone 1 showed why that does not work without a package repository:

- Snapshot boot entries are the entire reason Limine was chosen. Limine cannot
  read inside the LUKS container, so every boot artifact must sit on the
  unencrypted ESP, and booting a snapshot means a different
  `rootflags=subvol=` on the kernel command line.
- **A UKI bakes its command line into the binary**, so each snapshot would need
  its own UKI. Generating those is what `limine-entry-tool` exists to do.
- That tool, `limine-mkinitcpio-hook` and `limine-snapper-sync` are one Java
  project. All three declare `gradle` as a makedepend, none is in an official
  Arch repository, and none has a `-bin` variant. Building them at install time
  means a ~330MB GraalVM download plus a native-image compile inside a
  RAM-backed live filesystem — verified by attempting it, which failed on the
  missing `gradle`.

So Archwright installs a plain kernel and initramfs on the ESP. The command
line then becomes per-entry text in `limine.conf`, and
`bin/archwright-limine-update` generates the whole menu — default entry plus
one per snapper snapshot — in about 100 lines of shell with no build
dependencies.

**Known cost.** No UKI means no single signed blob, so Secure Boot support is
meaningfully harder if it is ever wanted. Accepted: milestone 1 does not do
Secure Boot, and the alternative was an unshippable install.

**Rejected alternatives at the time of the amendment:** keep the UKI and defer
snapshot entries entirely (drops the one feature Limine was chosen for); build
the Java tooling anyway (unshippable); reopen the bootloader choice (a larger
change than the problem warranted).

**Rejected.**
- *Simple*: GPT + ESP + ext4, systemd-boot, no encryption. Easiest to write and
  the most reliable script.
- *Middle*: btrfs + snapper but no LUKS.
- *Runtime choice*: ask the user, support all shapes.

**Why.** Snapshot-with-rollback is named in the source research as one of the top
transferable ideas, and it is the thing that makes a rolling-release base safe to
actually daily-drive. Encryption is a one-time cost at install for a permanent
property. Making it a runtime choice roughly doubles the testing surface for a
v1 that has no users yet.

**Consequence — Limine is non-negotiable.** Snapshot rollback is unavailable on
GRUB and systemd-boot. Keeping the boot menu in step with snapper is done by
`bin/archwright-limine-update` (see the amendment above), not by
`limine-snapper-sync` as originally planned. This one requirement rules out the
`archinstall` JSON path in D4.

**Would change if.** A target machine's firmware turns out to be hostile to
Limine. The fallback is the *Middle* option plus a documented manual rollback,
not GRUB.

---

## D3 — Desktop shell: assemble, behind a swap boundary

**Chosen.** waybar, mako, walker, hyprlock, hypridle and swaybg as separate
mature packages — but isolated behind one systemd user target
(`archwright-shell.target`) so the whole furniture layer can be replaced as a
unit. No other layer names any of those packages.

**Rejected.**
- *Write a Quickshell shell.* One process, everything themes together, panels
  open instantly. The source research puts this at weeks-to-months of QML, and
  nothing exists until it is written — the 23 first-party plugins in the system
  studied are 23 things a team wrote and maintains.
- *Assemble with no boundary*, wired directly the way most dotfiles repos do.
- *Sway instead of Hyprland.* Simpler config, far less GPU-dependent, friendlier
  in VMs — but it discards most of the researched Hyprland knowledge.

**Why.** Assembling gets a working desktop in days using packages other people
maintain. The boundary costs a small amount of structure now and keeps the
Quickshell door open once there is real experience of living with the assembled
version. Retrofitting the boundary later means auditing the whole install.

**Known cost.** Each component themes separately, in its own config format
(waybar is JSON + CSS, mako is INI, hyprlock is Hyprland syntax). This is exactly
why the theming fan-out in D10 exists. Panels also spawn a process on open, so
the launcher has a visible cold-start hitch that a single-process shell would not.

**Would change if.** The per-component theming fan-out becomes the dominant
maintenance burden, which is the signal that a single-process shell has started
paying for itself.

---

## D4 — Delivery: a script run from the stock Arch ISO

**Chosen.** The user boots the official, unmodified Arch install medium and runs
one command. The script does partitioning, LUKS, btrfs, `pacstrap`, Limine,
snapper, then desktop, apps and AI layer.

**Rejected.**
- *Custom `archiso` ISO with a bundled offline mirror.* The most polished
  handoff — the researched system installs in under five minutes precisely
  because nothing downloads. But it means building and hosting a multi-gigabyte
  image and rebuilding it as packages go stale: a second project alongside the
  first.
- *Declarative `archinstall` JSON plus a post-install script.* Least code. Ruled
  out by D2 — `archinstall` has no Limine support, and the JSON path gives up the
  phase-ordering control that §7 of the research extract shows is load-bearing.
- *Post-install script only*, run on an already-installed Arch system. Cannot
  deliver D2 at all: LUKS, subvolume layout and bootloader are install-time
  decisions.

**Why.** It is the only option that delivers the chosen base layer with no
hosting infrastructure. It is also a plain shell script a stranger can read
before running it, which matters more than polish for something meant to be
shared. And it is the natural precursor to an ISO — an `archiso` profile later
just wraps the same script and the same manifests.

**Known cost.** Needs a network connection throughout, and the install takes as
long as the downloads take (20–40 minutes rather than five).

**Would change if.** Installs become frequent enough that the download time
matters, or the project starts being handed to non-technical people.

---

## D5 — AI layer: four pieces in, two out

**Chosen.** Lazy agent CLI stubs with a default-agent convention and hotkey; a
shared agent skill directory symlinked across agents; time-boxed passwordless
sudo; a local model runtime in the extras tier.

**Rejected.**
- *Crash diagnosis* — watch `systemd-coredump`, hand a segfault's core dump to
  the default agent. Genuinely clever, but meaningfully more code and it needs a
  working notification click-handler.
- *Agent usage / quota tracking panel* — per-subscription plan and quota display
  in the bar. Per-vendor API scraping on a refresh timer; it breaks whenever any
  vendor changes an endpoint. The highest-maintenance item in the entire
  researched system relative to its value here.

**Why.** The four chosen pieces are all cheap and all durable. Lazy stubs cost
nothing until first run, so shipping a dozen is free. The skill directory is a
handful of symlinks. The sudo window is a small script and a transient timer. The
two rejected pieces are the only ones with ongoing external dependencies.

**Would change if.** Someone else wants to own the usage panel as a separate
plugin — it is a reasonable standalone project, just not part of a base system.

---

## D6 — Auto-approve agent flags ship commented out

**Chosen.** The shipped aliases include the unattended, don't-stop-to-ask flags
(`--permission-mode auto` and equivalents) **present but commented**, with the
warning attached. The `~/Work` redirect for launches from `$HOME` is kept.

**Rejected.** Shipping them active, as the researched system does.

**Why.** This is a deliberate divergence, not an oversight. Combined with the
time-boxed sudo window in D5, an active auto-approve alias means an unattended
agent with root-adjacent access to a freshly installed machine. That should be a
choice someone makes on purpose, not a default they inherit from an installer.
Leaving the flags visible but inert means the capability is discoverable and one
edit away.

**Would change if.** Nothing foreseeable. The cost of the safe default is one
uncommented line.

---

## D7 — Applications: two tiers

**Chosen.** A small fixed core (one tool per job) plus an opt-in extras list the
installer offers and the guide presents as add-on sections.

**Rejected.**
- *Core only* (~20 packages). Smallest guide, fastest install.
- *Core plus a fixed productivity layer* (~35 packages).
- *Match the researched base manifest closely*, including office suite, OBS and
  a video editor. At that point it stops being a base install and the guide gets
  long.

**Why.** The core stays honest and quick to verify; the extras make the
deliverable useful to more than one person without inflating what everybody gets.
The source system's own "zero bloat" claim is undermined by shipping an office
suite by default — the two-tier split avoids inheriting that contradiction.

**Known cost.** More combinations to test. Mitigated by the VM oracle driving a
fixed extras selection from the answer file.

---

## D8 — Firefox as the default browser

**Chosen.** Firefox default, with a `policies.json` for sane defaults and native
Wayland. Chromium available in `extras`.

**Rejected.** Chromium as default, as the researched system does.

**Why.** Author preference, and nothing in the design depends on Chromium. The
two custom browser extensions in the researched system (a URL copier and a video
downloader, both riding a native messaging host) were never in scope to clone, so
choosing Chromium would have bought nothing.

**Known cost.** Firefox's chrome does not recolour from `colors.toml` as cleanly
as Chromium's would. Browser theming is therefore **best-effort** — documented as
a limitation rather than papered over. `MOZ_ENABLE_WAYLAND=1` becomes
load-bearing rather than incidental.

**Would change if.** Nothing. The limitation is cosmetic and stated.

---

## D9 — Sync model: shared manifests plus a drift check

**Chosen.** Package lists, subvolume layout and hotkeys live as plain data files
in `manifest/`. The installer reads them at runtime; no package list is hardcoded
in `lib/`. A script verifies the guide's tables match them and exits non-zero on
mismatch.

**Rejected.**
- *Independent artifacts kept aligned by hand.* What almost every dotfiles
  project does, and why almost every dotfiles project's README is wrong.
- *Literate source* — the script tangled out of the guide's fenced code blocks.
  Cannot drift, but means maintaining a tangler, and the script becomes a
  generated artifact that is awkward to edit or debug.

**Why.** It gives the documentation a real oracle — a check that passes or fails
rather than a promise — without inventing a build system. Prose stays
hand-written and human; only the facts are pinned. The same manifest files are
what an `archiso` profile would consume if D4 is ever revisited.

**Follow-on decision.** Hyprland's keybind block is **generated** from
`manifest/hotkeys.tsv` at install time rather than hand-written, with a "do not
edit" header and user overrides in a separate sourced file. Otherwise the
manifest is a third copy that can disagree with both the config and the guide,
and the drift check would be validating docs against docs.

---

## D10 — Theming: install-time only

**Chosen.** One `colors.toml` fanned out at install time to foot, Hyprland,
waybar CSS, mako, walker, btop and Neovim. No runtime theme-switching engine.

**Kept from the research anyway**, because both cost almost nothing:
- the `themed/*.tpl` escape hatch, where **user templates outrank shipped ones**
- **install-time sanitization** of imported themes — colours in, executables out

**Rejected.** A full theme-switching engine with a picker, live regeneration and
a theme catalogue. The researched system drives 20+ applications from one palette
file; the fan-out *is* the work, and it is a project in its own right.

**Why.** "Bare basics with the UI" does not include a theming engine. The
escape hatch and the sanitization rule are kept because they are each a few lines
and they remove whole categories of future problem — respectively "please theme
app X" requests, and executing a stranger's code because they called it a theme.

**Would change if.** The project grows a theme catalogue, at which point the
runtime engine is the obvious next feature and the template system is already in
place to receive it.

---

## D11 — Hardware: generic, with a self-detecting script directory

**Chosen.** Target generic x86_64 UEFI. Ship `hardware/*.sh` where each script
probes for its hardware and no-ops when absent, with GPU driver selection
(Intel/AMD/NVIDIA) plus placeholders for suspend and audio. Re-runnable after
install.

**Rejected.**
- *Optimize for one specific machine first.* Fastest to a daily driver, least
  useful to anyone else.
- *VM-only, bare metal deferred.* Removes all firmware variability but means the
  result cannot actually be daily-driven, and the encryption and snapshot layers
  go under-tested.

**Note on scope.** The option selected in the design session was plain "generic,
verified in a VM." The `hardware/` directory is a small expansion on that: GPU
driver selection has to live *somewhere*, and the alternative is hardcoding it
inline in `lib/40-desktop.sh`, which is worse and harder to extend. The directory
is the structural pattern from the research (§20) applied at minimum size — three
scripts, not forty-five.

**Why.** The source research is emphatic that the hardware matrix is "the
accumulated residue of a user base, not a design," and that a rebuild should
scope it to one machine and grow it only on report. A directory of self-detecting
no-ops is the cheapest structure that allows that growth without a refactor.

---

## D12 — Verification: a QEMU VM boot is the oracle

**Chosen.** `test/vm-install.sh` (Linux host) as the primary oracle: QEMU with
OVMF UEFI firmware, blank qcow2, stock Arch ISO, unattended install from an
answer file, reboot, then assert LUKS prompt, boot, Hyprland session, a snapper
snapshot, and a snapshot entry in the Limine menu. Every milestone is gated on
it. Supporting checks: the drift check, `shellcheck`, and an idempotency run.

**Rejected.** Inspection, "it looks right," and testing only on real hardware.

**Why.** The author's standing working rule is that no change is done until an
independent check has been run and seen to pass. For an OS installer the only
honest check is a real boot. Real hardware alone is too slow to iterate on and
destroys the machine under test.

**Borrowed from the research (§21):** each run gets a **throwaway overlay with
its own firmware variables**, so no disk or NVRAM state leaks between runs. This
is easy to omit and produces confusing false passes when omitted.

---

## D13 — WSL2 runs the oracle

**Superseded an earlier draft.** The first version of this entry committed to a
portable QEMU-for-Windows build unpacked into `.tools/`. That was written up as a
decision when it had only been raised as an idea to explore, and exploring it
showed two things: the common Windows QEMU distribution is an NSIS installer
rather than a portable archive, so "unzip it" needed an extra extraction step;
and the machine already had a better option.

**Chosen.** QEMU runs inside **WSL2 Ubuntu** (`qemu-system-x86`, `qemu-utils`,
`ovmf`, `libarchive-tools`), driven by `test/vm-install.sh`. Verified on this
machine: `/dev/kvm` is present and read/write, the CPU exposes `vmx`, and QEMU
8.2.2 initialises with `accel=kvm`.

**Rejected.**
- *Portable QEMU in `.tools/`* — see above.
- *`winget install QEMU` on Windows* — works, and Hyper-V is already enabled so
  WHPX acceleration would be available, but WHPX is slower than KVM and it
  installs software system-wide for no gain here.

**Why.** It is the fastest option available on this machine, it changes nothing
in the Windows install, and it exercises `test/vm-install.sh` — the Linux path
that anyone cloning the repo will actually use. Testing the path most users take
is worth more than testing the author's host OS.

**Consequences.**

- **Large artifacts live outside the repo.** The repo sits on a Windows drive at
  `/mnt/e/...`, where I/O crosses the WSL filesystem boundary. A 1.3GB ISO and a
  qcow2 disk image are slow there, so the ISO, extracted boot files and
  throwaway VM disks live in `$ARCHWRIGHT_CACHE` (default `~/.cache/archwright`)
  on the native filesystem. Only the repo itself is read across the boundary.
- **OVMF filenames are probed, not assumed.** Ubuntu 24.04 ships
  `OVMF_CODE_4M.fd`; Arch and older Debian ship `OVMF_CODE.fd`. `tools/env.sh`
  searches a list and deliberately skips the `secboot` and `ms` variants, which
  refuse to boot an unsigned kernel and fail as a blank screen rather than an
  error.
- **`.gitattributes` pins LF** on shell, Python and data files. They are authored
  on Windows and executed in Linux; CRLF fails in ways that do not name the
  cause.
- **`test/vm-install.ps1` is out of scope for milestone 1.** The Windows host
  path is not being maintained or verified for now. Reinstating it is a small
  piece of work — `tools/env.sh` is the only place that resolves host paths.

**Guide consequence.** The guide's main body assumes bare metal on any UEFI
machine and makes no host-OS assumptions. Host-specific material lives in a
"try it in a VM first" appendix with a Linux track and a Windows track.

---

## D14 — Locations: guide in the vault, installer standalone

**Chosen.** The guide is a vault note in `Operating system/Custom OS Builder/`,
linked into the existing MOCs. The installer is this repo at
`E:\data\dev\archwright`.

**Rejected.**
- *Both in the vault*, following the existing guide-plus-script pattern.
- *Vault as source of truth with the repo generated from it.* Single source, but
  an export step to maintain.

**Why.** A `curl`-able installer has to be a real repo with its own history and
README. The vault stays the research and writing surface. The cost is two places
to keep in sync, which is what D9 addresses.

**Follow-on.** Because the repo must stand alone for anyone who clones it, the
vault research it depends on is reproduced in
[`research-extract.md`](research-extract.md) rather than referenced by path.

---

## D15 — Name: Archwright

**Chosen.** `archwright` — project, repo, CLI command and `/usr/share` path.
Short aliases (`awu`, `aws`, `awa`, `a`) for frequent verbs.

**Rejected**, from a long list: *Archway* (elegant, and *arch* + *way*land, but
says nothing about building it yourself), *Archland* / *Arcland* (most
informative, least elegant), *Minarchy* (frames the project as derivative),
*Cairn*, *Lintel*, *Axiom*, *Chassis*, *Bastion*, *Archetype* (crowded search
results), and others.

**Why.** A *wright* is a maker — shipwright, wheelwright, playwright — so an
archwright builds arches. It puts "you build this yourself" in the name, which is
the actual character of both deliverables. Reads as Arch on sight. Effectively
uncontested: a GitHub search found five repositories, none above one star and
none in this space.

**Known cost.** Ten letters, so the CLI needs aliases. People will type
*Archwrite*.

---

## D16 — Explicitly not a distribution

**Chosen.** No package repository, no Arch mirror, no signing key, no release
channels, no migration system, no custom ISO.

**Why.** The central finding of the source research is that "the hard part is not
the desktop, it's the delivery system" — roughly 80% of the engineering in the
system studied sits in the repo, mirror, ISO, migrations, snapshot wiring and
hardware scripts, and none of it is visible in a screenshot. That research also
warns that the characteristic failure is starting at distribution scope and
discovering dotfiles-scope problems.

Archwright is deliberately **scope A** — a configuration set plus an install
script — with two borrowings from scope B: snapshots, and an unattended answer
file. Both are cheap and both pay for themselves immediately.

**Would change if.** Never, without a deliberate re-scoping conversation. Adding
a package repo means signing keys, key rotation, a mirror, and writing migrations
forever.

---

# Implementation log

The numbered decisions above are design-level and were made before building.
This section is the running chain of everything decided **during**
implementation — whether chosen deliberately, forced by a review finding, or
forced by something failing in the VM.

The point is that a later reader can tell the difference between "this is
load-bearing, leave it alone" and "this was arbitrary, change it freely".
Anything removed without reading this risks re-introducing a bug that was
already paid for once.

Format: **what changed** · *why* · **trigger**.

## 2026-09-06 — milestone 1

### L1 — Work on a `milestone-1` branch, not `main`
`main` was already pushed to GitHub. Nine commits of unverified installer work
had no business landing there directly. **Trigger:** on the fly.

### L2 — `tools/fetch-shellcheck.ps1` and `test/lint.sh` added
shellcheck was not installed and the repo's own rules require clean output.
Fetching a portable copy into `.tools/` matches how the project treats every
other tool: nothing system-wide, delete the folder to undo. `test/lint.sh`
exists so the invocation cannot drift between `CLAUDE.md`, the plan and CI.
Neither was in the plan; both are scope, and both were judged worth it.
**Trigger:** missing dependency.

### L3 — Lint covers untracked files
`git ls-files` alone made the lint gate blind during the write-lint-commit
loop — a syntactically broken new file passed. Now `git ls-files -co
--exclude-standard`. It immediately caught CRLF that a patch script of mine
had introduced. **Trigger:** adversarial review.

### L4 — `assert_fails` requires the command to exist
It treated any non-zero status as success, including 127. Deleting `aw_die`
outright left the whole suite green. Now 126/127 are failures and the command
must exist. **Trigger:** adversarial review (mutation testing).

### L5 — Test failures recorded in a file, not a variable
A `TESTS_FAILED` increment inside a pipeline or subshell is lost when it
exits, so a failing assertion could report as a pass. **Trigger:** adversarial
review.

### L6 — Manifest tests assert structure, not row counts
`assert_eq "$n" "5"` broke when a subvolume was legitimately added and stayed
green when the file was corrupted — tabs replaced by spaces, every package
renamed to junk. Now: field counts, required packages by name, the root
subvolume is `@`, mountpoints absolute and unique. **Trigger:** adversarial
review.

### L7 — `aw_answers_load` resets before parsing
Loading a second answer file inherited values from the first, so validation
passed on a field the new file never set. **Trigger:** own test caught it.

### L8 — Answer values: CR stripped, trimmed, quoted values verbatim
A clone with Git-for-Windows' default `core.autocrlf=true` failed four tests
and produced `AW_DISK=/dev/vda\r` that still validated. Quoted values are kept
byte-for-byte because passwords contain `#` and may end in a space — eating
either would lock a user out of the machine they just installed.
**Trigger:** adversarial review.

### L9 — Answer values are validated, and the "cannot execute" claim was corrected
The header claimed values could not execute because the file is never sourced.
That was false end to end: values are interpolated into `aw_run_in_chroot`.
Non-secret fields are now pattern-validated; secrets stay unconstrained
because they only ever travel on stdin. **Trigger:** adversarial review.

### L10 — `.gitattributes` pins LF
Scripts are authored on Windows and executed in Linux. CRLF fails in ways that
never name the cause. **Trigger:** adversarial review.

### L11 — Cross-phase state in `/run/archwright/state`
Each `install.sh --phase X` is a separate process, so `AW_ESP_DEV` and
`AW_ROOT_DEV` from the disk phase were simply gone by the boot phase. `/run`
is tmpfs, which is the right lifetime. Derivation from the running system is
kept as a fallback so a phase can still be run standalone.
**Trigger:** VM failure.

### L12 — `install.sh` pins `LC_ALL=C`
`parted`, `sort` and `comm` are all locale-sensitive and `lib/partition.sh`
depends on their output being stable. **Trigger:** adversarial review
(collation bug).

### L13 — `curl` and `libnotify` added to `manifest/core.packages`
`curl` was arriving only transitively via `git`; the installed system needs it
explicitly. `libnotify` was a dependency of `limine-snapper-sync`, which has
since been dropped — **`libnotify` is now unused and can go** unless something
else claims it. **Trigger:** on the fly.

### L14 — All AUR build machinery removed
Superseded by the D2 amendment. Along with it went a throwaway `aurbuild`
user, a sudoers drop-in, and `manifest/aur.packages`. Two findings from that
work are worth keeping even though the code is gone: **the Arch live ISO does
not ship git**, and **its `sudo` has no usable `secure_path`**, so
`sudo -u someuser somecmd` fails with "command not found" even when the
command is installed. Use `runuser` with an explicit PATH if this is ever
needed again. **Trigger:** VM failure.

### L15 — The `bin/` directory must be in the served tree
`serve_repo()` packed only `install.sh`, `lib`, `manifest` and `test`, so
`archwright-limine-update` silently never reached the guest. Any new top-level
directory the installer reads has to be added there too.
**Trigger:** VM failure.

### L16 — Tag is `m1-verified`, not `milestone-1`
A tag sharing a name with a branch makes every ref ambiguous and git warns on
each use. **Trigger:** on the fly.

---

## Known gaps carried out of milestone 1

Recorded so they are not mistaken for decisions.

| Gap | Detail |
|---|---|
| **Super key unusable when viewing the VM from Windows** | Windows and WSLg both claim Super, so no `Super + …` binding reaches the guest. The binding is correct (`hyprctl binds` reports `modmask: 64`) and works on real hardware. Ctrl+Alt+G grab, `GDK_BACKEND=x11`, SDL with `grab-mod`, and VNC were all tried and none helped. Workaround: `hyprctl dispatch` over the serial console. Viewer limitation, not a product defect |
| **Windows host path unmaintained** | `test/vm-install.ps1` and `tools/fetch-qemu-windows.ps1` are not written or verified. See D13 |

### L17 — `README.md` written: the real-hardware bootstrap
Milestone 1 was verified end to end in QEMU while the route a real person takes
was never written down or tested. The harness supplies for free everything that
is hard on a laptop: networking, the repo arriving on the machine, well-behaved
firmware, a predictable disk name. The README now covers writing the USB,
booting UEFI, connecting Wi-Fi with `iwctl`, installing git (the ISO has none),
finding the disk, writing an answer file, and what "done" looks like — plus an
explicit "Honest limitations" section listing what QEMU does *not* prove.
**Trigger:** the user pointing out that the project had started assuming QEMU is
the environment rather than the proxy.

### L18 — Preflight refuses to install when Secure Boot is on
Archwright's bootloader is unsigned, so with Secure Boot enabled the install
succeeds and the machine then refuses to boot. It is the most likely
real-hardware blocker and is **invisible in the harness**, because OVMF ships
with Secure Boot off — in QEMU the EFI variable does not exist at all, which is
reported as "unknown" and warns rather than blocking. `aw_secureboot_state`
takes the efivars path as a parameter so it is unit-tested against fixtures.
**Trigger:** writing the README exposed a promise the code did not keep.

### L19 — Stop generating shell code through Python heredocs
Patching files with `python3 - <<'PY' ... p.write_text(...)` silently no-op'd or
corrupted content five times: a function defined but its call site never wired,
two literal `\n` sequences, a cp1252 decode error on a UTF-8 file, and finally
`test_common.sh` rewritten with **real control bytes** where escape text was
intended, turning a shell script into a binary file. Use the editor tools for
anything containing escapes or non-ASCII, and assert on every replacement so a
non-match fails loudly. **Trigger:** repeated self-inflicted corruption.

## Real-hardware gaps carried out of milestone 1

Distinct from the table above: these are things the QEMU harness cannot tell us
about, listed so they are not mistaken for verified behaviour. Also summarised
for users in `README.md` under "Honest limitations".

| Gap | Detail |
|---|---|
| **No interactive mode** | `--answers <file>` is mandatory. A real person must hand-write an answer file at a TTY before anything runs. A prompt-driven mode, or generating a template with `--init-answers`, is the obvious fix |
| **Only `/dev/vda` exercised** | The `nvme0n1p1` / `mmcblk0p1` naming logic is unit-tested but has never touched real hardware — and nearly every modern machine is NVMe |
| **Firmware quirks untested** | OVMF is clean reference firmware. Real firmware may refuse the `efibootmgr` NVRAM entry. The installer warns and relies on the removable-media path, which is right, but unproven against anything odd |
| **Wi-Fi firmware** | Some chipsets need firmware the ISO does not carry. Preflight reports "no network" without saying why |
| **Tested cmdline differs from the shipped one** | The harness sets `SERIAL_CONSOLE=1`, adding `console=ttyS0`. A real install leaves it `0`, so the exact command line a user gets has never been booted |

### L20 — Firewall on by default; `sshd` installed but not enabled
`ufw` is now in the manifest, configured deny-inbound / allow-outbound, and
enabled. **No port is opened at all** — not even SSH.

Two details worth keeping:

- The config files (`/etc/default/ufw`, `/etc/ufw/ufw.conf`) are edited
  directly rather than by running `ufw` in the chroot. The chroot shares the
  **live installer's** running kernel, so `ufw` commands there would mutate the
  installer's own netfilter tables and would not persist to the target anyway.
- `sshd` was previously *enabled*, which combined with the absent firewall meant
  a fresh install listened on port 22 unprotected. It is now installed and
  disabled. A base system that anyone can install has no business listening on
  the network unasked; the README documents turning it on deliberately.

**Trigger:** gap review — the spec required a firewall (§3) and nothing
implemented it.

### L21 — `libnotify` removed from the manifest
It was only ever a dependency of `limine-snapper-sync`, which L14/D2 removed.
Found by writing the implementation log, which is the point of writing it.
**Trigger:** the decision log itself.

## 2026-09-06 — milestone 2

### L22 — The test VM gets one virtio GPU with a render node
Milestone 2 gates on a real Hyprland session, and Hyprland needs DRM with EGL.
Probing before planning found QEMU's default bochs display provides a card and
a connected connector but **no render node**, so Hyprland would have silently
fallen back to software rendering and the harness would have been testing a
path no real machine takes. `-vga none -device virtio-gpu-pci` gives exactly
one card, one connector and `renderD128` — the shape of a real single-GPU
machine. Milestone 1 was re-run green afterwards to confirm changing the
emulated graphics did not disturb the base install.
**Trigger:** deliberate probe before planning, after the UKI lesson.

> **Superseded by L28.** `-vga none` removed the only framebuffer firmware
> and the bootloader can draw on, making the machine impossible to watch
> boot. `virtio-vga` gives the render node *and* visible boot output.

### L23 — `AUTOLOGIN` is a real option, not a test hack
greetd's tuigreet runs on VT1 and the harness only has a serial console, so the
automated gate cannot type a password. Rather than a test-only branch,
autologin is a supported answer-file option — reasonable on a single-user
laptop — which the test enables. The gate also asserts the interactive tuigreet
path is configured, so the shipped default is not left verified by inspection
alone. **Trigger:** the harness could not exercise the shipped login path.

### L24 — The served tree is an exclude list, not an allowlist
`serve_repo()` packed a hardcoded list of directories. It silently omitted
`bin/` in milestone 1 (L15) and `config/` in milestone 2, each producing a
failure several layers from the cause. It now packs everything in the repo root
outside `SERVE_EXCLUDE`, so adding a directory the installer reads does not
require remembering that this function exists.
**Trigger:** the same bug twice.

### L25 — Assertions that need shell state must be functions, not `sh -c` strings
Four session assertions used `sh -c '...'`, which spawns a child shell that sees
neither `AW_XDG` (never exported) nor `hyprctl_user` (a shell function). All
four would have failed for entirely the wrong reason, sending the next person
hunting in the compositor. `check` runs its arguments in the current shell, so
helper functions work correctly. Caught by shellcheck as SC2016, which is
usually a nit and here was a real bug.
**Trigger:** lint.

### L26 — `hyprctl` needs `HYPRLAND_INSTANCE_SIGNATURE`
Without it, hyprctl has no idea which compositor socket to talk to and fails
in a way indistinguishable from "the session never started" — the dangerous
kind of failure, because it points at the wrong subsystem. The assertion helper
now derives the signature from the newest directory under
`$XDG_RUNTIME_DIR/hypr` and, when there is none, prints the directory contents
instead of failing mutely. **Trigger:** first gate run.

### L27 — Do not assert that a D-Bus-activated service is running
`xdg-desktop-portal-hyprland` starts when an application asks for a file picker
or a screencast. With nothing running that wants one, it is correctly not
running, so `pgrep` for it asserted nothing. The gate now checks what the
installer is actually responsible for: the binary, both `.portal` registration
files, and the D-Bus activation file — all four paths verified against the Arch
package file lists rather than guessed. **Trigger:** first gate run.

## Real-hardware gaps added by milestone 2

| Gap | Detail |
|---|---|
| **No keybinding has ever been pressed** | The gate drives Hyprland through `hyprctl`, not keystrokes, and the Super key cannot reach the guest when the VM is viewed from Windows. So every binding is verified as *configured*, never as *working*. First real-hardware boot closes this |
| **Graphics drivers** | The VM uses virtio-gpu. `mesa` covers Intel and AMD; **NVIDIA machines will not reach a session** until the hardware milestone adds driver selection. The base system will still boot |
| **Only one monitor, one mode** | `monitor = , preferred, auto, 1` is untested against multiple outputs, mixed DPI or fractional scaling |

### L28 — `virtio-vga` instead of `-vga none -device virtio-gpu-pci`
**Supersedes the device choice in L22.** L22 removed the VGA device to get down
to a single card. That worked for the automated gate but removed the only
framebuffer firmware and the bootloader know how to draw on: booting the
installed image by hand showed the Limine menu only on the serial console, and
the QEMU window opened with zero dimensions because no display surface exists
until Linux loads `virtio_gpu`.

`virtio-vga` is one device that is both VGA-compatible and virtio-gpu. Probed:
one display controller, `renderD128` present, one connected connector — so
Hyprland keeps its render node and firmware output is visible. It is also
closer to real hardware, which does show boot output on screen, so the previous
config was the less faithful one.

Incidental: the card enumerates as `card1`, not `card0`, because simpledrm
holds `card0` briefly during EFI handover. Nothing depends on the number; the
GPU probe was generalised to stop implying it does.
**Trigger:** the author tried to look at the built system and could not see it.

### L29 — A persistent pacman cache, shared into the guest over 9p
A full gate run was dominated by `pacstrap` downloading ~500MB. The host now
keeps a cache at `$ARCHWRIGHT_CACHE/pkgcache`, shared into the guest as a 9p
mount over `/var/cache/pacman/pkg`, and the installer is told to use it with
`--host-pkg-cache`.

Measured: **6m06s cold, 3m12s warm** for the full gate.

The hazard, documented at both the flag and the call site: `pacstrap -c` uses
the *live environment's* cache, which on a stock Arch ISO is **a tmpfs in RAM**.
Several hundred megabytes of packages would exhaust it. It is only safe because
the harness mounts real host storage there first, which is why this is an
opt-in flag a real install never passes rather than the default.

The mount is non-fatal: if 9p fails the run warns and proceeds slowly. Losing
an optimisation must not turn into a failed test.
**Trigger:** the author asked for faster iteration.

---

# Planned work

Things decided to be worth doing, not yet scheduled into a milestone. Distinct
from "known gaps", which are things currently missing or wrong.

## P1 — Resume an interrupted install (real hardware) — **DONE, see L34**

**Why it matters.** A real install is 20–40 minutes, mostly downloads. If it
fails at minute 35 — flaky wifi, a mirror timing out, a laptop lid closing —
the only option today is to start over, re-downloading everything. The disk
phase deliberately wipes and re-partitions on every run, which is correct for a
first attempt and punishing for a retry.

**Why it cannot resume today.**

- Cross-phase state lives in `/run/archwright`, which is tmpfs: it does not
  survive a reboot.
- Nothing reopens the LUKS container or remounts the subvolume tree, so
  `--phase base` only works if the live environment is still up from the failed
  attempt.
- `pacstrap` caches into the target, which the next run then wipes, so the
  downloads are lost with it.
- `aw_track` records every partition, container and subvolume a run creates,
  but **nothing consumes that record** — the scaffolding for "undo exactly what
  this run made" exists, the undo does not.

**Shape of a fix.** Persist phase state somewhere durable — the ESP is the
obvious candidate, since it is FAT, small, and mounted before anything else.
Teach the disk phase to recognise Archwright's own layout and offer `--resume`
rather than wiping. Keep the package cache out of the wiped area, or accept
re-downloading and fix only the phase skipping.

**Flagged by the author as important**, and it is: it is the difference between
a bad network costing five minutes and costing the whole install.

## 2026-09-07 — milestone 3

### L30 — `fuzzel` as the launcher, not `walker`
D3 named "walker/wofi". **`walker` is not in Arch's official repositories** —
it is AUR-only, and building AUR packages at install time is exactly what D2
removed. Between the official alternatives `fuzzel` is Wayland-native, actively
maintained, and by the same author as `foot`, which Archwright already ships.
A unit test asserts `walker` never reappears in the manifest.
**Trigger:** package availability checked before planning.

### L31 — Upstream units get a drop-in, not an edit — and `.wants` is not enough
waybar, mako, hypridle and hyprpolkitagent ship their own systemd user units.
Those are package-owned and must never be edited, so they are symlinked into
`archwright-shell.target.wants/`.

**That alone made the boundary half-real, and the gate caught it.** A `.wants`
symlink is a **start** dependency only: stopping the target did not stop
waybar, mako or hypridle — only `archwright-swaybg.service` stopped, because it
declares `PartOf=`. So D3's claim that the furniture layer can be replaced as a
unit was true for starting and false for stopping.

`PartOf=` has to be declared *by* the unit, so it goes in a drop-in under
`/etc/systemd/user/<unit>.d/` — administrator territory, survives package
updates, upstream untouched.

This is precisely why the gate tests stop *and* start rather than asserting the
claim in prose: checking only "the target is active and the components are
running" would have passed and shipped a broken boundary. It also unmasked the
restore assertion, which had been passing only because nothing ever stopped.
**Trigger:** first milestone 3 gate run.

### L32 — Shell keybinds live in their own sourced file
If `hyprland.conf` named `fuzzel` and `hyprlock` directly, the compositor config
would be coupled to the shell and D3's boundary would be a fiction. It now
carries a single `source = ~/.config/hypr/shell.conf`, and that file holds every
shell-layer binding plus the target autostart. Replacing the furniture layer
means replacing one config file and one target.
**Trigger:** on the fly, while writing the plan.

### L33 — A passing gate archives a known-good disk image
`VMRUN` is wiped at the start of every run, and `tools/boot-installed.sh`
pointed straight at it — so starting a test destroyed the very image you wanted
to boot. That happened once and cost a confusing debugging session in which the
symptom (a half-installed disk) looked nothing like the cause.

A passing gate now copies the disk and firmware vars to
`$ARCHWRIGHT_CACHE/last-good/`, and the viewer boots that by default. It also
refuses with a clear message when a QEMU process is holding the image, rather
than surfacing QEMU's lock error several lines deep.
**Trigger:** the author's `boot-installed.sh` run failed for reasons entirely of
my own making.

### L34 — P1 implemented: `--resume` (planned work now done)
Phase completion is recorded on the **ESP** rather than `/run`, because `/run`
is tmpfs and dies at exactly the moment the state matters — a reboot.

`--resume` finds the ESP and the LUKS container **by label and filesystem type,
never by partition number** (the same rule as `lib/partition.sh`), then refuses
unless it finds Archwright's own state file on the ESP. It mounts the ESP
read-only to check, so a disk that turns out to belong to somebody else is left
completely untouched.

Preflight had to become resume-aware in two places: it no longer rejects the
mounted partitions that resume itself just mounted, and it does not demand the
word `ERASE` for an operation that erases nothing — training people to type
ERASE without reading is its own hazard.

Verified by `test/vm-install.sh --phase resume`, which installs through `base`,
tears the mounts down and discards `/run` to simulate a reboot, resumes, and
asserts both that the finished phases were skipped and that a disk with no
Archwright state is refused.
**Trigger:** flagged by the author as important; recorded as P1, now closed.

### L35 — `fetch-shellcheck.ps1` verifies a checksum
`tools/fetch-arch-iso.sh` verified the ISO it downloaded; the linter binary that
gates every commit did not. Now pinned by version *and* sha256, with no way to
skip the check: overriding the version without also supplying a hash is an
error rather than a silent downgrade in safety.
**Trigger:** gap review.

### L36 — `plymouth` removed from the manifest
It was installed for three milestones and nothing ever configured it — no
`plymouth` hook in mkinitcpio, no `splash` on the kernel command line. Shipping
a package nothing uses is the kind of thing that survives forever because
removing it looks risky.

Configuring it now was the tempting alternative and was rejected: Plymouth takes
over the console, and the test harness types the LUKS passphrase over the serial
port. Enabling it without care would break the gate in a way that looks like an
encryption failure. The branded boot splash belongs to the theming milestone,
where it can be done properly and tested. A unit test keeps it out until then.
**Trigger:** gap review.

### L37 — Both microcode packages, deliberately
Previously an accident, now a decision: `amd-ucode` and `intel-ucode` are both
installed and both emitted as boot modules. The kernel ignores the image that
does not match the CPU, and having both means the same disk still boots if it
moves between an Intel and an AMD machine — which matters for a system whose
point is that you can image it and hand it to someone.
**Trigger:** gap review turned an unexamined default into a stated choice.

## 2026-09-07 — milestone 4

### L38 — Repository requirements are manifest data, not code
`gaming` needs the `multilib` repository because Steam is the only package here
outside `extra`. That requirement is declared in `manifest/extras.packages` as a
`## Requires: multilib` line the parser reads, rather than hardcoded in `lib/`.
Package facts stay with the package data — the same rule that keeps package
names out of the installer. The repository is enabled only when a selected group
asks for it, and the gate asserts it stays off otherwise, so nobody receives a
32-bit package set they never requested.
**Trigger:** package availability checked before planning.

### L39 — `vim` dropped in favour of `neovim`
Neovim is the decided editor (spec §3). Shipping both is exactly the pattern
L36 removed plymouth for: a package nothing chose, surviving because removing it
looks riskier than leaving it. `nano` stays deliberately, as the fallback for
when something is broken and a modal editor is the wrong tool. A test asserts
`vim` does not come back.
**Trigger:** gap review applied to a new milestone rather than only backwards.

### L40 — Handler assertions query `xdg-mime`, they do not check for a file
Asserting that `/etc/xdg/mimeapps.list` exists would pass for a file that
resolves to nothing. The gate asks `xdg-mime query default` for html, png, mp4,
pdf and directories and compares the answer. Writing that assertion is what
surfaced the dependency: resolution needs `update-desktop-database` to have run,
which the apps phase now does.
**Trigger:** writing the assertion honestly.
