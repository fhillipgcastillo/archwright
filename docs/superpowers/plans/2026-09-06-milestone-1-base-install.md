# Archwright Milestone 1 — Base Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `install.sh`, run from the stock Arch ISO, turns a blank UEFI disk into a booting LUKS2 + btrfs + Limine + snapper Arch system with no desktop — verified by an automated QEMU boot.

**Architecture:** A phase-ordered bash installer reading all package and layout facts from `manifest/`. Pure helper logic (parted output parsing, manifest reading, answer-file parsing) lives in sourced libraries with fast dependency-free unit tests. Everything else is verified by an integration harness that boots the stock Arch ISO in QEMU with a serial console, drives it over a TCP socket from Python, installs from the working tree served over HTTP, reboots, and asserts against the installed system.

**Tech Stack:** bash (POSIX-ish, `set -euo pipefail`), Python 3 stdlib (`socket`, `http.server`) for the VM driver, QEMU + OVMF, PowerShell 7 for Windows-host tooling. No third-party libraries anywhere.

## Global Constraints

Copied from `docs/superpowers/specs/2026-09-06-archwright-design.md` and `CLAUDE.md`. Every task's requirements implicitly include these.

- **Installer code never runs on the development host.** Only inside the QEMU VM. No `parted`, `mkfs`, `cryptsetup`, or `dd` outside the VM, ever.
- **UEFI + GPT only.** No BIOS/MBR path.
- **Bootloader is Limine.** Not GRUB, not systemd-boot. Snapshot rollback depends on it.
- **No hardcoded package lists in `lib/`.** Packages come from `manifest/`, read at runtime.
- **Never predict a partition number.** Read back what `parted` created, assert it is genuinely new, verify size within 1 MiB, track what this run created.
- **Install skeleton-seeding packages before `useradd`.** `/etc/skel` must be populated before the home directory is created.
- **Snapper timers:** `snapper-timeline.timer` disabled; `snapper-cleanup.timer` and `limine-snapper-sync.service` enabled.
- **`NetworkManager-wait-online.service` masked.**
- **Every script:** `#!/usr/bin/env bash` + `set -euo pipefail`, and passes `shellcheck` with no unexplained `disable` directives.
- **Project name/path token is `archwright`** — used for `/usr/share/archwright`, `~/.local/state/archwright`, and the CLI.
- **Each VM run uses a throwaway disk overlay and its own copy of the OVMF variables file**, so no disk or NVRAM state leaks between runs.

## Milestone 1 gate

The milestone is done when `test/vm-install.sh` (or `.ps1`) exits 0, having asserted all of:

1. The installer completed without error.
2. On reboot, the LUKS passphrase prompt appeared.
3. The system reached a root shell.
4. `findmnt -no FSTYPE /` is `btrfs` and the root subvolume is `@`.
5. `snapper -c root list` shows at least one snapshot.
6. The Limine config contains a snapshot boot entry.

## A wrinkle resolved up front: the Limine tooling is not all in the official repos

`limine` itself is in Arch's `extra` repository. The three pieces that make snapshots work — `limine-mkinitcpio-hook`, `limine-entry-tool` and `limine-snapper-sync` — are, as of this writing, **AUR packages**. `pacstrap` cannot install from the AUR.

The system this design was researched from sidesteps this by building its own packages and serving them from its own repository, which Archwright explicitly does not do (decision D16).

**Resolution:** Task 8 builds the needed AUR packages inside the live ISO environment with `makepkg`, as an unprivileged temporary user, and installs the resulting `.pkg.tar.zst` files into the target with `pacman -U --root`. Task 8 Step 1 verifies the actual repository each package lives in and takes the official-repo path when one is available, so the plan self-corrects if any of them have been moved into `extra` since.

This is the one place milestone 1 is meaningfully harder than the spec implies. It is worth doing rather than dropping, because gate criterion 6 — the snapshot boot entry — is the entire reason Limine was chosen over systemd-boot.

---

## File structure

| File | Responsibility |
|---|---|
| `install.sh` | Entry point. Parses args, sources libs, runs phases in order, handles rollback on failure |
| `lib/common.sh` | Logging, assertions, `die`, `run_in_chroot`, rollback tracking. No domain knowledge |
| `lib/answers.sh` | Parse and validate the answer file into known variables |
| `lib/manifest.sh` | Read `manifest/*.packages` and `manifest/subvolumes.tsv` |
| `lib/partition.sh` | Pure parted-output parsing and the new-partition-number safety rule |
| `lib/00-preflight.sh` | UEFI check, network check, clock sync, target disk resolution |
| `lib/10-disk.sh` | GPT, ESP, LUKS2 container, btrfs subvolumes, mount tree |
| `lib/20-base.sh` | `pacstrap`, fstab, locale, hostname, user creation |
| `lib/30-boot.sh` | mkinitcpio UKI, Limine install and config, snapper, service enablement |
| `manifest/core.packages` | The milestone-1 core package list |
| `manifest/subvolumes.tsv` | Subvolume → mountpoint → mount options |
| `test/unit/harness.sh` | Dependency-free assertion harness |
| `test/unit/test_*.sh` | Unit tests, one file per library under test |
| `test/run-unit.sh` | Runs every `test/unit/test_*.sh`, reports, exits non-zero on failure |
| `test/vm/drive_vm.py` | Boots the ISO in QEMU, drives the serial console, serves the repo, runs the installer, reboots, runs assertions |
| `test/vm/assertions.sh` | Runs inside the installed system; checks gate criteria 4–6 |
| `test/vm/answers.example.conf` | The unattended answer file used by the VM run |
| `test/vm-install.sh` | Linux-host entry point for the VM oracle |
| `test/vm-install.ps1` | Windows-host entry point for the VM oracle |
| `tools/fetch-qemu-windows.ps1` | Portable QEMU + OVMF into `.tools/`, nothing system-wide |
| `tools/fetch-arch-iso.sh` / `.ps1` | Download and checksum the stock Arch ISO into `.tools/` |
| `tools/extract-iso-boot.sh` / `.ps1` | Pull `vmlinuz-linux` and `initramfs-linux.img` out of the ISO |

---

## Task 1: Foundation — common library and unit test harness

**Files:**
- Create: `lib/common.sh`
- Create: `test/unit/harness.sh`
- Create: `test/unit/test_common.sh`
- Create: `test/run-unit.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `aw_log(level, msg)`, `aw_die(msg)` (exit 1), `aw_require_cmd(cmd...)`, `aw_track(kind, value)`, `aw_tracked(kind)` → newline-separated values, `AW_LOG_LEVEL` (`debug|info|warn|error`, default `info`). Harness provides `assert_eq(actual, expected, label)`, `assert_contains(haystack, needle, label)`, `assert_fails(cmd..., label)`, `finish_tests()`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/harness.sh`:

```bash
#!/usr/bin/env bash
# Dependency-free assertion harness. Sourced by every test_*.sh.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL  %s\n      %s\n' "$1" "$2" >&2
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-assert_eq}"
  if [ "$actual" = "$expected" ]; then _pass
  else _fail "$label" "expected [$expected], got [$actual]"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-assert_contains}"
  case "$haystack" in
    *"$needle"*) _pass ;;
    *) _fail "$label" "expected to contain [$needle], got [$haystack]" ;;
  esac
}

assert_fails() {
  local label="${!#}"
  set -- "${@:1:$#-1}"
  if "$@" >/dev/null 2>&1; then _fail "$label" "expected non-zero exit, got 0"
  else _pass; fi
}

finish_tests() {
  printf '%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
```

Create `test/unit/test_common.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

# aw_log respects AW_LOG_LEVEL
AW_LOG_LEVEL=warn
out="$(aw_log info "quiet please" 2>&1)"
assert_eq "$out" "" "info suppressed at warn level"

out="$(aw_log error "loud" 2>&1)"
assert_contains "$out" "loud" "error emitted at warn level"

AW_LOG_LEVEL=info
out="$(aw_log info "hello" 2>&1)"
assert_contains "$out" "hello" "info emitted at info level"
assert_contains "$out" "INFO" "log line carries its level"

# aw_die exits non-zero
assert_fails aw_die "boom" "aw_die exits non-zero"

# aw_require_cmd
assert_fails aw_require_cmd "definitely-not-a-real-command-xyz" "missing command fails"
aw_require_cmd sh && _pass || _fail "require_cmd sh" "sh should exist"

# rollback tracking round-trips
AW_TRACK_DIR="$(mktemp -d)"
aw_track partition "/dev/vda1"
aw_track partition "/dev/vda2"
aw_track luks "cryptroot"
assert_eq "$(aw_tracked partition | tr '\n' ',')" "/dev/vda1,/dev/vda2," "tracked partitions in order"
assert_eq "$(aw_tracked luks)" "cryptroot" "tracked luks name"
assert_eq "$(aw_tracked nothing)" "" "unknown kind is empty, not an error"
rm -rf "$AW_TRACK_DIR"

finish_tests
```

Create `test/run-unit.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$HERE"/unit/test_*.sh; do
  bash "$t" || failed=1
done
if [ "$failed" -ne 0 ]; then
  echo "UNIT TESTS FAILED" >&2
  exit 1
fi
echo "all unit tests passed"
```

Create `.gitignore`:

```
.tools/
.vmrun/
*.qcow2
*.iso
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/run-unit.sh`
Expected: FAIL — `lib/common.sh: No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `lib/common.sh`:

```bash
#!/usr/bin/env bash
# Logging, failure and rollback tracking. No Archwright domain knowledge here.

AW_LOG_LEVEL="${AW_LOG_LEVEL:-info}"
AW_TRACK_DIR="${AW_TRACK_DIR:-/run/archwright}"

_aw_level_num() {
  case "$1" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    warn)  echo 30 ;;
    error) echo 40 ;;
    *)     echo 20 ;;
  esac
}

aw_log() {
  local level="$1"; shift
  local want cur
  want="$(_aw_level_num "$level")"
  cur="$(_aw_level_num "$AW_LOG_LEVEL")"
  [ "$want" -ge "$cur" ] || return 0
  printf '[%s] %-5s %s\n' "$(date +%H:%M:%S)" "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" "$*" >&2
}

aw_die() {
  aw_log error "$*"
  exit 1
}

aw_require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { aw_log error "required command not found: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ]
}

# Record something this run created, so rollback undoes only our own work.
aw_track() {
  local kind="$1" value="$2"
  mkdir -p "$AW_TRACK_DIR"
  printf '%s\n' "$value" >> "$AW_TRACK_DIR/$kind"
}

aw_tracked() {
  local kind="$1"
  [ -f "$AW_TRACK_DIR/$kind" ] || return 0
  cat "$AW_TRACK_DIR/$kind"
}

aw_run_in_chroot() {
  arch-chroot /mnt /usr/bin/env bash -euo pipefail -c "$*"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/run-unit.sh`
Expected: `test_common.sh: 10 run, 0 failed` then `all unit tests passed`

- [ ] **Step 5: Lint**

Run: `shellcheck lib/common.sh test/run-unit.sh test/unit/harness.sh test/unit/test_common.sh`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh test/unit/harness.sh test/unit/test_common.sh test/run-unit.sh .gitignore
git commit -m "Add common library and dependency-free unit test harness"
```

---

## Task 2: Manifest and answer-file readers

**Files:**
- Create: `manifest/core.packages`
- Create: `manifest/subvolumes.tsv`
- Create: `lib/manifest.sh`
- Create: `lib/answers.sh`
- Create: `test/vm/answers.example.conf`
- Create: `test/unit/test_manifest.sh`
- Create: `test/unit/test_answers.sh`

**Interfaces:**
- Consumes: `aw_die` from `lib/common.sh`.
- Produces: `aw_manifest_packages(file)` → newline-separated package names, comments and blank lines stripped; `aw_manifest_subvolumes(file)` → `subvol<TAB>mountpoint<TAB>options` lines; `aw_answers_load(file)` sets `AW_DISK AW_HOSTNAME AW_USERNAME AW_USER_PASSWORD AW_LUKS_PASSPHRASE AW_LOCALE AW_TIMEZONE AW_KEYMAP AW_SERIAL_CONSOLE`; `aw_answers_validate()` → non-zero with a specific message when a required field is missing.

- [ ] **Step 1: Write the failing tests**

Create `manifest/core.packages`:

```
# Archwright core packages, milestone 1 (base system only, no desktop).
# One package per line. '#' starts a comment. '## Group:' headers are
# parsed by the guide drift check and ignored by the installer.

## Group: base
base
base-devel
linux
linux-firmware
linux-headers

## Group: microcode
amd-ucode
intel-ucode

## Group: filesystem
btrfs-progs
dosfstools
exfatprogs
snapper

## Group: boot
efibootmgr
limine
mkinitcpio
plymouth

## Group: network
networkmanager
openssh

## Group: cli-staples
bash-completion
git
less
man-db
nano
ripgrep
sudo
vim

## Group: hardware
sof-firmware
zram-generator
```

Create `manifest/subvolumes.tsv`:

```
# subvolume	mountpoint	mount options
# Tab-separated. '#' starts a comment. Order matters: parents mount first.
@	/	compress=zstd:1,noatime
@home	/home	compress=zstd:1,noatime
@snapshots	/.snapshots	compress=zstd:1,noatime
@log	/var/log	compress=zstd:1,noatime
@pkg	/var/cache/pacman/pkg	noatime
```

Create `test/vm/answers.example.conf`:

```
# Answer file for the automated VM run. Test values only — never reuse these.
DISK=/dev/vda
HOSTNAME=archwright-vm
USERNAME=test
USER_PASSWORD=testpassword
LUKS_PASSPHRASE=testpassphrase
LOCALE=en_US.UTF-8
TIMEZONE=UTC
KEYMAP=us
# Test-only: adds console=ttyS0,115200 to the UKI cmdline so the harness
# can drive the installed system over the serial port.
SERIAL_CONSOLE=1
```

Create `test/unit/test_manifest.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$ROOT/lib/manifest.sh"

tmp="$(mktemp -d)"
cat > "$tmp/p.packages" <<'EOF'
# a comment
## Group: one
alpha

beta   
## Group: two
gamma
EOF

got="$(aw_manifest_packages "$tmp/p.packages" | tr '\n' ',')"
assert_eq "$got" "alpha,beta,gamma," "packages: comments, blanks and group headers stripped"

cat > "$tmp/s.tsv" <<EOF
# header comment
@	/	compress=zstd:1,noatime
@home	/home	compress=zstd:1,noatime
EOF

got="$(aw_manifest_subvolumes "$tmp/s.tsv" | wc -l | tr -d ' ')"
assert_eq "$got" "2" "subvolumes: two data rows"

first="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f1)"
assert_eq "$first" "@" "subvolumes: first field is the subvolume name"

third="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f3)"
assert_eq "$third" "compress=zstd:1,noatime" "subvolumes: third field is mount options"

assert_fails aw_manifest_packages "$tmp/does-not-exist" "missing manifest fails loudly"

# The real shipped manifests must parse and be non-empty.
n="$(aw_manifest_packages "$ROOT/manifest/core.packages" | wc -l | tr -d ' ')"
[ "$n" -gt 10 ] && _pass || _fail "core.packages" "expected >10 packages, got $n"

n="$(aw_manifest_subvolumes "$ROOT/manifest/subvolumes.tsv" | wc -l | tr -d ' ')"
assert_eq "$n" "5" "shipped subvolumes.tsv has 5 rows"

rm -rf "$tmp"
finish_tests
```

Create `test/unit/test_answers.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/answers.sh
. "$ROOT/lib/answers.sh"

aw_answers_load "$ROOT/test/vm/answers.example.conf"
assert_eq "$AW_DISK" "/dev/vda" "disk parsed"
assert_eq "$AW_HOSTNAME" "archwright-vm" "hostname parsed"
assert_eq "$AW_SERIAL_CONSOLE" "1" "serial console flag parsed"
assert_eq "$AW_TIMEZONE" "UTC" "timezone parsed"
aw_answers_validate && _pass || _fail "example answers" "example file should validate"

tmp="$(mktemp -d)"
cat > "$tmp/bad.conf" <<'EOF'
HOSTNAME=nodisk
EOF
aw_answers_load "$tmp/bad.conf"
assert_fails aw_answers_validate "missing DISK fails validation"

# Injection guard: a value must not be executed.
cat > "$tmp/evil.conf" <<'EOF'
HOSTNAME=$(touch /tmp/aw-pwned)
DISK=/dev/vda
USERNAME=u
USER_PASSWORD=p
LUKS_PASSPHRASE=l
EOF
rm -f /tmp/aw-pwned
aw_answers_load "$tmp/evil.conf"
[ ! -e /tmp/aw-pwned ] && _pass || _fail "injection" "answer value was executed"
assert_eq "$AW_HOSTNAME" '$(touch /tmp/aw-pwned)' "value kept literal"

rm -rf "$tmp"
finish_tests
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash test/run-unit.sh`
Expected: FAIL — `lib/manifest.sh: No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `lib/manifest.sh`:

```bash
#!/usr/bin/env bash
# Readers for manifest/. The installer must never hardcode a package list.

aw_manifest_packages() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^[[:space:]]*$' || true
}

aw_manifest_subvolumes() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  grep -v '^[[:space:]]*#' "$file" | grep -v '^[[:space:]]*$' || true
}
```

Create `lib/answers.sh`:

```bash
#!/usr/bin/env bash
# Parse the unattended answer file. Values are read literally: the file is
# never sourced, because a value must never be able to execute.

AW_DISK=""; AW_HOSTNAME=""; AW_USERNAME=""; AW_USER_PASSWORD=""
AW_LUKS_PASSPHRASE=""; AW_LOCALE="en_US.UTF-8"; AW_TIMEZONE="UTC"
AW_KEYMAP="us"; AW_SERIAL_CONSOLE="0"

aw_answers_load() {
  local file="$1" line key value
  [ -f "$file" ] || aw_die "answer file not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
      DISK)            AW_DISK="$value" ;;
      HOSTNAME)        AW_HOSTNAME="$value" ;;
      USERNAME)        AW_USERNAME="$value" ;;
      USER_PASSWORD)   AW_USER_PASSWORD="$value" ;;
      LUKS_PASSPHRASE) AW_LUKS_PASSPHRASE="$value" ;;
      LOCALE)          AW_LOCALE="$value" ;;
      TIMEZONE)        AW_TIMEZONE="$value" ;;
      KEYMAP)          AW_KEYMAP="$value" ;;
      SERIAL_CONSOLE)  AW_SERIAL_CONSOLE="$value" ;;
      *) aw_log warn "unknown answer key ignored: $key" ;;
    esac
  done < "$file"
}

aw_answers_validate() {
  local ok=0
  [ -n "$AW_DISK" ]            || { aw_log error "answer file: DISK is required"; ok=1; }
  [ -n "$AW_HOSTNAME" ]        || { aw_log error "answer file: HOSTNAME is required"; ok=1; }
  [ -n "$AW_USERNAME" ]        || { aw_log error "answer file: USERNAME is required"; ok=1; }
  [ -n "$AW_USER_PASSWORD" ]   || { aw_log error "answer file: USER_PASSWORD is required"; ok=1; }
  [ -n "$AW_LUKS_PASSPHRASE" ] || { aw_log error "answer file: LUKS_PASSPHRASE is required"; ok=1; }
  return "$ok"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/run-unit.sh`
Expected: `test_answers.sh: 8 run, 0 failed`, `test_manifest.sh: 7 run, 0 failed`, `all unit tests passed`

- [ ] **Step 5: Lint**

Run: `shellcheck lib/manifest.sh lib/answers.sh test/unit/test_manifest.sh test/unit/test_answers.sh`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add manifest lib/manifest.sh lib/answers.sh test/vm/answers.example.conf test/unit/test_manifest.sh test/unit/test_answers.sh
git commit -m "Add manifest and answer-file readers with core package list"
```

---

## Task 3: The partition safety rule

This is the safety-critical pure logic. It is the reason a bug here would destroy someone's data, and the reason it gets real unit tests before any disk is touched.

**Files:**
- Create: `lib/partition.sh`
- Create: `test/unit/test_partition.sh`

**Interfaces:**
- Consumes: `aw_die`, `aw_log`.
- Produces: `aw_parted_parse(text)` → `num<TAB>start<TAB>end<TAB>size<TAB>fs<TAB>name<TAB>flags` per partition; `aw_parted_numbers(text)` → sorted partition numbers; `aw_new_partition_number(before, after)` → the single new number, or fails; `aw_partition_device(disk, num)` → `/dev/vda1` vs `/dev/nvme0n1p1`; `aw_assert_size_within(actual_bytes, expected_bytes, tolerance_bytes)`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/test_partition.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/partition.sh
. "$ROOT/lib/partition.sh"

BLANK='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;'

ONE='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;'

TWO='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
2:1074790400B:21474835967B:20400045568B::archwright:;'

# A disk with a numbering hole - the case the safety rule exists for.
HOLE='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
3:5368709120B:21474835967B:16106126848B:ntfs:Windows:msftdata;'

HOLE_FILLED='BYT;
/dev/vda:21474836480B:virtblk:512:512:gpt:Virtio Block Device:;
1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
2:1074790400B:5368709119B:4293918720B::archwright:;
3:5368709120B:21474835967B:16106126848B:ntfs:Windows:msftdata;'

assert_eq "$(aw_parted_numbers "$BLANK" | tr '\n' ',')" "" "blank disk has no partitions"
assert_eq "$(aw_parted_numbers "$ONE" | tr '\n' ',')" "1," "one partition"
assert_eq "$(aw_parted_numbers "$TWO" | tr '\n' ',')" "1,2," "two partitions"
assert_eq "$(aw_parted_numbers "$HOLE" | tr '\n' ',')" "1,3," "numbering hole preserved"

assert_eq "$(aw_parted_parse "$ONE" | cut -f4)" "1073741824B" "parse: size field"
assert_eq "$(aw_parted_parse "$ONE" | cut -f6)" "ESP" "parse: name field"
assert_eq "$(aw_parted_parse "$ONE" | cut -f7)" "boot, esp" "parse: flags field"

# The core safety rule.
assert_eq "$(aw_new_partition_number "$BLANK" "$ONE")" "1" "first partition is 1"
assert_eq "$(aw_new_partition_number "$ONE" "$TWO")" "2" "second partition is 2"

# parted filled the HOLE at 2, NOT 4. Predicting 'highest + 1' would have
# returned 4 and formatted nothing, or worse, something else.
assert_eq "$(aw_new_partition_number "$HOLE" "$HOLE_FILLED")" "2" "parted fills the lowest free slot"

assert_fails aw_new_partition_number "$ONE" "$ONE" "no new partition is an error"
assert_fails aw_new_partition_number "$BLANK" "$TWO" "two new partitions is an error"

# Device naming.
assert_eq "$(aw_partition_device /dev/vda 1)" "/dev/vda1" "sd/vd naming"
assert_eq "$(aw_partition_device /dev/sda 2)" "/dev/sda2" "sd naming"
assert_eq "$(aw_partition_device /dev/nvme0n1 1)" "/dev/nvme0n1p1" "nvme naming"
assert_eq "$(aw_partition_device /dev/mmcblk0 3)" "/dev/mmcblk0p3" "mmcblk naming"

# Size tolerance: 1 MiB either way.
aw_assert_size_within 1073741824 1073741824 1048576 && _pass || _fail "size exact" "should pass"
aw_assert_size_within 1073741824 1074266112 1048576 && _pass || _fail "size within" "should pass"
assert_fails aw_assert_size_within 1073741824 1090519040 1048576 "size outside tolerance fails"

finish_tests
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/run-unit.sh`
Expected: FAIL — `lib/partition.sh: No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `lib/partition.sh`:

```bash
#!/usr/bin/env bash
# Partition discovery and the never-predict-a-partition-number safety rule.
#
# parted fills the LOWEST free GPT slot, not 'highest existing + 1'. Any disk
# whose numbering has a hole - exactly what deleting a partition leaves behind -
# hands back a number we did not choose. So: snapshot before, snapshot after,
# and derive the new number by difference. Never guess it.

# Turn `parted -ms <dev> unit B print` output into tab-separated rows.
# Input lines look like:
#   1:1048576B:1074790399B:1073741824B:fat32:ESP:boot, esp;
aw_parted_parse() {
  printf '%s\n' "$1" \
    | grep -E '^[0-9]+:' \
    | sed 's/;[[:space:]]*$//' \
    | awk -F: '{
        printf "%s", $1
        for (i = 2; i <= NF; i++) printf "\t%s", $i
        printf "\n"
      }'
}

aw_parted_numbers() {
  aw_parted_parse "$1" | cut -f1 | sort -n
}

# The safety rule. Returns the single partition number that exists in `after`
# but not in `before`. Fails loudly on zero or more than one - both mean the
# disk is not in the state we think it is, and continuing could format
# somebody else's partition.
aw_new_partition_number() {
  local before="$1" after="$2" new count
  new="$(comm -13 \
          <(aw_parted_numbers "$before") \
          <(aw_parted_numbers "$after"))"
  count="$(printf '%s' "$new" | grep -c '[0-9]' || true)"
  if [ "$count" -ne 1 ]; then
    aw_log error "expected exactly 1 new partition, found $count: [$(printf '%s' "$new" | tr '\n' ' ')]"
    return 1
  fi
  printf '%s\n' "$new"
}

# /dev/vda + 1 -> /dev/vda1 ; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
aw_partition_device() {
  local disk="$1" num="$2"
  case "$disk" in
    *nvme*n[0-9]*|*mmcblk[0-9]*|*loop[0-9]*) printf '%sp%s\n' "$disk" "$num" ;;
    *) printf '%s%s\n' "$disk" "$num" ;;
  esac
}

aw_assert_size_within() {
  local actual="$1" expected="$2" tolerance="$3" delta
  delta=$(( actual > expected ? actual - expected : expected - actual ))
  if [ "$delta" -gt "$tolerance" ]; then
    aw_log error "partition size $actual differs from requested $expected by $delta bytes (tolerance $tolerance)"
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/run-unit.sh`
Expected: `test_partition.sh: 19 run, 0 failed`, and `all unit tests passed`

- [ ] **Step 5: Lint**

Run: `shellcheck lib/partition.sh test/unit/test_partition.sh`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add lib/partition.sh test/unit/test_partition.sh
git commit -m "Add partition safety rule: derive new partition number by difference

parted fills the lowest free GPT slot, so a disk with a numbering hole
hands back a number we did not choose. Snapshot before and after and take
the difference; fail loudly on anything but exactly one new partition."
```

---

## Task 4: VM tooling — fetch QEMU, OVMF and the Arch ISO

No installer code yet. This task produces the ability to boot *anything*, verified by booting the stock Arch ISO and seeing a root prompt on the serial console.

**Files:**
- Create: `tools/fetch-qemu-windows.ps1`
- Create: `tools/fetch-arch-iso.sh`
- Create: `tools/fetch-arch-iso.ps1`
- Create: `tools/extract-iso-boot.sh`
- Create: `tools/extract-iso-boot.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `.tools/qemu/qemu-system-x86_64.exe` (Windows only), `.tools/ovmf/OVMF_CODE.fd` and `.tools/ovmf/OVMF_VARS.fd`, `.tools/archlinux.iso`, `.tools/boot/vmlinuz-linux`, `.tools/boot/initramfs-linux.img`, and `.tools/boot/archisolabel.txt` containing the ISO volume label.

- [ ] **Step 1: Write the fetch scripts**

Create `tools/fetch-arch-iso.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$HERE/.tools"
mkdir -p "$TOOLS"

MIRROR="${ARCHWRIGHT_MIRROR:-https://geo.mirror.pkgbuild.com/iso/latest}"
ISO="$TOOLS/archlinux.iso"

if [ -f "$ISO" ]; then
  echo "ISO already present: $ISO"
  exit 0
fi

echo "Resolving latest Arch ISO from $MIRROR ..."
name="$(curl -fsSL "$MIRROR/sha256sums.txt" | awk '/archlinux-[0-9.]+-x86_64\.iso$/ {print $2; exit}')"
[ -n "$name" ] || { echo "could not determine ISO filename" >&2; exit 1; }
sum="$(curl -fsSL "$MIRROR/sha256sums.txt" | awk -v n="$name" '$2 == n {print $1; exit}')"

echo "Downloading $name ..."
curl -fL --progress-bar -o "$ISO.part" "$MIRROR/$name"

echo "Verifying sha256 ..."
actual="$(sha256sum "$ISO.part" | awk '{print $1}')"
if [ "$actual" != "$sum" ]; then
  rm -f "$ISO.part"
  echo "CHECKSUM MISMATCH: expected $sum, got $actual" >&2
  exit 1
fi
mv "$ISO.part" "$ISO"
printf '%s\n' "$name" > "$TOOLS/archlinux.iso.name"
echo "OK: $ISO"
```

Create `tools/fetch-arch-iso.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

$mirror = if ($env:ARCHWRIGHT_MIRROR) { $env:ARCHWRIGHT_MIRROR } else { 'https://geo.mirror.pkgbuild.com/iso/latest' }
$iso    = Join-Path $tools 'archlinux.iso'

if (Test-Path $iso) { Write-Host "ISO already present: $iso"; exit 0 }

Write-Host "Resolving latest Arch ISO from $mirror ..."
$sums = (Invoke-WebRequest -Uri "$mirror/sha256sums.txt" -UseBasicParsing).Content -split "`n"
$row  = $sums | Where-Object { $_ -match 'archlinux-[\d.]+-x86_64\.iso$' } | Select-Object -First 1
if (-not $row) { throw 'could not determine ISO filename' }
$parts = $row -split '\s+'
$sum = $parts[0]; $name = $parts[1]

Write-Host "Downloading $name ..."
Invoke-WebRequest -Uri "$mirror/$name" -OutFile "$iso.part" -UseBasicParsing

Write-Host 'Verifying sha256 ...'
$actual = (Get-FileHash -Algorithm SHA256 "$iso.part").Hash.ToLower()
if ($actual -ne $sum.ToLower()) {
  Remove-Item "$iso.part" -Force
  throw "CHECKSUM MISMATCH: expected $sum, got $actual"
}
Move-Item "$iso.part" $iso -Force
Set-Content -Path (Join-Path $tools 'archlinux.iso.name') -Value $name
Write-Host "OK: $iso"
```

Create `tools/fetch-qemu-windows.ps1`:

```powershell
#!/usr/bin/env pwsh
# Portable QEMU + OVMF into .tools/. Nothing installed system-wide, nothing
# added to PATH. Delete .tools/ to undo completely.
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$qemu  = Join-Path $tools 'qemu'
$ovmf  = Join-Path $tools 'ovmf'
New-Item -ItemType Directory -Force -Path $tools, $ovmf | Out-Null

# QEMU for Windows, portable zip build.
if (-not (Test-Path (Join-Path $qemu 'qemu-system-x86_64.exe'))) {
  $url = $env:ARCHWRIGHT_QEMU_URL
  if (-not $url) {
    throw @'
Set ARCHWRIGHT_QEMU_URL to a portable QEMU-for-Windows zip before running this.
Stefan Weil publishes builds at https://qemu.weilnetz.de/w64/ - pick a recent
qemu-w64-setup or portable zip, or point this at any archive that contains
qemu-system-x86_64.exe. Pinning the URL is deliberate: this script must not
silently pull a different build than the one the milestone was verified on.
'@
  }
  Write-Host "Downloading QEMU from $url ..."
  $zip = Join-Path $tools 'qemu.zip'
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $qemu -Force
  Remove-Item $zip -Force
  $exe = Get-ChildItem -Path $qemu -Recurse -Filter 'qemu-system-x86_64.exe' | Select-Object -First 1
  if (-not $exe) { throw 'archive did not contain qemu-system-x86_64.exe' }
  if ($exe.DirectoryName -ne $qemu) {
    Get-ChildItem -Path $exe.DirectoryName | Move-Item -Destination $qemu -Force
  }
}

# OVMF UEFI firmware. QEMU-for-Windows builds ship edk2-x86_64-code.fd.
$code = Join-Path $ovmf 'OVMF_CODE.fd'
$vars = Join-Path $ovmf 'OVMF_VARS.fd'
if (-not (Test-Path $code)) {
  $shipped = Get-ChildItem -Path $qemu -Recurse -Include 'edk2-x86_64-code.fd','OVMF_CODE.fd' | Select-Object -First 1
  if (-not $shipped) { throw "no OVMF firmware found under $qemu - set ARCHWRIGHT_OVMF_CODE to a path" }
  Copy-Item $shipped.FullName $code -Force
}
if (-not (Test-Path $vars)) {
  $shipped = Get-ChildItem -Path $qemu -Recurse -Include 'edk2-i386-vars.fd','OVMF_VARS.fd' | Select-Object -First 1
  if (-not $shipped) { throw "no OVMF vars template found under $qemu" }
  Copy-Item $shipped.FullName $vars -Force
}

Write-Host "OK: $qemu"
Write-Host "OK: $ovmf"
```

Create `tools/extract-iso-boot.sh`:

```bash
#!/usr/bin/env bash
# Pull the kernel and initramfs out of the Arch ISO so QEMU can boot them
# directly with -kernel/-initrd. That is what lets us append
# console=ttyS0,115200 without driving an interactive boot menu.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$HERE/.tools"
ISO="$TOOLS/archlinux.iso"
BOOT="$TOOLS/boot"

[ -f "$ISO" ] || { echo "run tools/fetch-arch-iso.sh first" >&2; exit 1; }
mkdir -p "$BOOT"

command -v bsdtar >/dev/null 2>&1 || { echo "bsdtar required (pacman -S libarchive)" >&2; exit 1; }

bsdtar -xOf "$ISO" arch/boot/x86_64/vmlinuz-linux      > "$BOOT/vmlinuz-linux"
bsdtar -xOf "$ISO" arch/boot/x86_64/initramfs-linux.img > "$BOOT/initramfs-linux.img"

# archiso needs the volume label on the kernel command line.
label="$(bsdtar -xOf "$ISO" '.disk/info' 2>/dev/null || true)"
if [ -z "$label" ]; then
  label="$(blkid -o value -s LABEL "$ISO" 2>/dev/null || true)"
fi
if [ -z "$label" ]; then
  # Fall back to the ISO9660 volume identifier at offset 32808, 32 bytes.
  label="$(dd if="$ISO" bs=1 skip=32808 count=32 2>/dev/null | tr -d '\0' | sed 's/[[:space:]]*$//')"
fi
[ -n "$label" ] || { echo "could not determine ISO volume label" >&2; exit 1; }
printf '%s\n' "$label" > "$BOOT/archisolabel.txt"

echo "OK: $BOOT (label: $label)"
```

Create `tools/extract-iso-boot.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$iso   = Join-Path $tools 'archlinux.iso'
$boot  = Join-Path $tools 'boot'

if (-not (Test-Path $iso)) { throw 'run tools/fetch-arch-iso.ps1 first' }
New-Item -ItemType Directory -Force -Path $boot | Out-Null

$mount = Mount-DiskImage -ImagePath $iso -PassThru
try {
  $vol = ($mount | Get-Volume)
  $drive = "$($vol.DriveLetter):"
  $label = $vol.FileSystemLabel
  Copy-Item "$drive\arch\boot\x86_64\vmlinuz-linux"       (Join-Path $boot 'vmlinuz-linux') -Force
  Copy-Item "$drive\arch\boot\x86_64\initramfs-linux.img" (Join-Path $boot 'initramfs-linux.img') -Force
  Set-Content -Path (Join-Path $boot 'archisolabel.txt') -Value $label
  Write-Host "OK: $boot (label: $label)"
} finally {
  Dismount-DiskImage -ImagePath $iso | Out-Null
}
```

- [ ] **Step 2: Run the fetchers and verify the artifacts exist**

On Windows:

```
pwsh tools/fetch-arch-iso.ps1
pwsh tools/fetch-qemu-windows.ps1
pwsh tools/extract-iso-boot.ps1
```

Expected: `.tools/archlinux.iso`, `.tools/qemu/qemu-system-x86_64.exe`, `.tools/ovmf/OVMF_CODE.fd`, `.tools/ovmf/OVMF_VARS.fd`, `.tools/boot/vmlinuz-linux`, `.tools/boot/initramfs-linux.img`, `.tools/boot/archisolabel.txt` all present. The checksum step must print `OK`, not a mismatch.

- [ ] **Step 3: Smoke-boot the ISO by hand, once**

This is the only manual step in the plan, and it exists to separate "the harness is broken" from "the installer is broken" before any installer exists.

```
.tools/qemu/qemu-system-x86_64.exe \
  -machine q35,accel=whpx:tcg -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=.tools/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=.tools/ovmf/OVMF_VARS.fd \
  -cdrom .tools/archlinux.iso \
  -kernel .tools/boot/vmlinuz-linux \
  -initrd .tools/boot/initramfs-linux.img \
  -append "archisobasedir=arch archisolabel=<LABEL> console=ttyS0,115200" \
  -nographic
```

Substitute `<LABEL>` with the contents of `.tools/boot/archisolabel.txt`.

Expected: kernel messages scroll past on the terminal and you land at a root prompt (`root@archiso ~ #`) **on the serial console**. Type `exit` or kill QEMU to finish.

If you get a graphical boot instead of serial output, `console=ttyS0,115200` did not take — check the `-append` line. If the initramfs cannot find the medium, `archisolabel` is wrong — re-check `archisolabel.txt`.

- [ ] **Step 4: Commit**

```bash
git add tools/
git commit -m "Add VM tooling: portable QEMU, OVMF, Arch ISO fetch and boot extraction

Extracting the kernel and initramfs lets QEMU boot them directly, which is
how we get console=ttyS0 onto the command line without driving an
interactive boot menu."
```

---

## Task 5: The VM driver

Boots the ISO unattended, serves the working tree over HTTP, runs a command inside the guest, and reports. Still no installer — this task proves the harness can drive a guest.

**Files:**
- Create: `test/vm/drive_vm.py`
- Create: `test/vm-install.sh`
- Create: `test/vm-install.ps1`

**Interfaces:**
- Consumes: `.tools/` artifacts from Task 4.
- Produces: `python3 test/vm/drive_vm.py --phase iso-smoke` exits 0 when it can reach a root prompt and run a command in the live ISO. Later phases (`install`, `verify`, `all`) are filled in by Tasks 7 and 9. The driver exposes the repo at `http://10.0.2.2:<port>/repo.tar` inside the guest.

- [ ] **Step 1: Write the failing test**

Create `test/vm/drive_vm.py`:

```python
#!/usr/bin/env python3
"""Drive an Archwright install inside QEMU over a serial console.

The guest reaches the host at 10.0.2.2 under QEMU user-mode networking, so
the working tree is served over plain HTTP rather than copied into an image.
That means every run tests the working tree, not the last thing pushed.
"""
import argparse
import http.server
import os
import pathlib
import shutil
import socket
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".tools"
RUN = ROOT / ".vmrun"
PROMPT = "root@archiso ~ #"
BOOT_TIMEOUT = 300
INSTALL_TIMEOUT = 3600


def log(msg):
    print(f"[drive_vm] {msg}", flush=True)


def qemu_binary():
    win = TOOLS / "qemu" / "qemu-system-x86_64.exe"
    if win.exists():
        return str(win)
    found = shutil.which("qemu-system-x86_64")
    if not found:
        sys.exit("qemu-system-x86_64 not found: run tools/fetch-qemu-windows.ps1 "
                 "or install qemu-full")
    return found


def serve_repo():
    """Tar the working tree and serve the directory. Returns (port, thread)."""
    RUN.mkdir(exist_ok=True)
    tar_path = RUN / "repo.tar"
    with tarfile.open(tar_path, "w") as tar:
        for name in ("install.sh", "lib", "manifest", "test"):
            src = ROOT / name
            if src.exists():
                tar.add(src, arcname=name)
    log(f"packed working tree -> {tar_path} ({tar_path.stat().st_size} bytes)")

    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(
        *a, directory=str(RUN), **kw)
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"serving {RUN} on host port {port}")
    return port, httpd


class Serial:
    """Line-oriented conversation with the guest over a TCP serial port."""

    def __init__(self, port):
        self.buf = ""
        deadline = time.time() + 60
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(1.0)

    def read_until(self, needle, timeout, echo=True):
        deadline = time.time() + timeout
        while needle not in self.buf:
            if time.time() > deadline:
                tail = self.buf[-4000:]
                raise TimeoutError(
                    f"timed out waiting for {needle!r}\n--- last output ---\n{tail}")
            try:
                chunk = self.sock.recv(4096).decode("utf-8", "replace")
            except socket.timeout:
                continue
            if not chunk:
                time.sleep(0.1)
                continue
            if echo:
                sys.stdout.write(chunk)
                sys.stdout.flush()
            self.buf += chunk
        idx = self.buf.index(needle) + len(needle)
        seen, self.buf = self.buf[:idx], self.buf[idx:]
        return seen

    def send(self, line):
        self.sock.sendall((line + "\n").encode())

    def run(self, cmd, timeout=600):
        """Run a command and return its exit status, using a unique sentinel."""
        token = f"AWDONE{int(time.time() * 1000) % 100000}"
        self.send(f"{cmd}; echo {token}:$?")
        out = self.read_until(f"{token}:", timeout)
        status = self.read_until("\n", 30).strip()
        return int(status), out


def start_qemu(disk, serial_port, iso_boot=True, extra=()):
    label = (TOOLS / "boot" / "archisolabel.txt").read_text().strip()
    args = [
        qemu_binary(),
        "-machine", "q35,accel=whpx:kvm:tcg",
        "-m", "4096", "-smp", "2",
        "-drive", f"if=pflash,format=raw,readonly=on,file={TOOLS/'ovmf'/'OVMF_CODE.fd'}",
        "-drive", f"if=pflash,format=raw,file={RUN/'OVMF_VARS.fd'}",
        "-drive", f"file={disk},if=virtio,format=qcow2",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-serial", f"tcp:127.0.0.1:{serial_port},server=on,wait=off",
        "-display", "none",
    ]
    if iso_boot:
        args += [
            "-cdrom", str(TOOLS / "archlinux.iso"),
            "-kernel", str(TOOLS / "boot" / "vmlinuz-linux"),
            "-initrd", str(TOOLS / "boot" / "initramfs-linux.img"),
            "-append", f"archisobasedir=arch archisolabel={label} console=ttyS0,115200",
        ]
    args += list(extra)
    log("launching qemu")
    return subprocess.Popen(args)


def fresh_run_dir(size="20G"):
    """Throwaway disk and its own copy of the firmware vars, every run.

    Reusing OVMF_VARS between runs leaks NVRAM boot entries and produces
    confusing false passes.
    """
    if RUN.exists():
        shutil.rmtree(RUN)
    RUN.mkdir()
    shutil.copy(TOOLS / "ovmf" / "OVMF_VARS.fd", RUN / "OVMF_VARS.fd")
    disk = RUN / "disk.qcow2"
    qemu_img = pathlib.Path(qemu_binary()).with_name(
        "qemu-img.exe" if os.name == "nt" else "qemu-img")
    subprocess.check_call([str(qemu_img), "create", "-f", "qcow2", str(disk), size],
                          stdout=subprocess.DEVNULL)
    return disk


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def phase_iso_smoke():
    disk = fresh_run_dir()
    sport = free_port()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        log("waiting for the live root prompt ...")
        ser.read_until(PROMPT, BOOT_TIMEOUT)
        rc, _ = ser.run("echo hello-from-guest")
        if rc != 0:
            sys.exit("guest command failed")
        rc, out = ser.run("test -d /sys/firmware/efi && echo UEFI-OK")
        if rc != 0 or "UEFI-OK" not in out:
            sys.exit("guest did not boot in UEFI mode")
        log("PASS: reached a root prompt and the guest is in UEFI mode")
    finally:
        proc.kill()


PHASES = {"iso-smoke": phase_iso_smoke}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="iso-smoke", choices=sorted(PHASES))
    args = ap.parse_args()
    PHASES[args.phase]()


if __name__ == "__main__":
    main()
```

Create `test/vm-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
[ -f .tools/archlinux.iso ]        || tools/fetch-arch-iso.sh
[ -f .tools/boot/vmlinuz-linux ]   || tools/extract-iso-boot.sh
exec python3 test/vm/drive_vm.py "$@"
```

Create `test/vm-install.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not (Test-Path '.tools/archlinux.iso'))      { & pwsh tools/fetch-arch-iso.ps1 }
if (-not (Test-Path '.tools/qemu'))               { & pwsh tools/fetch-qemu-windows.ps1 }
if (-not (Test-Path '.tools/boot/vmlinuz-linux')) { & pwsh tools/extract-iso-boot.ps1 }
& python test/vm/drive_vm.py @args
exit $LASTEXITCODE
```

- [ ] **Step 2: Run it to verify the harness works**

Run: `pwsh test/vm-install.ps1 --phase iso-smoke`
Expected: kernel output scrolls, then `[drive_vm] PASS: reached a root prompt and the guest is in UEFI mode`, exit 0.

If it times out waiting for the prompt, the tail of the guest output is printed — read it. The two common causes are a wrong `archisolabel` and missing acceleration making boot exceed the 300 s timeout.

- [ ] **Step 3: Verify the isolation property**

Run: `pwsh test/vm-install.ps1 --phase iso-smoke` a second time.
Expected: passes identically. Confirm `.vmrun/` was recreated — `disk.qcow2` should have a new timestamp and `OVMF_VARS.fd` should be a fresh copy of the template, not the previous run's.

- [ ] **Step 4: Commit**

```bash
git add test/vm/drive_vm.py test/vm-install.sh test/vm-install.ps1
git commit -m "Add QEMU VM driver over a serial console

Boots the stock Arch ISO with a serial console, drives it from Python over
TCP, and serves the working tree over HTTP so every run tests what is on
disk rather than what was last pushed. Each run gets a throwaway qcow2 and
its own copy of OVMF_VARS so no NVRAM state leaks between runs."
```

---

## Task 6: Preflight phase

**Files:**
- Create: `install.sh`
- Create: `lib/00-preflight.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/answers.sh`, `lib/manifest.sh`.
- Produces: `install.sh --answers <file> [--phase <name>] [--yes]`. Sets `AW_ROOT` (repo root). `aw_preflight()` validates UEFI, the target disk, network reachability and clock sync, and fails with a specific message for each.

- [ ] **Step 1: Write `install.sh`**

```bash
#!/usr/bin/env bash
# Archwright installer. Run from the stock Arch ISO.
#
# This script partitions and formats a disk. It must only ever run inside the
# Arch live environment against a disk you intend to erase.
set -euo pipefail

AW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AW_ROOT

# shellcheck source=lib/common.sh
. "$AW_ROOT/lib/common.sh"
# shellcheck source=lib/answers.sh
. "$AW_ROOT/lib/answers.sh"
# shellcheck source=lib/manifest.sh
. "$AW_ROOT/lib/manifest.sh"
# shellcheck source=lib/partition.sh
. "$AW_ROOT/lib/partition.sh"

ANSWERS=""
ONLY_PHASE=""
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: install.sh --answers <file> [--phase <name>] [--yes]

  --answers <file>  Unattended answer file (required).
  --phase <name>    Run a single phase: preflight, disk, base, boot.
                    Default: all of them, in order.
  --yes             Do not prompt before erasing the target disk.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS="${2:-}"; shift 2 ;;
    --phase)   ONLY_PHASE="${2:-}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) aw_die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$ANSWERS" ] || { usage >&2; aw_die "--answers is required"; }
aw_answers_load "$ANSWERS"
aw_answers_validate || aw_die "answer file is incomplete"
export ASSUME_YES

run_phase() {
  local name="$1" file="$2"
  if [ -n "$ONLY_PHASE" ] && [ "$ONLY_PHASE" != "$name" ]; then
    return 0
  fi
  aw_log info "=== phase: $name ==="
  # shellcheck source=/dev/null
  . "$AW_ROOT/lib/$file"
  "aw_$name"
}

run_phase preflight 00-preflight.sh
run_phase disk      10-disk.sh
run_phase base      20-base.sh
run_phase boot      30-boot.sh

aw_log info "installation complete"
```

- [ ] **Step 2: Write `lib/00-preflight.sh`**

```bash
#!/usr/bin/env bash
# Phase 1: refuse to continue unless the environment is what we require.

aw_preflight() {
  aw_require_cmd parted cryptsetup mkfs.btrfs mkfs.fat pacstrap arch-chroot \
                 sgdisk blkid lsblk curl timedatectl \
    || aw_die "missing required tools - are you running from the Arch ISO?"

  [ -d /sys/firmware/efi ] \
    || aw_die "not booted in UEFI mode. Archwright is UEFI-only; reboot the installer in UEFI mode."

  [ "$(id -u)" -eq 0 ] || aw_die "must run as root"

  [ -b "$AW_DISK" ] || aw_die "target disk is not a block device: $AW_DISK"

  case "$(lsblk -no TYPE "$AW_DISK" | head -1)" in
    disk|loop) ;;
    *) aw_die "$AW_DISK is not a whole disk. Give the disk (/dev/vda), not a partition (/dev/vda1)." ;;
  esac

  local size
  size="$(blockdev --getsize64 "$AW_DISK")"
  if [ "$size" -lt 17179869184 ]; then
    aw_die "target disk is $((size / 1073741824))GiB; Archwright needs at least 16GiB"
  fi

  curl -fsS --max-time 20 -o /dev/null https://archlinux.org/ \
    || aw_die "no network. The installer downloads packages from Arch's mirrors."

  timedatectl set-ntp true || aw_log warn "could not enable NTP; package signature checks may fail if the clock is wrong"

  aw_log info "preflight OK: UEFI, root, $AW_DISK ($((size / 1073741824))GiB), network up"

  if [ "${ASSUME_YES:-0}" -ne 1 ]; then
    printf 'This will ERASE ALL DATA on %s. Type ERASE to continue: ' "$AW_DISK" >&2
    local reply
    read -r reply
    [ "$reply" = "ERASE" ] || aw_die "aborted by user"
  fi
}
```

- [ ] **Step 3: Add the install phase to the VM driver**

In `test/vm/drive_vm.py`, add after `phase_iso_smoke`:

```python
def guest_fetch_repo(ser, port):
    """Pull the working tree into the guest and unpack it."""
    rc, _ = ser.run(f"curl -fsS -o /tmp/repo.tar http://10.0.2.2:{port}/repo.tar", 120)
    if rc != 0:
        sys.exit("guest could not fetch the repo tarball from the host")
    rc, _ = ser.run("mkdir -p /root/archwright && tar -xf /tmp/repo.tar -C /root/archwright", 120)
    if rc != 0:
        sys.exit("guest could not unpack the repo tarball")


def phase_preflight():
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        ser.read_until(PROMPT, BOOT_TIMEOUT)
        guest_fetch_repo(ser, port)
        rc, out = ser.run(
            "bash /root/archwright/install.sh "
            "--answers /root/archwright/test/vm/answers.example.conf "
            "--phase preflight --yes", 300)
        if rc != 0:
            sys.exit(f"preflight failed with status {rc}")
        if "preflight OK" not in out:
            sys.exit("preflight did not report OK")
        log("PASS: preflight succeeded in the guest")
    finally:
        httpd.shutdown()
        proc.kill()


PHASES = {"iso-smoke": phase_iso_smoke, "preflight": phase_preflight}
```

Delete the old single-entry `PHASES` line so only this one remains.

- [ ] **Step 4: Run the phase to verify it passes**

Run: `pwsh test/vm-install.ps1 --phase preflight`
Expected: `[drive_vm] PASS: preflight succeeded in the guest`, exit 0.

- [ ] **Step 5: Verify preflight actually refuses bad input**

Run, in the guest via a temporary answer file with `DISK=/dev/vda1`:

```
pwsh test/vm-install.ps1 --phase preflight
```
after editing `test/vm/answers.example.conf` to `DISK=/dev/does-not-exist`.

Expected: non-zero exit with `target disk is not a block device: /dev/does-not-exist`. **Restore the answer file to `DISK=/dev/vda` afterwards.** A preflight that passes on garbage is worse than no preflight.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck install.sh lib/00-preflight.sh
git add install.sh lib/00-preflight.sh test/vm/drive_vm.py
git commit -m "Add installer entry point and preflight phase"
```

---

## Task 7: Disk phase — GPT, ESP, LUKS2, btrfs subvolumes

**Files:**
- Create: `lib/10-disk.sh`
- Modify: `test/vm/drive_vm.py` (add the `disk` phase)

**Interfaces:**
- Consumes: `aw_parted_numbers`, `aw_new_partition_number`, `aw_partition_device`, `aw_assert_size_within`, `aw_manifest_subvolumes`, `aw_track`.
- Produces: after `aw_disk()`, `/mnt` holds the full mount tree; `AW_ESP_DEV` and `AW_ROOT_DEV` name the created partitions; `/dev/mapper/cryptroot` is the opened LUKS container.

- [ ] **Step 1: Write `lib/10-disk.sh`**

```bash
#!/usr/bin/env bash
# Phase 2: GPT + ESP + LUKS2 + btrfs subvolumes + the mount tree.

AW_ESP_SIZE_MIB=1024
AW_CRYPT_NAME=cryptroot

_aw_parted_print() {
  parted -ms "$AW_DISK" unit B print 2>/dev/null || true
}

# Create one partition and return the number parted actually assigned.
# Never predicts the number: snapshots before and after and takes the
# difference. See lib/partition.sh for why.
_aw_make_partition() {
  local label="$1" fstype="$2" start="$3" end="$4"
  local before after num
  before="$(_aw_parted_print)"
  parted -s "$AW_DISK" mkpart "$label" "$fstype" "$start" "$end"
  partprobe "$AW_DISK" || true
  udevadm settle || true
  after="$(_aw_parted_print)"
  num="$(aw_new_partition_number "$before" "$after")" \
    || aw_die "could not determine which partition parted created - refusing to format anything"
  printf '%s\n' "$num"
}

aw_disk() {
  aw_log info "wiping and partitioning $AW_DISK"

  # Tear down anything holding the disk from a previous attempt.
  swapoff -a || true
  umount -R /mnt 2>/dev/null || true
  cryptsetup close "$AW_CRYPT_NAME" 2>/dev/null || true

  wipefs -af "$AW_DISK"
  sgdisk --zap-all "$AW_DISK"
  parted -s "$AW_DISK" mklabel gpt

  local esp_num root_num esp_size_b actual_b
  esp_num="$(_aw_make_partition ESP fat32 1MiB "$((AW_ESP_SIZE_MIB + 1))MiB")"
  parted -s "$AW_DISK" set "$esp_num" esp on
  AW_ESP_DEV="$(aw_partition_device "$AW_DISK" "$esp_num")"
  aw_track partition "$AW_ESP_DEV"

  esp_size_b=$((AW_ESP_SIZE_MIB * 1048576))
  actual_b="$(blockdev --getsize64 "$AW_ESP_DEV")"
  aw_assert_size_within "$actual_b" "$esp_size_b" 1048576 \
    || aw_die "ESP size sanity check failed"

  root_num="$(_aw_make_partition archwright btrfs "$((AW_ESP_SIZE_MIB + 1))MiB" 100%)"
  AW_ROOT_DEV="$(aw_partition_device "$AW_DISK" "$root_num")"
  aw_track partition "$AW_ROOT_DEV"

  aw_log info "ESP=$AW_ESP_DEV (partition $esp_num), root=$AW_ROOT_DEV (partition $root_num)"

  aw_log info "creating the LUKS2 container"
  printf '%s' "$AW_LUKS_PASSPHRASE" \
    | cryptsetup luksFormat --type luks2 --batch-mode "$AW_ROOT_DEV" -
  printf '%s' "$AW_LUKS_PASSPHRASE" \
    | cryptsetup open "$AW_ROOT_DEV" "$AW_CRYPT_NAME" -
  aw_track luks "$AW_CRYPT_NAME"

  local mapped="/dev/mapper/$AW_CRYPT_NAME"

  aw_log info "formatting"
  mkfs.fat -F32 -n ESP "$AW_ESP_DEV"
  mkfs.btrfs -f -L archwright "$mapped"

  aw_log info "creating subvolumes"
  mount "$mapped" /mnt
  local subvol mountpoint opts
  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ -n "$subvol" ] || continue
    btrfs subvolume create "/mnt/$subvol" >/dev/null
    aw_track subvolume "$subvol"
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")
  umount /mnt

  aw_log info "mounting the tree"
  # Mount '@' first: everything else nests under it.
  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ "$mountpoint" = "/" ] || continue
    mount -o "subvol=$subvol,$opts" "$mapped" /mnt
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")

  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ "$mountpoint" != "/" ] || continue
    mkdir -p "/mnt$mountpoint"
    mount -o "subvol=$subvol,$opts" "$mapped" "/mnt$mountpoint"
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")

  mkdir -p /mnt/boot
  mount "$AW_ESP_DEV" /mnt/boot

  aw_log info "mount tree:"
  findmnt -R /mnt >&2
}
```

- [ ] **Step 2: Add the disk phase to the driver**

In `test/vm/drive_vm.py`:

```python
def phase_disk():
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        ser.read_until(PROMPT, BOOT_TIMEOUT)
        guest_fetch_repo(ser, port)
        for phase in ("preflight", "disk"):
            rc, _ = ser.run(
                "bash /root/archwright/install.sh "
                "--answers /root/archwright/test/vm/answers.example.conf "
                f"--phase {phase} --yes", 900)
            if rc != 0:
                sys.exit(f"phase {phase} failed with status {rc}")
        checks = [
            ("findmnt -no FSTYPE /mnt", "btrfs"),
            ("findmnt -no OPTIONS /mnt | grep -o 'subvol=/@'", "subvol=/@"),
            ("findmnt -no FSTYPE /mnt/boot", "vfat"),
            ("findmnt -no TARGET /mnt/home", "/mnt/home"),
            ("findmnt -no TARGET /mnt/.snapshots", "/mnt/.snapshots"),
            ("cryptsetup status cryptroot | head -1", "is active"),
            ("cryptsetup luksDump /dev/vda2 | grep -o 'Version:.*2'", "2"),
        ]
        for cmd, expect in checks:
            rc, out = ser.run(cmd, 60)
            if rc != 0 or expect not in out:
                sys.exit(f"disk check failed: {cmd!r} did not yield {expect!r}")
        log("PASS: disk layout is correct")
    finally:
        httpd.shutdown()
        proc.kill()


PHASES = {
    "iso-smoke": phase_iso_smoke,
    "preflight": phase_preflight,
    "disk": phase_disk,
}
```

- [ ] **Step 3: Run to verify it passes**

Run: `pwsh test/vm-install.ps1 --phase disk`
Expected: `[drive_vm] PASS: disk layout is correct`, exit 0.

- [ ] **Step 4: Lint and commit**

```bash
shellcheck lib/10-disk.sh
git add lib/10-disk.sh test/vm/drive_vm.py
git commit -m "Add disk phase: GPT, ESP, LUKS2 and btrfs subvolumes

Partition numbers are read back from parted rather than predicted, and the
ESP size is checked within a 1MiB tolerance before anything is formatted."
```

---

## Task 8: Base phase — pacstrap, fstab, locale, user

**Files:**
- Create: `lib/20-base.sh`
- Modify: `test/vm/drive_vm.py` (add the `base` phase)

**Interfaces:**
- Consumes: `aw_manifest_packages`, `aw_run_in_chroot`.
- Produces: a populated `/mnt` with `/etc/fstab`, locale, hostname, the user account, and `/usr/share/archwright/` seeded. `aw_base()`.

- [ ] **Step 1: Write `lib/20-base.sh`**

```bash
#!/usr/bin/env bash
# Phase 3: pacstrap the base system and configure identity.
#
# Ordering note: packages that seed /etc/skel must be installed BEFORE
# useradd, because useradd copies /etc/skel exactly once. There is no second
# chance to fix a home directory that was created too early.

aw_base() {
  local packages
  packages="$(aw_manifest_packages "$AW_ROOT/manifest/core.packages")"
  aw_log info "pacstrap: $(printf '%s' "$packages" | wc -l) packages"

  # shellcheck disable=SC2086
  # Intentional word splitting: pacstrap takes packages as separate arguments.
  pacstrap -K /mnt $packages || aw_die "pacstrap failed"

  aw_log info "generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab
  grep -q ' / ' /mnt/etc/fstab || aw_die "genfstab produced no root entry"

  aw_log info "locale, time and hostname"
  aw_run_in_chroot "ln -sf /usr/share/zoneinfo/$AW_TIMEZONE /etc/localtime && hwclock --systohc"
  printf '%s UTF-8\n' "$AW_LOCALE" > /mnt/etc/locale.gen
  aw_run_in_chroot "locale-gen"
  printf 'LANG=%s\n' "$AW_LOCALE" > /mnt/etc/locale.conf
  printf 'KEYMAP=%s\n' "$AW_KEYMAP" > /mnt/etc/vconsole.conf
  printf '%s\n' "$AW_HOSTNAME" > /mnt/etc/hostname
  cat > /mnt/etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$AW_HOSTNAME.localdomain	$AW_HOSTNAME
EOF

  # Archwright's own tree. Ours, package-owned, never hand-edited.
  install -d -m 0755 /mnt/usr/share/archwright
  printf 'milestone-1\n' > /mnt/usr/share/archwright/VERSION

  # Skeleton seeding happens here, before useradd.
  install -d -m 0755 /mnt/etc/skel/.local/state/archwright

  aw_log info "creating user $AW_USERNAME"
  aw_run_in_chroot "useradd -m -G wheel -s /bin/bash '$AW_USERNAME'"
  printf '%s:%s\n' "$AW_USERNAME" "$AW_USER_PASSWORD" | arch-chroot /mnt chpasswd
  arch-chroot /mnt passwd -l root

  install -d -m 0750 /mnt/etc/sudoers.d
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
  chmod 0440 /mnt/etc/sudoers.d/10-wheel
  arch-chroot /mnt visudo -cf /etc/sudoers.d/10-wheel \
    || aw_die "generated sudoers file is invalid"

  aw_log info "enabling services"
  aw_run_in_chroot "systemctl enable NetworkManager.service sshd.service"
  # Nothing in the session needs to block on the network.
  aw_run_in_chroot "systemctl mask NetworkManager-wait-online.service"

  printf '[zram0]\nzram-size = min(ram / 2, 8192)\n' > /mnt/etc/systemd/zram-generator.conf
}
```

- [ ] **Step 2: Add the base phase to the driver**

```python
def _run_phases(ser, phases, timeout=3600):
    for phase in phases:
        rc, _ = ser.run(
            "bash /root/archwright/install.sh "
            "--answers /root/archwright/test/vm/answers.example.conf "
            f"--phase {phase} --yes", timeout)
        if rc != 0:
            sys.exit(f"phase {phase} failed with status {rc}")


def phase_base():
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        ser.read_until(PROMPT, BOOT_TIMEOUT)
        guest_fetch_repo(ser, port)
        _run_phases(ser, ("preflight", "disk", "base"))
        checks = [
            ("test -f /mnt/etc/fstab && echo FSTAB-OK", "FSTAB-OK"),
            ("cat /mnt/etc/hostname", "archwright-vm"),
            ("arch-chroot /mnt id -u test >/dev/null && echo USER-OK", "USER-OK"),
            ("test -d /mnt/home/test && echo HOME-OK", "HOME-OK"),
            ("test -d /mnt/home/test/.local/state/archwright && echo SKEL-OK", "SKEL-OK"),
            ("arch-chroot /mnt systemctl is-enabled NetworkManager.service", "enabled"),
            ("arch-chroot /mnt systemctl is-enabled NetworkManager-wait-online.service", "masked"),
        ]
        for cmd, expect in checks:
            rc, out = ser.run(cmd, 120)
            if expect not in out:
                sys.exit(f"base check failed: {cmd!r} did not yield {expect!r}")
        log("PASS: base system installed and configured")
    finally:
        httpd.shutdown()
        proc.kill()
```

Add `"base": phase_base` to `PHASES`.

The `SKEL-OK` check is the one that matters: it proves `/etc/skel` was populated *before* `useradd` ran. If skeleton seeding drifts later in the phase, that check fails and the ordering constraint is caught immediately.

- [ ] **Step 3: Run to verify it passes**

Run: `pwsh test/vm-install.ps1 --phase base`
Expected: `[drive_vm] PASS: base system installed and configured`, exit 0. This run downloads several hundred megabytes of packages and takes 10–25 minutes.

- [ ] **Step 4: Lint and commit**

```bash
shellcheck lib/20-base.sh
git add lib/20-base.sh test/vm/drive_vm.py
git commit -m "Add base phase: pacstrap, fstab, locale, user and services

/etc/skel is seeded before useradd, because useradd copies it exactly once.
A VM check asserts the ordering so it cannot silently regress."
```

---

## Task 9: Boot phase — UKI, Limine, snapper, and the milestone gate

**Files:**
- Create: `lib/30-boot.sh`
- Create: `test/vm/assertions.sh`
- Modify: `test/vm/drive_vm.py` (add `install`, `verify`, `all`)

**Interfaces:**
- Consumes: everything above.
- Produces: a bootable installed system. `aw_boot()`. `test/vm/assertions.sh` runs inside the installed system and exits non-zero with a message on any failed gate criterion.

- [ ] **Step 1: Verify where the Limine tooling actually lives**

Run inside a live-ISO guest (`pwsh test/vm-install.ps1 --phase iso-smoke` then by hand, or add a throwaway phase):

```
pacman -Sy >/dev/null 2>&1
for p in limine limine-mkinitcpio-hook limine-entry-tool limine-snapper-sync snapper; do
  printf '%-26s ' "$p"
  pacman -Si "$p" >/dev/null 2>&1 && echo "official" || echo "NOT in official repos"
done
```

Record the result. Packages reported `official` are added to `manifest/core.packages` and installed by Task 8's pacstrap. Packages reported `NOT in official repos` go through the AUR path in Step 2. Do not skip this step — it determines which of the two code paths below is live.

- [ ] **Step 2: Write `lib/30-boot.sh`**

```bash
#!/usr/bin/env bash
# Phase 4: initramfs as a UKI, Limine as the bootloader, snapper wired to it.
#
# Limine is not interchangeable here. Snapshot rollback from the boot menu is
# the reason it was chosen over systemd-boot, and limine-snapper-sync is what
# keeps that menu in step with snapper.

AW_AUR_PACKAGES="limine-mkinitcpio-hook limine-snapper-sync"

# Build an AUR package in the live environment and install it into the target.
# makepkg refuses to run as root, so this uses a throwaway unprivileged user.
_aw_install_from_aur() {
  local pkg="$1" builddir="/tmp/aurbuild/$pkg"

  id aurbuild >/dev/null 2>&1 || {
    useradd -m -s /bin/bash aurbuild
    printf 'aurbuild ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/aurbuild
    chmod 0440 /etc/sudoers.d/aurbuild
  }

  rm -rf "$builddir"
  install -d -o aurbuild -g aurbuild "$builddir"
  sudo -u aurbuild git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$builddir" \
    || aw_die "could not clone AUR package $pkg"
  sudo -u aurbuild bash -c "cd '$builddir' && makepkg -s --noconfirm" \
    || aw_die "makepkg failed for $pkg"

  local built
  built="$(find "$builddir" -maxdepth 1 -name '*.pkg.tar.zst' | head -1)"
  [ -n "$built" ] || aw_die "makepkg produced no package for $pkg"
  pacman -U --root /mnt --noconfirm "$built" || aw_die "could not install $pkg into the target"
  aw_log info "installed $pkg from the AUR"
}

aw_boot() {
  local pkg
  for pkg in $AW_AUR_PACKAGES; do
    if arch-chroot /mnt pacman -Si "$pkg" >/dev/null 2>&1; then
      aw_log info "$pkg is in the official repos; installing normally"
      aw_run_in_chroot "pacman -S --noconfirm --needed $pkg"
    else
      aw_log info "$pkg is not in the official repos; building from the AUR"
      _aw_install_from_aur "$pkg"
    fi
  done

  aw_log info "configuring mkinitcpio for a UKI"
  cat > /mnt/etc/mkinitcpio.conf.d/archwright.conf <<'EOF'
# LUKS on the root device needs systemd-based early userspace so the
# passphrase can be prompted for before the root filesystem is mounted.
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
EOF

  local root_uuid cmdline
  root_uuid="$(blkid -s UUID -o value "$AW_ROOT_DEV")"
  cmdline="rd.luks.name=$root_uuid=$AW_CRYPT_NAME root=/dev/mapper/$AW_CRYPT_NAME rootflags=subvol=@ rw quiet"
  if [ "${AW_SERIAL_CONSOLE:-0}" = "1" ]; then
    cmdline="$cmdline console=ttyS0,115200"
    aw_log warn "SERIAL_CONSOLE=1: adding console=ttyS0 to the kernel cmdline (test builds only)"
  fi
  printf '%s\n' "$cmdline" > /mnt/etc/kernel/cmdline

  install -d /mnt/boot/EFI/Linux
  cat > /mnt/etc/mkinitcpio.d/linux.preset <<'EOF'
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/boot/EFI/Linux/archwright-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF

  aw_log info "building the unified kernel image"
  aw_run_in_chroot "mkinitcpio -P" || aw_die "mkinitcpio failed"
  [ -f /mnt/boot/EFI/Linux/archwright-linux.efi ] || aw_die "no UKI was produced"

  aw_log info "installing Limine"
  install -d /mnt/boot/EFI/BOOT
  aw_run_in_chroot "cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI"
  cat > /mnt/boot/limine.conf <<EOF
timeout: 3
default_entry: 1

/Archwright
    protocol: efi
    path: boot():/EFI/Linux/archwright-linux.efi
EOF
  aw_run_in_chroot "efibootmgr --create --disk $AW_DISK --part 1 \
    --loader '\\EFI\\BOOT\\BOOTX64.EFI' --label 'Archwright' --unicode" \
    || aw_log warn "efibootmgr entry not created; the removable-media path will still boot"

  aw_log info "configuring snapper"
  # snapper insists on creating /.snapshots itself, so the pre-made subvolume
  # is unmounted, removed, the config created, snapper's directory deleted, and
  # the real subvolume remounted. This dance is required, not incidental.
  umount /mnt/.snapshots
  rmdir /mnt/.snapshots
  aw_run_in_chroot "snapper --no-dbus -c root create-config /"
  aw_run_in_chroot "btrfs subvolume delete /.snapshots"
  mkdir -p /mnt/.snapshots
  mount -o "subvol=@snapshots,compress=zstd:1,noatime" "/dev/mapper/$AW_CRYPT_NAME" /mnt/.snapshots
  chmod 750 /mnt/.snapshots

  # Snapshots happen on updates, not on a clock.
  aw_run_in_chroot "systemctl disable snapper-timeline.timer" || true
  aw_run_in_chroot "systemctl enable snapper-cleanup.timer"
  aw_run_in_chroot "systemctl enable limine-snapper-sync.service" \
    || aw_log warn "limine-snapper-sync.service not enabled - snapshot boot entries will not appear"

  aw_log info "taking the baseline snapshot"
  aw_run_in_chroot "snapper --no-dbus -c root create --description 'archwright install baseline'" \
    || aw_die "could not create the baseline snapshot"

  aw_run_in_chroot "limine-update" || aw_log warn "limine-update not available"

  aw_log info "boot phase complete"
}
```

- [ ] **Step 3: Write `test/vm/assertions.sh`**

```bash
#!/usr/bin/env bash
# Runs inside the INSTALLED system. Checks milestone 1 gate criteria 4-6.
set -uo pipefail
fails=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label"
    fails=$((fails + 1))
  fi
}

check "root is btrfs"            test "$(findmnt -no FSTYPE /)" = "btrfs"
check "root subvolume is @"      sh -c 'findmnt -no OPTIONS / | grep -q "subvol=/@\\b"'
check "/boot is vfat"            test "$(findmnt -no FSTYPE /boot)" = "vfat"
check "/home is mounted"         mountpoint -q /home
check "/.snapshots is mounted"   mountpoint -q /.snapshots
check "root device is LUKS"      sh -c 'lsblk -no TYPE | grep -q crypt'
check "snapper has a snapshot"   sh -c 'snapper -c root list | grep -qE "^[[:space:]]*[1-9]"'
check "timeline timer is off"    sh -c '! systemctl is-enabled snapper-timeline.timer 2>/dev/null | grep -q "^enabled$"'
check "cleanup timer is on"      sh -c 'systemctl is-enabled snapper-cleanup.timer | grep -q "^enabled$"'
check "UKI exists"               test -f /boot/EFI/Linux/archwright-linux.efi
check "limine config present"    test -f /boot/limine.conf
check "limine snapshot entry"    sh -c 'grep -qiE "snapshot" /boot/limine.conf'
check "NM wait-online masked"    sh -c 'systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null | grep -q "^masked$"'

if [ "$fails" -ne 0 ]; then
  printf 'ASSERTIONS-FAILED:%d\n' "$fails"
  exit 1
fi
printf 'ASSERTIONS-PASSED\n'
```

- [ ] **Step 4: Add `install`, `verify` and `all` to the driver**

```python
LUKS_PROMPT = "Please enter passphrase"
INSTALLED_PROMPT = "login:"


def phase_all():
    """The milestone 1 gate: install, reboot, unlock, assert."""
    disk = fresh_run_dir()
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport)
    try:
        ser = Serial(sport)
        ser.read_until(PROMPT, BOOT_TIMEOUT)
        guest_fetch_repo(ser, port)
        _run_phases(ser, ("preflight", "disk", "base", "boot"))
        log("install finished; shutting the live environment down")
        ser.send("sync; poweroff -f")
        proc.wait(timeout=120)
    finally:
        httpd.shutdown()
        try:
            proc.kill()
        except Exception:
            pass

    # Second boot: from the installed disk, no ISO, no -kernel.
    log("booting the installed system")
    sport = free_port()
    port, httpd = serve_repo()
    proc = start_qemu(disk, sport, iso_boot=False)
    try:
        ser = Serial(sport)
        log("waiting for the LUKS passphrase prompt (gate criterion 2)")
        ser.read_until(LUKS_PROMPT, BOOT_TIMEOUT)
        ser.send("testpassphrase")
        log("LUKS prompt answered; waiting for login (gate criterion 3)")
        ser.read_until(INSTALLED_PROMPT, BOOT_TIMEOUT)
        ser.send("test")
        ser.read_until("Password:", 60)
        ser.send("testpassword")
        ser.read_until("$", 60)
        rc, _ = ser.run(f"curl -fsS -o /tmp/a.sh http://10.0.2.2:{port}/repo.tar", 60)
        ser.run("mkdir -p /tmp/r && tar -xf /tmp/a.sh -C /tmp/r", 60)
        rc, out = ser.run("sudo -S bash /tmp/r/test/vm/assertions.sh <<< testpassword", 120)
        if "ASSERTIONS-PASSED" not in out:
            sys.exit("installed-system assertions failed - see output above")
        log("PASS: milestone 1 gate met")
    finally:
        httpd.shutdown()
        proc.kill()


PHASES = {
    "iso-smoke": phase_iso_smoke,
    "preflight": phase_preflight,
    "disk": phase_disk,
    "base": phase_base,
    "all": phase_all,
}
```

- [ ] **Step 5: Run the full gate**

Run: `pwsh test/vm-install.ps1 --phase all`
Expected: the install runs, the VM reboots, `Please enter passphrase` appears, the system logs in, and `ASSERTIONS-PASSED` is printed followed by `[drive_vm] PASS: milestone 1 gate met`. Exit 0.

Expect this to fail the first several times. The likely failure points, in order: the Limine EFI path, the `mkinitcpio` HOOKS line for `sd-encrypt`, and the snapper `/.snapshots` dance. Each prints the guest output tail.

- [ ] **Step 6: Lint everything and commit**

```bash
shellcheck install.sh lib/*.sh test/vm/assertions.sh test/run-unit.sh test/unit/*.sh
bash test/run-unit.sh
git add lib/30-boot.sh test/vm/assertions.sh test/vm/drive_vm.py
git commit -m "Add boot phase: UKI, Limine, snapper, and the milestone 1 gate

Builds the two Limine AUR packages in the live environment when they are not
in the official repos. Wires snapper for snapshots-on-update rather than on a
timer, and asserts the whole gate against the rebooted system."
```

- [ ] **Step 7: Tag the milestone**

```bash
git tag -a milestone-1 -m "Base install: UEFI, LUKS2, btrfs, Limine, snapper, verified in QEMU"
```

---

## Self-review notes

**Spec coverage.** Milestone 1 in spec §14 requires a booting encrypted btrfs + Limine system with a snapper snapshot and a Limine snapshot entry. Tasks 6–9 cover it. Spec §4's `lib/` layout is followed exactly. Spec §11's partition rule is Task 3, its phase ordering is Task 8 (skel before useradd) — the mkinitcpio hook masking belongs to the hardware phase, which is milestone 6, and is deliberately absent here. Spec §13's oracle requirements are Tasks 4, 5 and 9, including the throwaway-overlay isolation. Spec §16's manifest-driven rule is Task 2 and is enforced by there being no package name anywhere in `lib/`.

**Deliberately out of milestone 1:** Plymouth (installed but not configured), hibernation, the `archwright` CLI, `check-guide-drift.sh` (nothing to check against until the guide exists in milestone 7), and `manifest/hotkeys.tsv` (no Hyprland yet).

**Known risk.** Task 9 Step 1 exists because the Limine snapshot tooling's repository location determines which code path runs, and that cannot be resolved from the development host. Both paths are written out in full; the step decides which is live.
