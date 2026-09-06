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
  printf '[%s] %-5s %s\n' \
    "$(date +%H:%M:%S)" \
    "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" \
    "$*" >&2
}

aw_die() {
  aw_log error "$*"
  exit 1
}

aw_require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      aw_log error "required command not found: $c"
      missing=1
    }
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

# Cross-phase state.
#
# Each `install.sh --phase X` is its own process, so a variable set in the
# disk phase is gone by the boot phase. Facts that later phases need are
# written here instead. /run is tmpfs, which is the right lifetime: it lives
# for this boot of the live environment and vanishes afterwards.
aw_state_set() {
  local key="$1" value="$2"
  mkdir -p "$AW_TRACK_DIR/state"
  printf '%s' "$value" > "$AW_TRACK_DIR/state/$key"
}

aw_state_get() {
  local key="$1"
  [ -f "$AW_TRACK_DIR/state/$key" ] || return 1
  cat "$AW_TRACK_DIR/state/$key"
}

# Secure Boot state, read straight from the EFI variable.
#
#   0 = enabled    1 = disabled    2 = cannot tell
#
# This matters because Archwright's bootloader is unsigned: with Secure Boot on,
# the machine installs fine and then refuses to boot, which is a miserable way
# to find out. It is the single most likely real-hardware blocker, and it is
# invisible in QEMU because OVMF ships with Secure Boot off.
#
# The efivars file carries a 4-byte attribute header before the value, hence
# the offset. The path is a parameter so this is testable against a fixture
# rather than only against the machine it happens to run on.
aw_secureboot_state() {
  local dir="${1:-/sys/firmware/efi/efivars}" f val
  [ -d "$dir" ] || return 2
  f="$(find "$dir" -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -1)"
  [ -n "$f" ] || return 2
  val="$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -d '[:space:]')"
  case "$val" in
    1) return 0 ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

# The partition number of a device node, read from sysfs rather than parsed
# out of the name - naming differs between sd*, nvme*p* and mmcblk*p*.
aw_partition_number_of() {
  local dev="$1" name
  name="${dev##*/}"
  [ -f "/sys/class/block/$name/partition" ] || return 1
  cat "/sys/class/block/$name/partition"
}

aw_run_in_chroot() {
  arch-chroot /mnt /usr/bin/env bash -euo pipefail -c "$*"
}
