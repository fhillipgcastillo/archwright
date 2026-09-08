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
#
# KNOWN LIMITATION ON WINDOWS + WSL: the Super key does not reach the guest.
#
# Windows and WSLg both claim Super for themselves, so `Super + Return` opens
# nothing and `Super + Q` fires a Windows shortcut instead. The binding is
# fine - `hyprctl binds` shows `modmask: 64` - the keypress simply never
# arrives. Tried and did NOT help: QEMU's Ctrl+Alt+G grab, GDK_BACKEND=x11,
# the SDL backend with grab-mod, and VNC.
#
# This is a limitation of viewing a VM from Windows, not of Archwright. On real
# hardware Super goes straight to Hyprland. To drive the session from here,
# dispatch to the compositor over the serial console instead:
#
#   export XDG_RUNTIME_DIR=/run/user/1000
#   export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)
#   hyprctl dispatch exec foot
#
# Non-Super bindings, the mouse, and anything launched that way all work
# normally.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
# shellcheck source=tools/env.sh
. "$HERE/tools/env.sh"

PERSIST=0
DISPLAY_MODE="gtk"
SOURCE="last-good"
SPICE_PORT=""

usage() {
  cat <<'EOF'
Usage: tools/boot-installed.sh [--write] [--serial-only] [--spice [port]]

  --write        Keep changes made in this session. Default is throwaway:
                 the disk is untouched and everything is discarded on exit.
  --serial-only  No graphical window; serial console only. Useful over SSH,
                 or when there is no display available.
  --spice [port] Serve the display over SPICE (default port 5930) instead of
                 opening a window here, and connect from a NATIVE client.

                 This exists for one reason: the Super key. A window opened
                 from WSL is drawn by WSLg, which is a Windows application, so
                 Windows takes Super before the guest ever sees it. A SPICE
                 client running natively on Windows can grab the keyboard
                 itself - the same trick the Try Omarchy launcher uses, but in
                 software that already exists.

                 Install virt-viewer for Windows, then:
                     remote-viewer spice://127.0.0.1:5930
                 and press Ctrl+Alt+G inside it to take and release the grab.

                 UNVERIFIED. Nobody has confirmed this delivers Super yet; it
                 is here so it can be tried in one command instead of built.
  --latest       Boot the disk from the most recent run instead of the last
                 PASSING one. That disk is deleted and rebuilt at the start of
                 every test run, so only use this when no run is in progress.

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
    --spice)
      DISPLAY_MODE="none"; SPICE_PORT="5930"; shift
      case "${1:-}" in [0-9]*) SPICE_PORT="$1"; shift ;; esac ;;
    --latest)      SOURCE="latest"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Default to the archived copy from the last PASSING gate run. AW_VMRUN is
# wiped at the start of every test, so pointing at it by default meant that
# kicking off a run destroyed the image you were about to boot.
if [ "$SOURCE" = "last-good" ] && [ -f "$AW_LASTGOOD/disk.qcow2" ]; then
  src_dir="$AW_LASTGOOD"
  echo "Booting the archived image from the last passing run."
else
  src_dir="$AW_VMRUN"
  if [ "$SOURCE" = "last-good" ]; then
    echo "No archived image yet - falling back to the most recent run." >&2
    echo "That disk is rebuilt by every test run; if one is in progress this" >&2
    echo "will fail or show a half-finished install." >&2
  fi
fi

disk="$src_dir/disk.qcow2"
vars="$src_dir/OVMF_VARS.fd"

if [ ! -f "$disk" ]; then
  echo "No installed disk at $disk" >&2
  echo "Run an install first:  bash test/vm-install.sh --phase all" >&2
  exit 1
fi

# A clear message beats QEMU's "Failed to get write lock" three lines deep.
if pgrep -f "qemu-system-x86_64.*$(basename "$src_dir")/disk.qcow2" >/dev/null 2>&1; then
  echo "A QEMU process is already using $disk." >&2
  echo "Wait for the test run to finish, or use --latest / --write carefully." >&2
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

if [ -n "$SPICE_PORT" ]; then
  # Loopback only, and deliberately so: WSL2 forwards localhost to Windows, so
  # a native client on the same machine can reach this and nothing else can.
  # An unauthenticated SPICE server on 0.0.0.0 is a remote desktop with no
  # password.
  args+=(
    -spice "port=$SPICE_PORT,addr=127.0.0.1,disable-ticketing=on"
    -device virtio-serial-pci
    -chardev "spicevmc,id=spicechannel0,name=vdagent"
    -device "virtserialport,chardev=spicechannel0,name=com.redhat.spice.0"
  )
  cat <<EOF
SPICE display on 127.0.0.1:$SPICE_PORT (loopback only, no password).

From Windows, with virt-viewer installed:
    remote-viewer spice://127.0.0.1:$SPICE_PORT

Ctrl+Alt+G takes and releases the keyboard grab there. The point of this mode
is to find out whether a NATIVE client delivers Super to the guest, which a
window drawn by WSLg cannot. Currently unverified - please say which it is.
EOF
fi

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
