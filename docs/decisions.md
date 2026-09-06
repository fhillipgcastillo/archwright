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
GRUB and systemd-boot; `limine-snapper-sync` is what keeps the boot menu in step
with snapper. This one requirement rules out the `archinstall` JSON path in D4.

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
| **No firewall** | The spec calls for `ufw` deny-all-inbound (D-level, §3). `ufw` is not in the manifest and nothing configures it, while `sshd` **is** enabled — so a fresh install listens on port 22 unprotected. Harmless in a VM, not on real hardware. Close before shipping anything to a real machine |
| **Plymouth installed but unconfigured** | No boot splash, no themed unlock. Dead weight until the theming milestone |
| **`fetch-shellcheck.ps1` does not verify a checksum** | Unlike `fetch-arch-iso.sh`, which checks sha256. Inconsistent |
| **`libnotify` now unused** | See L13 |
| **Windows host path unmaintained** | `test/vm-install.ps1` and `tools/fetch-qemu-windows.ps1` are not written or verified. See D13 |
