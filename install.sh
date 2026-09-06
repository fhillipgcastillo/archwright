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

This script ERASES the target disk. Read docs/ before running it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS="${2:-}"; shift 2 ;;
    --phase)   ONLY_PHASE="${2:-}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; aw_die "unknown argument: $1" ;;
  esac
done

[ -n "$ANSWERS" ] || { usage >&2; aw_die "--answers is required"; }

case "$ONLY_PHASE" in
  ''|preflight|disk|base|boot) ;;
  *) aw_die "unknown phase: $ONLY_PHASE (expected preflight, disk, base or boot)" ;;
esac

aw_answers_load "$ANSWERS"
aw_answers_validate || aw_die "answer file is invalid; fix the errors above"
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
