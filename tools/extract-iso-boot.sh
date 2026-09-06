#!/usr/bin/env bash
# Pull the kernel and initramfs out of the Arch ISO so QEMU can boot them
# directly with -kernel/-initrd.
#
# Why: that is what lets us append console=ttyS0,115200 to the kernel command
# line. Without it the only way to reach a serial console is editing the boot
# menu interactively, which cannot be scripted. archiso's own initramfs then
# finds the medium by its volume label, so the label has to be passed too.
set -euo pipefail
# shellcheck source=tools/env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

[ -f "$AW_ISO" ] || { echo "run tools/fetch-arch-iso.sh first" >&2; exit 1; }
command -v bsdtar >/dev/null 2>&1 \
  || { echo "bsdtar required. On Debian/Ubuntu: apt install libarchive-tools" >&2; exit 1; }

mkdir -p "$AW_BOOT"

bsdtar -xOf "$AW_ISO" arch/boot/x86_64/vmlinuz-linux       > "$AW_BOOT/vmlinuz-linux"
bsdtar -xOf "$AW_ISO" arch/boot/x86_64/initramfs-linux.img > "$AW_BOOT/initramfs-linux.img"

[ -s "$AW_BOOT/vmlinuz-linux" ]       || { echo "extracted kernel is empty" >&2; exit 1; }
[ -s "$AW_BOOT/initramfs-linux.img" ] || { echo "extracted initramfs is empty" >&2; exit 1; }

# The ISO9660 volume identifier lives at byte offset 32808, 32 bytes wide.
# Reading it directly avoids depending on blkid or a loop mount, neither of
# which is reliably available unprivileged.
label="$(dd if="$AW_ISO" bs=1 skip=32808 count=32 2>/dev/null | tr -d '\0' | sed 's/[[:space:]]*$//')"
[ -n "$label" ] || { echo "could not read the ISO volume label" >&2; exit 1; }
printf '%s\n' "$label" > "$AW_BOOT/archisolabel.txt"

echo "OK: $AW_BOOT"
echo "  kernel    $(du -h "$AW_BOOT/vmlinuz-linux" | cut -f1)"
echo "  initramfs $(du -h "$AW_BOOT/initramfs-linux.img" | cut -f1)"
echo "  label     $label"
