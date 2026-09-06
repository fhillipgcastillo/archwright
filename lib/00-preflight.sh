#!/usr/bin/env bash
# Phase 1: refuse to continue unless the environment is exactly what we need.
#
# Every check here exists so a later phase fails with a clear message now,
# rather than half-way through partitioning with a confusing one.

aw_preflight() {
  aw_require_cmd parted cryptsetup mkfs.btrfs mkfs.fat pacstrap arch-chroot \
                 genfstab sgdisk wipefs blkid lsblk blockdev curl timedatectl \
                 partprobe udevadm \
    || aw_die "missing required tools - are you running from the Arch ISO?"

  [ "$(id -u)" -eq 0 ] || aw_die "must run as root"

  [ -d /sys/firmware/efi ] \
    || aw_die "not booted in UEFI mode. Archwright is UEFI-only; reboot the installer in UEFI mode."

  [ -b "$AW_DISK" ] || aw_die "target disk is not a block device: $AW_DISK"

  local type
  type="$(lsblk -dno TYPE "$AW_DISK" 2>/dev/null || true)"
  case "$type" in
    disk|loop) ;;
    part) aw_die "$AW_DISK is a partition. Give the whole disk (e.g. /dev/vda), not /dev/vda1." ;;
    '')   aw_die "could not determine the device type of $AW_DISK" ;;
    *)    aw_die "$AW_DISK is a '$type', not a whole disk" ;;
  esac

  local size
  size="$(blockdev --getsize64 "$AW_DISK")"
  if [ "$size" -lt 17179869184 ]; then
    aw_die "target disk is $((size / 1073741824))GiB; Archwright needs at least 16GiB"
  fi

  # A mounted target means either the wrong disk or a previous run still
  # holding it. Either way, formatting it now would be destructive in a way
  # the operator did not ask for.
  if lsblk -no MOUNTPOINTS "$AW_DISK" 2>/dev/null | grep -qv '^[[:space:]]*$'; then
    aw_log warn "$AW_DISK currently has mounted partitions:"
    lsblk -no NAME,MOUNTPOINTS "$AW_DISK" >&2
    aw_die "unmount them first, or pick a different disk"
  fi

  curl -fsS --max-time 20 -o /dev/null https://archlinux.org/ \
    || aw_die "no network. The installer downloads packages from Arch's mirrors."

  # A wrong clock makes package signature verification fail with an error that
  # never mentions the clock.
  timedatectl set-ntp true 2>/dev/null \
    || aw_log warn "could not enable NTP; if the clock is wrong, signature checks will fail"

  aw_log info "preflight OK: UEFI, root, $AW_DISK ($((size / 1073741824))GiB), network up"

  if [ "${ASSUME_YES:-0}" -ne 1 ]; then
    printf 'This will ERASE ALL DATA on %s. Type ERASE to continue: ' "$AW_DISK" >&2
    local reply
    read -r reply
    [ "$reply" = "ERASE" ] || aw_die "aborted by user"
  fi
}
