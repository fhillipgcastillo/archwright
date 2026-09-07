#!/usr/bin/env bash
# Boot the system the last VM run installed, in a window you can actually use.
#
# The automated harness runs headless and talks over a serial socket. This is
# the human version: a graphical window showing the Hyprland session, with the
# serial console on your terminal so you can type the LUKS passphrase.
#
# By default the disk is opened READ-ONLY via QEMU's -snapshot: everything you
# do is discarded on exit, so you can break things freely. Pass --write to keep
# your changes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
# shellcheck source=tools/env.sh
. "$HERE/tools/env.sh"

PERSIST=0
DISPLAY_MODE="gtk"

usage() {
  cat <<'EOF'
Usage: tools/boot-installed.sh [--write] [--serial-only]

  --write        Keep changes made in this session. Default is throwaway:
                 the disk is untouched and everything is discarded on exit.
  --serial-only  No graphical window; serial console only. Useful over SSH,
                 or when there is no display available.

Log in with the credentials from the answer file the install used
(test/vm/answers.example.conf by default: user "test", password
"testpassword", LUKS passphrase "testpassphrase").

Close the window or press Ctrl-A then X in the terminal to quit.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --write)       PERSIST=1; shift ;;
    --serial-only) DISPLAY_MODE="none"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

disk="$AW_VMRUN/disk.qcow2"
vars="$AW_VMRUN/OVMF_VARS.fd"

if [ ! -f "$disk" ]; then
  echo "No installed disk at $disk" >&2
  echo "Run an install first:  bash test/vm-install.sh --phase all" >&2
  exit 1
fi
[ -f "$vars" ] || { echo "missing firmware vars at $vars" >&2; exit 1; }

qemu="$(aw_env_qemu)" || exit 1
code="$(aw_env_ovmf_code)" || exit 1

args=(
  "$qemu"
  -machine "q35,accel=$(aw_env_accel)"
  -cpu "$([ "$(aw_env_accel)" = kvm ] && echo host || echo qemu64)"
  -m 4096 -smp 2
  -drive "if=pflash,format=raw,readonly=on,file=$code"
  -drive "if=pflash,format=raw,file=$vars"
  -drive "file=$disk,if=virtio,format=qcow2"
  -netdev "user,id=n0" -device "virtio-net-pci,netdev=n0"
  # Same graphics as the harness, so what you see is what the tests exercise.
  # virtio-vga is VGA-compatible (firmware and Limine paint on it) and
  # virtio-gpu underneath (Linux gets a render node for Hyprland).
  -device virtio-vga
  -display "$DISPLAY_MODE"
  # The installed test image puts the kernel console on ttyS0, so the LUKS
  # passphrase prompt arrives here rather than in the window.
  -serial mon:stdio
)

if [ "$PERSIST" -eq 0 ]; then
  args+=(-snapshot)
  echo "Throwaway mode: changes are discarded on exit. Pass --write to keep them."
else
  echo "WRITE MODE: changes are written to $disk"
fi

if [ "$DISPLAY_MODE" = "gtk" ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  echo "No DISPLAY or WAYLAND_DISPLAY set - a window cannot open." >&2
  echo "Use --serial-only instead." >&2
  exit 1
fi

echo "Unlock with the LUKS passphrase here in the terminal; the desktop"
echo "appears in the window. Quit with Ctrl-A then X."
exec "${args[@]}"
