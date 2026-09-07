#!/usr/bin/env bash
# Archwright installer. Run from the stock Arch ISO.
#
# WARNING: this script partitions and formats a disk. It must only ever run
# inside the Arch live environment, against a disk you intend to erase. Never
# run it, or anything in lib/, on a development machine.
set -euo pipefail

AW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AW_ROOT

# parted, sort and comm are all locale-sensitive, and lib/partition.sh depends
# on their output being stable. Pin the locale for the whole run.
export LC_ALL=C

# shellcheck source=lib/common.sh
. "$AW_ROOT/lib/common.sh"
# shellcheck source=lib/answers.sh
. "$AW_ROOT/lib/answers.sh"
# shellcheck source=lib/manifest.sh
. "$AW_ROOT/lib/manifest.sh"
# shellcheck source=lib/partition.sh
. "$AW_ROOT/lib/partition.sh"
# shellcheck source=lib/config.sh
. "$AW_ROOT/lib/config.sh"
# shellcheck source=lib/resume.sh
. "$AW_ROOT/lib/resume.sh"

ANSWERS=""
ONLY_PHASE=""
ASSUME_YES=0
HOST_PKG_CACHE=0
RESUME=0

usage() {
  cat <<'EOF'
Usage: install.sh --answers <file> [--phase <name>] [--yes]

  --answers <file>  Unattended answer file (required).
  --phase <name>    Run a single phase: preflight, disk, base, boot, session,
                    shell.
                    Default: all of them, in order.
  --yes             Do not prompt before erasing the target disk.
  --resume          Continue an install that was interrupted. Reopens the
                    existing LUKS container, remounts the tree, and skips the
                    phases that already finished. Refuses unless the disk is
                    positively identified as an Archwright install in progress,
                    so it can never wipe or adopt somebody else's disk.
  --host-pkg-cache  Install packages from the LIVE ENVIRONMENT's pacman cache
                    instead of the target's. Only pass this when that cache is
                    backed by real storage - on a stock Arch ISO it is a tmpfs
                    in RAM, and several hundred megabytes of packages will
                    exhaust it.

This script ERASES the target disk. Read docs/ before running it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS="${2:-}"; shift 2 ;;
    --phase)   ONLY_PHASE="${2:-}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    --host-pkg-cache) HOST_PKG_CACHE=1; shift ;;
    --resume)  RESUME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; aw_die "unknown argument: $1" ;;
  esac
done

[ -n "$ANSWERS" ] || { usage >&2; aw_die "--answers is required"; }

case "$ONLY_PHASE" in
  ''|preflight|disk|base|boot|session|shell) ;;
  *) aw_die "unknown phase: $ONLY_PHASE (expected preflight, disk, base, boot, session or shell)" ;;
esac

aw_answers_load "$ANSWERS"
aw_answers_validate || aw_die "answer file is invalid; fix the errors above"
export ASSUME_YES
export HOST_PKG_CACHE

run_phase() {
  local name="$1" file="$2"
  if [ -n "$ONLY_PHASE" ] && [ "$ONLY_PHASE" != "$name" ]; then
    return 0
  fi
  # On a resumed install, skip whatever the previous attempt finished. This is
  # the entire point of --resume: not re-downloading 500MB because the wifi
  # dropped at minute 35.
  if [ "$RESUME" -eq 1 ] && aw_phase_is_done "$name"; then
    aw_log info "=== phase: $name (already done, skipping) ==="
    return 0
  fi
  aw_log info "=== phase: $name ==="
  # shellcheck source=/dev/null
  . "$AW_ROOT/lib/$file"
  "aw_$name"
  aw_phase_record "$name"
}

if [ "$RESUME" -eq 1 ]; then
  aw_log info "resuming a previous install"
  aw_resume_prepare
fi

run_phase preflight 00-preflight.sh
run_phase disk      10-disk.sh
run_phase base      20-base.sh
run_phase boot      30-boot.sh
run_phase session   40-session.sh
run_phase shell     50-shell.sh

aw_log info "installation complete"
