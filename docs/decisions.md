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

---

## D17 — `pi` ships from `@earendil-works/pi-coding-agent` (REVISED)

**Superseded. The original decision was wrong, and wrong for an avoidable
reason.**

The first version of this decision dropped `pi` entirely, on the grounds that
no installable `pi` CLI existed: `@mariozechner/pi-agent` publishes no `bin` at
all, and `@mariozechner/pi` is a different tool whose binary is `pi-pods`.

Both of those facts are true, and both are about **the wrong packages**. pi is
published by a different author. The correct package is
`@earendil-works/pi-coding-agent` (0.85.1 at time of writing), it declares
`bin: {pi}`, and <https://pi.dev/> documents it as the primary npm install.

The failure was searching the registry for a name and reasoning from what came
back, instead of going to the project's own page first. "I could not find it"
was recorded as "it does not exist". A unit test now pins the package name, so
the wrong one cannot quietly return.

**Rule this leaves behind:** when verification comes back negative, check the
upstream's own documentation before recording an absence. A negative result
from a registry search is weak evidence.

## D18 — `gh` is a package, not a stub

`gh` is not a package name. Arch ships the GitHub CLI as `github-cli` in
`extra`, and it is now in `manifest/core.packages`.

Wrapping it in a mise stub instead would have taken a tool Arch already
packages, signs and updates, and replaced it with an unsigned copy from a
second registry that pacman cannot see. Stubs exist for what Arch does *not*
package. A unit test asserts `gh` never appears in `manifest/agents.tsv`.

**The trade this makes, stated plainly.** Spec §9.1 had `gh` as a lazy stub, so
it cost nothing until used. As a core package it is installed on every machine
whether or not the user touches GitHub. Together with the node toolchain that
the stubs require (L42), this milestone added roughly 80MB to every install:

| Package | Why it is in core | Paid by |
|---|---|---|
| `github-cli` | pacman signatures and updates, rather than an unsigned second registry | everyone |
| `nodejs`, `npm` | every stub resolves through mise's npm backend; the alternative is a large silent download at first launch, outside pacman's reach | everyone |

That is a real cost and the reasoning above is not a free win. It is judged
worth it because a base system that cannot verify what it installed is a worse
default than one that is 80MB larger — but if the project ever needs to defend
its install size, this is the first place to look, and moving `github-cli` to an
extras group is the obvious lever.

## D19 — The `archwright` CLI arrives in milestone 5

The plan put the CLI in milestone 6. But §9.2 and §9.4 define their features as
`archwright default agent` and `archwright sudo-window` — the CLI is not a
milestone 6 nicety, it is where milestone 5 lives.

So `bin/archwright` ships now with `agent`, `default`, `mise-install`,
`sudo-window`, `version` and `help`. Milestone 6 adds `hardware` and `theme` to
the same dispatcher rather than introducing a second command.

## D20 — The shared skill is linked into every agent's skills directory (REVISED)

**Superseded. The original decision was wrong about the purpose, and wrong
about the facts.**

The first version linked the shared skill only into `~/.claude/skills`, on the
grounds that nothing else read a per-user skills directory, and that three
symlinks nothing follows is the plymouth pattern (L36).

That reasoning misses what the directory is *for*. The point of a shared skill
describing this system's layout is that **any** agent on the machine can be
asked to change the system - restyle the bar, turn off the idle lock, add a
package - and finds the same description of how it is put together. An agent
without the link is an agent that has to be told all of it again, or that
guesses. The links are not decoration around one supported agent; they are the
mechanism.

The factual claim was also wrong. All four paths are real:

| Path | Read by |
|---|---|
| `~/.claude/skills` | Claude Code |
| `~/.codex/skills` | Codex CLI |
| `~/.pi/agent/skills` | pi |
| `~/.agents/skills` | the cross-agent location in the agentskills.io standard |

`~/.agents/skills` in particular is a standard, not a guess, and pi scans it.

The plymouth comparison does not hold either: plymouth was a package nothing
configured, costing disk and boot time. A symlink into a directory an agent may
create later costs nothing and is already correct when that agent arrives.

---

## 2026-09-07 — milestone 5: the AI layer

### L41 — Package verification before planning changed three design decisions
Checking the Arch package API and the npm registry *before* writing the plan
produced D17, D18 and D19 — one tool dropped, one moved out of the stub system
entirely, and one milestone boundary redrawn. None of that would have surfaced
until the gate, and D17 would not have surfaced until a user ran the command
weeks later. This is the same check that caught `walker` being AUR-only and
that would have caught the Limine tooling.
**Trigger:** the rule, applied on purpose rather than remembered afterwards.

### L42 — `nodejs` and `npm` are installed rather than bootstrapped by mise
Every stub resolves through mise's npm backend, which needs a node toolchain.
Letting mise install its own would put a runtime outside pacman's reach and
turn the first launch of the first agent into a large silent download at the
worst possible moment — someone trying an agent for the first time on a new
machine. Arch packages both, so both are in the `ai` group.
**Trigger:** writing the "a stub installs on first run" assertion and asking
what it would actually download.

### L43 — The sudoers rule is validated before it is installed, not after
`archwright sudo-window` writes the NOPASSWD rule to a temp file, runs
`visudo -cf` against it, and only then `install`s it into `/etc/sudoers.d/`. A
malformed file there is not a bug you fix afterwards: `sudo` refuses to run at
all, and a running session that has already dropped privileges has no way back
in. The gate re-runs `visudo -c` against the whole configuration after the
grant and again after the revert.
**Trigger:** writing the feature and asking what the worst outcome is.

### L44 — The revert is a systemd timer, not a background sleep
A `sleep N && rm` subshell dies with the terminal that started it, so a closed
lid, a crashed shell or a `killall` leaves passwordless root in place
permanently, silently. `systemd-run --on-active` survives all of those because
nothing about it depends on the granting process. Asking twice replaces the
pending timer rather than letting the first one close the second window early.
**Trigger:** asking how the feature fails rather than how it works.

### L45 — The test harness was launching the developer's real agent
`test_cli.sh` asserts that launching a missing agent fails. It passed — because
the developer running the suite has a real `claude` on `PATH`, so the CLI's
fallback found it and *launched Claude* instead of testing the failure path.
The test now sandboxes `PATH` alongside `HOME`. Any test that exercises a
`command -v` fallback has this hole.
**Trigger:** an assertion failing for the wrong reason and being read rather
than adjusted.

### L46 — `cmd | grep -q` inverts under `pipefail`
Two checks written as `archwright bad-command 2>&1 >/dev/null | grep -q .`
reported failure while the code was correct: with `set -o pipefail` the
pipeline reports the CLI's exit 2, not grep's verdict. Every such check in a
`pipefail` file is silently wrong in one direction or the other. Capture the
output into a variable and assert on that.
**Trigger:** a green implementation failing its own test.

### L47 — The shared skill link's depth is computed, not assumed
`~/.claude/skills/archwright` is two levels below `$HOME`, so the relative link
needs `../../`. Hardcoding that would produce a dangling symlink the moment
someone adds a link at a different depth, and a dangling symlink is invisible
until an agent silently fails to find the skill. The phase derives the depth
from the path and then asserts the link resolves.
**Trigger:** adding the second entry to a list that had one.

## Known gaps carried out of milestone 5

| Gap | Why it is acceptable for now |
|---|---|
| No agent is authenticated | Every agent needs the user's own credentials. Archwright installs the launcher; signing in is the user's first act. |
| The first launch of each agent needs network | Inherent to lazy stubs. The trade is a fast install against one slow first run, and it is documented in the generated stub itself. |
| `sudo-window`'s re-exec through `sudo` is not gated | The VM assertions already run as root, so they exercise everything after the re-exec. The re-exec itself is three lines and unit-tested for the validation that precedes it. |
| Agent auto-approve flag names are not verified | They ship commented out, so a stale flag produces an error the user sees immediately rather than a silent wrong behaviour. The file says to check `--help`. |
| No agent skill is verified to be *read* | The link resolves and the file parses as a skill, but nothing asserts Claude Code actually loads it — that would mean driving an agent inside the gate. |

### L48 — The sudo window survived a reboot, which is the thing it exists to prevent
An adversarial review of the finished feature found the hole: the drop-in in
`/etc/sudoers.d` is persistent, and a `systemd-run` transient unit lives in
`/run` and is destroyed at shutdown. Reboot inside the window - a crash, a
power cut, or simply rebooting - and the machine came back with permanent
passwordless root and nothing left to remove it. The code, the README and L44
all asserted the opposite in as many words.

Closed with a tmpfiles rule (`r!`, boot-only) that deletes the drop-in at every
boot. The gate runs `systemd-tmpfiles --remove --boot` directly, so it exercises
the real path, and separately asserts the periodic clean does **not** remove a
window that is legitimately open.

**Trigger:** a fresh reviewer asked what happens on reboot. Neither the unit
tests nor the VM gate could have found it: the gate boots the machine exactly
once, before any window is ever opened.

### L49 — A monotonic countdown does not run while a laptop is asleep
Same review, same feature. `--on-active=15m` is `CLOCK_MONOTONIC`, which stops
across suspend. Close the lid two minutes in, open it three days later, and
thirteen minutes of passwordless root were still to come. "A closed lid cannot
leave the window open" was exactly backwards.

Now an absolute wall-clock deadline via `--on-calendar`, which fires on resume
if the time has passed.

**Trigger:** the same question asked about a second state transition.

### L50 — The most dangerous field had the weakest validation
`manifest/agents.tsv` has three fields. Two got charset gates; the third - the
executable name - got only an empty/whitespace check, and it is the one
interpolated **unquoted** into the generated launcher. A row of
`$(id>/tmp/x)y` produced a stub that passed `bash -n`, was installed 0755 onto
the login PATH, and was wired to a compositor keybind.

The comment two blocks above it said "this is a security check, not tidiness".
It was on the wrong field.

All three now share one rule, in both copies of the generator, with the payload
list as test data. The lesson generalises: validate the field by what it *does*
in the output, not by how dangerous it looks in the input.

**Trigger:** a reviewer instructed to find an unvalidated interpolation, who
wrote the exploit rather than describing it.

### L51 — `grep -qx` anchors lines, not strings
`is_command_name` used `printf '%s' "$v" | grep -qxE '...'`. `-x` anchors each
LINE, so any multi-line value passes if one of its lines is legal:
`$'codex\n../../etc/evil'` was accepted. It gated `$SUDO_USER` before a sudoers
write. No working escape was demonstrated - a newline is a literal path
character, so the resulting component never exists - but a security primitive
should not be one `grep` semantic away from mattering. Now `[[ =~ ]]`, whose
anchors are string anchors.
**Trigger:** the same review, testing the validator rather than reading it.

### L52 — The security-critical file was not being linted
`test/lint.sh` globbed `*.sh`. Commands installed onto the finished system have
no extension by design, so `bin/archwright` - the file that writes to
`/etc/sudoers.d` - was outside the lint gate from the day it was added, and
`bin/archwright-limine-update` had been for two milestones before that. The
glob now takes `bin/*` by path.
**Trigger:** a reviewer checking whether the oracle covered the new code, rather
than assuming a green oracle meant covered code.

### L53 — The file teaching the ownership contract was breaking it
`lib/70-ai.sh` wrote the shared `SKILL.md` into the user's tree with a plain
`install`, so re-running the phase discarded any edit they had made. The
document being overwritten is the one that tells agents "Archwright seeds a
user config file once, when it does not exist, and never again". The canonical
copy now lives in `/usr/share/archwright/`, which the ownership table says is
ours to replace, and the user's copy is seeded from it.

Two smaller versions of the same mistake in the same loop: `install -d` reset
the mode of an existing `~/.claude` (which may be 0700 deliberately), and
`ln -sfn` onto an existing real directory would have created a link inside it.
**Trigger:** a reviewer checking a stated rule against the code that states it.

### L54 — An assertion pointed at a directory the code never writes to
`test_cli.sh` checked that a rejected `sudo-window` left no file behind - by
searching the sandboxed `$HOME`, while the CLI writes to `/etc/sudoers.d`. It
could not fail for any implementation, including one that wrote to the real
`/etc/sudoers.d` on every rejected input. `ARCHWRIGHT_SUDOERS_D` existed
specifically to make this testable and no test used it, partly because a
comment described it as "not a test hook".
**Trigger:** a reviewer asking of each assertion "would this fail if the
feature were broken?"

### L55 — A negative verification result is weak evidence
D17 dropped `pi` because a registry search for the name returned packages that
did not provide the command. The correct package is published under a different
author, and the project's own front page documents it. "I could not find it"
became "it does not exist" without ever checking upstream.

The rule that catches package problems before planning still holds; this adds
to it. A **positive** registry result is strong evidence. A **negative** one is
not, and must be checked against the project's own documentation before an
absence is recorded as a decision.
**Trigger:** the user supplying the URL the search should have led to.

### L56 — Fixing a security bug is where the next one gets introduced
The first round of fixes for L48/L49 was reviewed again, and two of the fixes
were themselves defects — one strictly worse than the bug it replaced.

**The wall-clock deadline.** Replacing `--on-active` with `--on-calendar`
closed the suspend leak and opened a hole: `date` formats in the *caller's*
timezone, systemd evaluates `OnCalendar` in the *system's*, and `sudo` passes
`TZ` through. When the resulting instant is already past, systemd finds no
future occurrence and marks the timer inactive **without firing it**. A stepped
clock does the same thing — `timesyncd` correcting a dual-boot machine's RTC is
enough. Permanent passwordless root, behind a success message, in a case the
monotonic timer had been immune to.

The answer was never either/or. A timer fires at whichever of its triggers
comes first, so it now carries both: monotonic for clock steps and timezone
confusion, calendar for suspend, UTC on both sides of the calendar value.

**The reordering.** Scheduling the timer before installing the grant protects
the *new* window. It does not protect the *old* one, and asking for a second
window is how you shorten the first. Cancelling its timer before the
replacement was scheduled meant any later failure left the original grant on
disk with nothing pending — while printing "nothing was granted". Every path
past that point now revokes rather than declines.

**Rule this leaves behind:** a fix to a security bug is a new change and needs
the same adversarial pass as the original, from someone who did not write it.
Both of these would have shipped on the strength of a green gate: the VM boots
once, never suspends, and has a correct clock.

### L57 — `shellcheck -s` overrides in-file `shell=` directives
`-s bash` was added to `test/lint.sh` on the belief that shellcheck could not
determine a dialect for the extensionless files in `bin/`. It reads the
shebang, so the flag was unnecessary — and `-s` *overrides* every in-file
`# shellcheck shell=` directive, which switched off all POSIX checking on
`config/profile.d/archwright-agents.sh`. That file is sourced by `/etc/profile`
in whatever shell the user logs in with; a `[[ ]]` or a `local` added to it
would have passed lint and broken the login shell. Removed, and lint stays
clean without it — which is the proof it was doing nothing useful.
**Trigger:** a reviewer testing the claim in the comment instead of reading it.

### L58 — Tightening a filter broke the feature it was protecting
Closing the injection hole (L50) narrowed the mise spec pattern so far that it
rejected every version pin mise documents — `npm:@openai/codex@0.20.0`,
`node@22`, `go:github.com/owner/tool@latest`. Pinning a version is the main
reason to run `mise-install` by hand rather than add a manifest row, so the
hardening removed the command's primary use. All four documented shapes are now
test data.
**Trigger:** a reviewer running the predicate against real-world input rather
than against the attack strings it was written for.

### L59 — Two cleanup assertions passed with the feature deleted
"An open window survives the periodic clean" wrote a file, ran a command that
was not configured to remove it, and asserted it was still there. Delete the
tmpfiles rule entirely and it still passed — "the file survived" is trivially
true when nothing is set up to delete it. Both cleanup checks now assert the
rule's content first. The boot check also left a live `NOPASSWD` rule in the VM
whenever it failed, which the later "sudoers still parses" check happily
accepted.
**Trigger:** "would this fail if the feature were absent?", asked of an
assertion that reads as obviously correct.

### L60 — A test that reads the file it is checking is not an oracle
`test_manifest.sh` pins pi's spec string, which was offered as the guard against
D17's mistake recurring. It proves only that nobody edited the row: it cannot
tell that the package exists, or that it ships the command named in the third
field — which is precisely what was got wrong. The VM gate's first-run
assertion now resolves **pi** rather than crush, so the one assertion in the
suite that talks to a real registry is aimed at the claim with the weakest
evidence behind it.
**Trigger:** a reviewer declining to accept a same-file assertion as
verification.

### L61 — A test-only hook was added to root-executing code for a check that could not fail
`ARCHWRIGHT_SUDOERS_D` was introduced so a unit test could prove a rejected
`sudo-window` writes nothing. It could not, twice over: the assertion created
its own empty directory and then checked it was empty, and `sudo` strips the
variable under `env_reset`, so the sandboxed path was unreachable from a
non-root test in the first place. What remained was an environment override in
the one script on the installed system that writes to `/etc/sudoers.d`.

Both are gone. What a unit test can honestly prove there is that a bad argument
exits 2 before the root re-exec; the write path is gated in the VM, against a
real root and a real sudoers file. Where a check cannot be made real, the honest
move is to delete it and say what covers the gap — not to reshape the product
until the check passes.
**Trigger:** a reviewer asking what the assertion would do against a broken
implementation, and finding the answer was "pass".

### L62 — The test was written around the broken half of the feature
Legalising version pins (L58) fixed the validator and not the name inference, so
`mise-install npm:@openai/codex@0.20.0` passed validation and was then rejected
two lines later as "not a usable command name". The new test passed an explicit
name to every pinned case, stepping around exactly the half that was broken, and
L58 recorded "all four documented shapes are now test data" — true of the
validator, false of the command.

A test that supplies the argument which avoids the bug is not coverage. The
inference path is now exercised without a name, and asserts the resulting file.
**Trigger:** a reviewer running the user-facing command rather than the
predicate under it.

### L63 — A predicate written for the obvious shape missed the simple ones
The traversal guard was `case */../*|../*|*/..`, which needs a slash beside the
dots. A bare `..` and `npm:../x` both walked through, and the one test case
happened to be the interior form that was caught. Anchoring the value between
slashes before matching — `case "/${1#*:}/" in */../*)` — covers all of them.
Inert either way, since the spec only ever reaches mise inside quotes, but the
source called it a security boundary and it did not hold.
**Trigger:** a reviewer enumerating the shapes rather than trusting the pattern.

### L64 — "Kept identical" is a comment, not an oracle
`bin/archwright` ships standalone onto the installed system and cannot source
`lib/`, so it carries its own copy of the three validators. A comment said they
were kept character-for-character identical and nothing enforced it — and the
new spec coverage lived entirely in the CLI's test file, so `lib/agents.sh`'s
copy never saw a version pin or a traversal at all.

A test now extracts and compares both bodies. Mutation-checked: widening one
copy's character class by a single character fails the suite, and nothing else
in it notices.
**Trigger:** a reviewer asking what enforces a claim in a comment.

## Known gaps carried out of milestone 5 (added after review)

| Gap | Why it is acceptable for now |
|---|---|
| Only one of five agent packages is resolved against a real registry | The gate first-runs `pi`, the row with the weakest evidence behind it. The other four are guarded by same-file assertions, which L60 correctly says are not oracles: a package that was unpublished or renamed its bin would still ship green. Resolving all five would cost one slow gate run and is worth doing when the gate is next touched. |
| The stepped-clock and suspend paths of the sudo window are argued, not executed | The gate waits out a one-minute window, which exercises the monotonic trigger for real. Nothing in the harness steps the clock or suspends the VM. The dual-trigger design is reasoned from systemd's elapse semantics. |
| `SIGKILL` between revoking and re-granting | The grant is now removed *before* the old timer is cancelled, so the uncatchable gap contains no grant. A `SIGKILL` in the remaining window loses the *new* grant, never leaks the old one. |

## Self-review of milestone 5 — what the review cycle crowded out

Written after the fact, unprompted by any reviewer, asking a different question:
not "is this code safe" but "did this milestone deliver what it was for".

### S1 — The headline command has never been run on the installed system
`archwright agent` is what `Super + Shift + Ctrl + A` launches and what the `a`
shortcut calls. It is the primary user-facing surface of the whole milestone.
The gate has never executed it. Nor `archwright default agent`, nor
`archwright mise-install`.

What the gate does instead: greps `shell.conf` for the string "archwright
agent", and runs one stub **directly**, bypassing the dispatcher entirely. So
every part of the launch path — reading the recorded default, resolving it in
`~/.local/bin`, the `$HOME` to `~/Work` redirect, forwarding arguments — is
proven only against a fake agent in a unit test.

This traces back to my own plan. Task 6's gate list is nine assertions, and
every one is an artifact check except "a stub installs on first run", which was
written to test mise rather than the command. Three review rounds went past it
without noticing, because I scoped all three to security, and an unexercised
feature is not a vulnerability.

### S2 — Four of the five agent packages have no oracle at all
The gate resolves `pi` against the real registry. `claude`, `codex`, `opencode`
and `crush` are guarded only by assertions that read the same manifest they are
checking — exactly the pattern L60 identifies as not an oracle, and exactly the
class of mistake that produced the wrong D17. Any of the four could be
unpublished, renamed, or have dropped its `bin` declaration, and the gate would
stay green.

### S3 — Core grew by roughly 80MB and nothing says so
`nodejs`, `npm` and `github-cli` were added to `manifest/core.packages` during
this milestone. Spec §9.1 had `gh` as a **lazy stub**; D18 promoted it to a real
package for pacman's signatures and updates, which is defensible — but it means
every install now pays for a tool not everyone wants, and D18 presents that as a
straight improvement rather than a trade. The node toolchain (L42) is the same
shape: a real argument, a real cost, stated only as the argument.

### S4 — Repair outweighed delivery, and most of the repair was avoidable
Thirteen commits: four deliver the milestone, six repair it, three are
housekeeping. Two of the repairs were genuine and serious — a sudo window that
survived a reboot, and one that could fail to close at all. The other four were
my own sloppiness that costs nothing to avoid: a phase that worked but was not
registered in its own whitelist, a lint failure committed because I chained the
check to the commit through a pipe, stale milestone labels, and a test written
around the broken half of the feature it was testing.

The lesson is not "review less" — the reviews found permanent passwordless
root, twice. It is that a fix cycle driven entirely by an adversarial reviewer
optimises for the reviewer's question. Nobody was asking whether the thing
worked.

---

## P2 — The desktop has almost no GUI applications for system tasks — **DONE, see D25-D27**

Raised during milestone 6. The system installs a compositor, a bar and a
terminal, and then expects the terminal for everything else. That is a
defensible position for a developer's machine and an indefensible one for a
system offered to other people: there is currently no graphical way to join a
wifi network, change the volume, pair a Bluetooth device, take a screenshot, or
see what is using the disk.

It also undercuts the point of the project. "Minimal" is not the same as
"unfinished", and a base install anyone can reproduce from the Arch wiki in an
afternoon adds nothing over doing exactly that.

**This needs a discussion before a plan, not a shopping list bolted on.** The
tension is real in both directions: every GUI added is weight on every install
(the milestone 5 audit already found 80MB added without it being stated as a
trade), and a half-set of GUIs is worse than none, because the user cannot tell
which tasks have one.

### Areas with no graphical answer today

| Task | Today | Notes for the discussion |
|---|---|---|
| Wifi / network | `nmtui` in a terminal | The most glaring one. A laptop that cannot join a network without a terminal is not finished. |
| Audio devices, per-app volume | none | |
| Bluetooth | none | No pairing UI at all. |
| Screenshots | **none at all** | Not even a CLI tool is installed. A desktop without a screenshot key is missing a basic function, and this one is cheap. |
| Display arrangement | edit `hyprland.conf` | Matters the moment a second monitor is plugged in. |
| Disk usage / partitions | `lsblk`, `df` | |
| System monitor | `btop` in a terminal | Arguably answered already. |
| Printing | none | Possibly out of scope; worth deciding rather than defaulting. |
| Archives | none | Nautilus needs a helper to extract a zip. |
| Text editor (GUI) | `nvim` | A non-modal editor is a reasonable expectation for a guest at the machine. |
| Calculator | none | Trivial, and conspicuously absent. |

### Questions the discussion has to settle

1. **One settings app or several small ones?** A single control centre is
   coherent but drags in a large dependency set built for a different desktop.
   Several focused tools stay light but leave the user hunting for which one
   owns a given setting.
2. **Where is the line between core and an extras group?** Wifi and screenshots
   look like core. A printer dialog probably does not.
3. **Does anything here need a keybind and a place on the bar**, or is the
   launcher enough?
4. **What does this cost?** Measure it, and state it as a trade — the D18
   lesson.

Nothing above is a decision, and no package named here has been checked against
the official repositories yet. That check comes first, before any plan: it is
the rule that caught walker being AUR-only and would have caught the Limine
tooling.

---

## D21 — Theming is install-time AND switchable afterwards (revises D10)

D10 said theming happens at install time only: pick a palette in the answer
file, write it once, no runtime engine. The reasoning was that a theme daemon
watching for changes is machinery nobody needs.

That still holds — there is no daemon here. But "written once" also meant
"seven palettes you cannot reach", which is most of the value thrown away to
avoid a problem the design never had. `archwright theme set nord` regenerates
seven files and restarts three units. It is a command, not a service.

What makes it safe is the ownership split, which is the actual decision:

| Yours, seeded once, never rewritten | Ours, replaced on every theme change |
|---|---|
| `hypr/hyprland.conf` | `hypr/colors.conf` |
| `waybar/style.css` | `waybar/colors.css` |
| `foot/foot.ini` | `foot/colors.ini` |
| `mako/config` | `mako/colors` |
| `fuzzel/fuzzel.ini` | `fuzzel/colors.ini` |

Every one of those consumers supports an include, which is what makes the split
possible at all. The gate proves it by editing `style.css`, switching theme, and
asserting the edit survived.

## D22 — The default look is not plain (revises the milestone 3 rule)

The compositor config carried: "Square corners, no blur, no shadows. Decided,
not configured." Safe, and indistinguishable from an afternoon with the Arch
wiki. A system worth installing over vanilla Arch has to look like something on
first boot, or there is no reason to clone it.

So: rounded corners, a soft shadow, and blur on the **layer surfaces only** —
the bar, the launcher, notifications. That last distinction is the whole cost
argument. Blurring windows resamples the full framebuffer every frame and shows
up immediately on battery and on integrated graphics; blurring three small
always-on-top surfaces costs almost nothing and is where the effect is actually
visible.

## D23 — Minimal is not the same as unfinished

Stated by the user, and general enough to outlive this milestone: "having a
basic or minimal doesn't mean it has to come vanilla — it should bring some
spice up to avoid having just a vanilla plain, that anyone can do without
cloning my project."

The test for a default is therefore not "is this the smallest thing that
works", it is **"does this need to be here for the system to feel finished".**
Both answers are legitimate; what is not legitimate is defaulting to the
smallest option because it is the easiest to defend.

Applied here: `adw-gtk-theme` and `papirus-icon-theme` are core rather than
extras, because without them the GTK applications look like a different decade
from everything around them — that is not an optional extra, it is the
difference between themed and half-themed. Recorded as P2: the same test
applied to graphical applications finds the system badly short.

## D24 — The wallpaper is generated, not shipped

A photograph means a licence to carry, roughly a megabyte in the repository,
and a background that fights whatever palette is selected. A gradient generated
from the palette costs 31KB, recolours with the theme, and has no licence at
all.

`tools/make-wallpaper.py` is standard library only — no Pillow, no numpy. PNG
is a simple container and zlib is in the stdlib, so the dependency-free version
is about thirty lines longer and cannot rot. It runs on the developer's machine
and the output is committed; generating on the target would mean ImageMagick or
an image library in core, tens of megabytes to draw one gradient.

---

## 2026-09-07 — milestone 6: theming and hardware

### L65 — foot's colour section is [colors-dark], not [colors]
Written from memory of how foot used to work. foot splits its palette into
`colors-dark` and `colors-light`, switchable at runtime, and rejects a plain
`[colors]` section outright. Without the `foot --check-config` assertion this
ships as a terminal with default colours while everything around it is themed,
and nothing anywhere reports an error.
**Trigger:** an assertion that asks the program rather than the file.

### L66 — `include` belongs to the default section
foot and fuzzel both put every option after a `[section]` header into that
section, so an include at the bottom of the file is read as
`[scrollback].include` and rejected. The documentation says the included file
has its own section scope and that the including file is still in the default
section afterwards — which describes this exactly, without spelling out that
the directive itself has to be there.
**Trigger:** the same two assertions, on the second run.

### L67 — The two config trees are rooted differently
`/usr/share/archwright/default-config` is already laid out relative to
`~/.config`. Baking a `.config/` prefix into the theme manifest put `foot.ini`
at `default-config/.config/foot/foot.ini`, where the seeding phase could not
find it. Destinations are now relative and the caller supplies the root, which
a unit test enforces.
**Trigger:** the gate, on the phase immediately downstream.

### L68 — A link written from outside the target cannot be checked from outside it
The theme phase writes an absolute symlink into the target's home. Testing it
with `[ -f ]` from the installer asks the LIVE ISO's filesystem, not the
target's, and fails a perfectly good install. Check the link's target with
`readlink`; whether it resolves is a question only the booted system can
answer, and that is where the gate asks it.
**Trigger:** the gate, on a phase that had otherwise completed.

### L69 — Dither is 44x the file size, and the compositor removes the banding anyway
Measured per palette: 1920x1080 with dither, 1362KB; 1280x720 with dither,
422KB; 1280x720 without, 31KB. Noise is the entire difference, and it exists to
hide banding that swaybg's bilinear upscaling removes for free. Rendering small
and letting the compositor smooth it turned 9.5MB of wallpapers into 216KB.
**Trigger:** looking at the output size before committing it.

### L70 — `cmd | grep -q` under pipefail, again
L46 recorded this in milestone 5. It was reintroduced in milestone 6, in a new
assertion, and cost a gate run to diagnose. **Writing a lesson down does not
prevent it.** The durable fix is a check that fails, not a paragraph that
explains — which is why `check_v` now exists, and why this pattern is worth a
lint rule rather than another log entry.
**Trigger:** a green implementation failing its own assertion.

## Known gaps carried out of milestone 6

| Gap | Why it is acceptable for now |
|---|---|
| No hardware script's apply path has run on real hardware | The VM has a virtio GPU and no battery, so the gate proves only that every script no-ops cleanly and leaves nothing behind. Detection is unit-tested against fixture sysfs trees covering Intel, AMD, NVIDIA, hybrid laptops and virtio; what the drivers then do is untested. |
| **NVIDIA still will not reach a session, unverified** | Modesetting is now configured in `modprobe.d` and the initramfs, which is the usual cause of a black screen. Whether that is sufficient on a real card is unknown. This gap has been carried since milestone 2 and is now *addressed but not closed*. |
| The suspend lock has never suspended a machine | The unit is installed and enabled on a machine with a battery. Nothing in the harness closes a lid. |
| Only Mocha is exercised end to end | The gate installs Mocha and switches to Tokyo Night and back. The other five are covered by rendering every template for every palette in unit tests, which catches a bad value but not a bad-looking one. |
| GTK theming is asserted by file, not by appearance | `archwright-apply-gtk-theme` needs a session bus; the gate checks the settings files exist and that the script is autostarted, not that Nautilus came up dark. |
| No light palette is gated | `latte` renders and is selectable, but the gate never installs it, so the light branch of the GTK applier is unexercised. |
| ~~Blur on the bar, launcher and notifications is off~~ **CLOSED** | The replacement syntax was confirmed against the installed compositor and blur ships; its `ignore_alpha` companion followed in D28. |

### L71 — Hyprland starts happily on a config it rejects
The user booted the installed system and found six errors painted across the
desktop. Every assertion in the gate passed: the session came up, hyprctl
answered, the accent applied, rounding applied. All true, and all beside the
point - Hyprland does not refuse a bad option, it ignores the line and shows a
complaint overlay.

The cause was real: Hyprland 0.53 replaced the window and layer rule syntax,
and `layerrule = blur, waybar` is the old form. 0.56 installs today.

`hyprctl configerrors` is now a gate assertion. It should have been one from
the moment that file grew past a handful of lines, and its absence is a
specific failure of imagination: **I asserted every effect I expected and never
asked the program whether it was happy.** That generalises past this config -
anything with a `--check-config`, a `configerrors`, or a validate subcommand
should be asked directly rather than inferred from its output.

**Trigger:** the user booting the thing and looking at it. Nothing in the
harness was going to find this.

### L72 — Two assertions written to catch it were themselves wrong
Worth recording together, because the pattern is the point.

The waybar journal check grepped for `css|style|parse`, which matches waybar's
own `[info] Using CSS file ...` line on every healthy start. It could not pass.

The Hyprland check required the literal string `no errors`; this version prints
*nothing* when the config is clean. It could not pass either - the check
written to catch the bug failed for the opposite reason to the bug.

Both were written quickly, in the same sitting, while fixing something urgent.
A new assertion needs its own moment of "what does this do when the system is
healthy", and neither got one.
**Trigger:** the gate, twice, on consecutive runs.

### L73 — A probe whose failure has two explanations answers nothing
To settle the 0.53 syntax, the gate tried four candidate layer rules through
`hyprctl keyword` and reported all four rejected. That reads as decisive and is
worthless: `hyprctl keyword layerrule` does not apply layer rules at all on
this version, so every rejection could mean a wrong syntax or a channel that
never works.

Removed rather than left in, because a misleading result is worse than no
result - the next person reads "all four rejected" and believes the question is
closed.
**Trigger:** the probe returning a suspiciously uniform answer.

---

## P2 — Graphical applications for system tasks — **DONE**

Raised by the user during milestone 6 and settled here. The system installed a
compositor and a terminal and expected the terminal for everything else: no
graphical way to join a wifi network, set the volume, pair a Bluetooth device
or take a screenshot — not even a CLI screenshot tool was present.

## D25 — Several focused tools, not one control centre

`gnome-control-center` is **23 MB with 56 direct dependencies**, and several of
its panels expect `gnome-settings-daemon` and `mutter` to be running. In a
Hyprland session those panels are inert. Paying a large GNOME dependency tree
for a settings app that is partly non-functional is the worst of both answers.

So: small, focused tools, each opened from the bar element it belongs to.
Clicking the network indicator opens the connection editor, the volume
indicator opens `pavucontrol`, the Bluetooth indicator opens `blueman`. That is
the whole graphical-settings story here — there is no settings app to find,
because the thing you were already looking at is the way in.

**The verification that mattered:** `network-manager-applet` ships **only**
`nm-applet`. `nm-connection-editor` is a separate 4.5 MB package. And they do
different jobs — the applet's tray menu is what lists networks to *join*, the
editor edits *saved* connections. Shipping only the editor, which is what the
package name suggests it covers, would have left a laptop unable to get online
without a terminal. Both ship, and a unit test asserts both, because the
distinction is not obvious enough to survive a future tidy-up.

## D26 — The wallpaper is yours once you choose one

Before this there was no way to use your own image at all: the wallpaper was
derived from the palette, full stop.

`archwright wallpaper set` records the choice, and from that moment **a theme
change stops replacing it**. `wallpaper reset` hands the decision back. This is
the same contract as the config files (D21) and the seeded launchers: Archwright
picks the default and stops picking the moment the user does.

The choice is recorded in a state file rather than inferred from the symlink,
because a link pointing into our own wallpapers directory is ambiguous — it
could be the palette default or a deliberate pick of that same image.

The gate proves the rule rather than the plumbing: set a picture, change theme,
assert the picture is still there.

## D27 — Pickers built on fuzzel, not a new GUI

`archwright theme pick` and `archwright wallpaper pick` are fuzzel menus on a
keybind. fuzzel is already the launcher, so they look and behave like everything
else, cost nothing, and need no new dependency. The theme picker passes each
palette's own wallpaper as a swatch through Rofi's extended dmenu protocol,
which fuzzel implements; if the icon cannot be loaded the entry is still
selectable, so the failure mode is a plainer list rather than a broken picker.

`azote` (a real thumbnail grid) and `nwg-look` (a GTK settings GUI) are in the
`theming-gui` extras group for people who would rather browse. azote wants to
own wallpaper setting — it launches its own backend — so selecting that group
is choosing azote's way over the systemd unit Archwright manages.

## What it cost, measured

31 MiB of named packages. The largest single entry is `gnome-calculator` at
10.5 MiB, a third of the total, for a calculator; it is the only official-repo
option found and is the obvious cut if install size ever matters.

Measured on the installed system after this milestone: **715 packages,
4,889 MiB total installed size.** That figure is printed by the gate on every
run so the next change has something to compare against, rather than an
argument about whether something is "small".

### L74 — Two packages, one obvious-sounding name
`network-manager-applet` contains no connection editor. The name reads like it
covers the graphical NetworkManager story and it covers half of it. Checking the
package's actual file list — not its name, not its description — is what caught
it, and the same check was already in the project's rules from milestone 4,
where a wrong `.desktop` name would have made a handler resolve to nothing.
**Trigger:** verifying binaries against package file lists before writing a
keybind that calls one.

### L75 — A tool check before argument parsing breaks `--help`
`archwright-screenshot` checked for grim and wl-copy at the top of the file, so
`--help` failed on any machine without them - which is exactly the machine
where someone is most likely to be reading the help. Tools are checked per
action, after the argument is parsed.
**Trigger:** a unit test asserting `--help` exits 0, written because it was
cheap rather than because the failure was suspected.

### L76 — Committed on a red suite, again
`bash test/run-unit.sh; git commit` with a semicolon rather than `&&`. The
failure was printed, scrolled past, and had no effect on what happened next.
This is the same shape as piping a check through `tail` (milestone 4) - the
check runs, the result is visible, and nothing acts on it. The fix is
mechanical: a check and a commit never belong in the same command.
**Trigger:** reading the exit code in the output after the commit had landed.

## Known gaps carried out of P2

| Gap | Why it is acceptable for now |
|---|---|
| No picker has been operated by a human | The gate runs `wallpaper set/reset` and `theme set` directly. `theme pick` and `wallpaper pick` open fuzzel and wait for a selection, which the harness cannot make - so the pickers are unexercised end to end, exactly like every keybind on this system. |
| Whether fuzzel renders a wallpaper PNG as a swatch is unverified | The icon is passed as an absolute path through Rofi's protocol; fuzzel documents icon *names*. If it cannot load one, the list degrades to text. Nothing asserts which happened. |
| `azote` and `nwg-look` are never installed by a gate run | The `theming-gui` group is asserted absent, not exercised. The conflict between azote's backend and the swaybg unit is reasoned, not observed. |
| Bluetooth and printing are untestable here | The VM has no Bluetooth controller and no printer. `blueman-manager` exists as a binary; nothing pairs anything. |

## P3 — No audio has ever been heard — **DONE**

Found by the user playing YouTube in the VM through a SPICE client: video fine,
no sound on the host.

**Cause, confirmed:** QEMU is started with no sound card. Neither
`tools/boot-installed.sh` nor `test/vm/drive_vm.py` passes `-audiodev` or any
audio device, so the guest has no hardware for PipeWire to play to. Nothing is
misconfigured in the guest.

**The sharper problem.** The gate asserts `pipewire` and `wireplumber` are
running. That is processes, not output — so the audio stack has never been
shown to produce a sound on any machine, virtual or physical. "Audio works" has
been claimed since milestone 2 on the strength of two `pgrep` calls.

**What it needs.** An audio device on the QEMU command line
(`-audiodev pa|pipewire,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0`
or the SPICE audio channel, which virt-viewer can carry), and then a gate
assertion that plays something and confirms a sink actually consumed it -
`wpctl status` showing a sink, or `pw-cat` to a null sink with a check on the
counters. Verify the flags against the QEMU in use before planning: this is the
same class as the layerrule syntax, where the documented form and the installed
version's form differed.

### P3, resolved

The VM has a sound card in both harnesses, `--spice` routes guest audio to
virt-viewer so it can be heard on the host, and the user confirmed real sound
from a real boot.

Three assertions replace the two `pgrep` calls, in increasing order of meaning:
the guest has a card, wireplumber published a sink from it, and a generated WAV
plays through `pw-play`. The gate's backend discards the samples - there are no
speakers - but everything from the application down to the device is now
exercised. `-audiodev none` does produce a usable sink, which was the open
question and is now answered rather than assumed.

### L77 — Three gate runs to find a missing function, because the checks were mute
The audio assertions failed twice with empty output. `check_v` exists to print
a command's own output on failure; both new functions produced none - one piped
straight into `grep -q`, the other sent stderr to `/dev/null` before returning
1, so a broken WAV generator and a broken audio stack were indistinguishable.

With the output restored, the third run named it in one line: `as_user: command
not found`. The helper was defined in the milestone 3 section and called from
the milestone 2 section above it. Nothing to do with audio at all.

The lesson is not "define functions early". It is that **a check which cannot
explain itself costs a full gate run per guess**, and that suppressing output
inside a function defeats the wrapper written to show it. Two runs bought
nothing.
**Trigger:** the user hearing silence in the VM - the harness had asserted
audio worked for five milestones on two process checks.

---

## D28 — The blur companion rule, settled by asking the parser

The one line left open out of milestone 6. Blur ships on the bar, the launcher
and the notifications; `ignorezero`, the rule that stops the compositor blurring
the fully transparent margin around them, did not, because its post-0.53
spelling had never been put to a compositor and a guess in a config file is what
painted six errors over the desktop the first time.

Settled by booting the last passing image read-only and reloading candidate
lines into it, the same method the blur lines were confirmed with, but with one
change that did all the work: **print the parser's error text instead of a
pass/fail.** Nine candidates went in as one file, one reload, and the answer
came back named:

    invalid field ignorezero: missing a value      <- the old name, still known
    invalid field type ignorealpha                 <- not this either
    (no error)                                     <- ignore_alpha 0.2

So on 0.56 the field is `ignore_alpha` and it takes a threshold. Round one had
probed three `ignorezero` spellings one at a time, each costing a reload, and
learned only that all three were wrong. Round two asked for the message and
finished in a single pass.

`0.2`, not `0.0`: it covers the antialiased rounded corners as well, and every
surface that should be blurred sits at 0.80 alpha or above.

The gate's informational probe now carries both shipped forms next to the
spelling each replaced, so the next Hyprland grammar change shows up as an
ACCEPTED line moving rather than as errors on someone's desktop.

**Trigger:** the user asking what the `ignorezero` line was, then asking for it.

### D28, measured

"It parses" is not "it does anything". The user asked how they would know it
works in the running system, and the honest first answer was that on the stock
wallpaper they would not - a blurred gradient is the same gradient. So it was
measured instead, in a booted image, with grim.

Getting the measurement right took three attempts and both wrong ones were the
same mistake: **no detail behind the surface under test.**

  1. Screenshot a terminal full of text, make it the wallpaper. Invalid - a
     full-screen grab has the old bar over the gradient in its top rows, so the
     region being measured still had nothing behind it.
  2. Grab below the bar instead, so the wallpaper is text all the way up. Now
     the numbers moved, but "edge energy" only said the pixels changed, not
     that the blur had stopped.
  3. Compare against the same screen with **waybar stopped**. No inference
     left:

     | frame | the bar's transparent strip vs. no bar at all |
     |---|---|
     | `ignore_alpha` ON  | mean 0.000 - 0 of 19200 bytes differ. Identical. |
     | `ignore_alpha` OFF | mean 4.060 - 819 bytes differ by >8 |

Two consecutive frames were byte-identical, so the noise floor is exactly zero
and those numbers are the rule and nothing else. With it on, the bar
contributes nothing at all to its own transparent pixels.

Checked at the same time, because a rule matching nothing looks exactly like a
rule that works: all three namespaces are real - `waybar` (1280x34), `launcher`
(fuzzel), `notifications` (mako). And every surface the threshold applies to
sits above it: the pills at 0.80, their border at 0.65, fuzzel at 0xf2. The one
value below 0.2 in the bar's stylesheet is a hover tint at 0.16, which is
composited over an 0.80 pill before the compositor ever sees it.

mako's background is opaque, so blur on `notifications` does nothing visible
today and `ignore_alpha` there only trims the rounded corners. Correct and
future-proof, not useful yet.


### L78 — A rejection is a fact; a rejection with a reason is an answer
Two probes, same VM, same method. The first returned "rejected" three times and
closed nothing. The second returned the parser's own sentence and closed the
question in one reload. The difference was one line of shell - keeping `out`
instead of testing it - and it is the same lesson as L77 from the other side: a
check that cannot explain itself costs a run per guess.
