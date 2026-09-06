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

aw_run_in_chroot() {
  arch-chroot /mnt /usr/bin/env bash -euo pipefail -c "$*"
}
