#!/usr/bin/env bash
# Download the stock Arch ISO into the cache and verify its checksum.
# The ISO is never modified - Archwright installs FROM the official medium.
set -euo pipefail
# shellcheck source=tools/env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

MIRROR="${ARCHWRIGHT_MIRROR:-https://geo.mirror.pkgbuild.com/iso/latest}"
mkdir -p "$AW_CACHE"

if [ -f "$AW_ISO" ]; then
  echo "ISO already present: $AW_ISO ($(du -h "$AW_ISO" | cut -f1))"
  exit 0
fi

echo "Resolving the latest Arch ISO from $MIRROR ..."
sums="$(curl -fsSL "$MIRROR/sha256sums.txt")"
name="$(printf '%s\n' "$sums" | awk '$2 ~ /^archlinux-[0-9.]+-x86_64\.iso$/ {print $2; exit}')"
[ -n "$name" ] || { echo "could not determine the ISO filename from sha256sums.txt" >&2; exit 1; }
sum="$(printf '%s\n' "$sums" | awk -v n="$name" '$2 == n {print $1; exit}')"
[ -n "$sum" ] || { echo "no checksum listed for $name" >&2; exit 1; }

echo "Downloading $name ..."
curl -fL --progress-bar -o "$AW_ISO.part" "$MIRROR/$name"

echo "Verifying sha256 ..."
actual="$(sha256sum "$AW_ISO.part" | awk '{print $1}')"
if [ "$actual" != "$sum" ]; then
  rm -f "$AW_ISO.part"
  echo "CHECKSUM MISMATCH: expected $sum, got $actual" >&2
  exit 1
fi

mv "$AW_ISO.part" "$AW_ISO"
printf '%s\n' "$name" > "$AW_CACHE/archlinux.iso.name"
echo "OK: $AW_ISO ($name)"
