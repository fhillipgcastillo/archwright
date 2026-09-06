#!/usr/bin/env bash
# Entry point for the VM oracle. Populates the cache if empty, then hands off
# to the Python driver.
#
# Must run inside Linux (WSL2 on this machine) - see D13 in docs/decisions.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
# shellcheck source=tools/env.sh
. "$HERE/tools/env.sh"

[ -f "$AW_ISO" ]                  || bash tools/fetch-arch-iso.sh
[ -f "$AW_BOOT/vmlinuz-linux" ]   || bash tools/extract-iso-boot.sh

exec python3 test/vm/drive_vm.py "$@"
