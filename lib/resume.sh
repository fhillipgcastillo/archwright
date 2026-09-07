#!/usr/bin/env bash
# Resuming an interrupted install (planned work P1).
#
# THE PROBLEM
#
# A real install is 20-40 minutes, mostly package downloads. If it fails at
# minute 35 - flaky wifi, a mirror timing out, a lid closing - the disk phase
# wipes and re-partitions on the next attempt and every byte is downloaded
# again. Correct for a first attempt; punishing for a retry.
#
# THE APPROACH
#
# Phase completion is recorded on the ESP rather than in /run. /run is tmpfs and
# dies at reboot, which is precisely when you most need the state. The ESP is
# FAT, mounted early, and survives.
#
# `--resume` reopens the LUKS container, remounts the subvolume tree, reads what
# already finished and skips it.
#
# THE SAFETY RULE
#
# Resume touches an EXISTING disk rather than one it just created, so it refuses
# unless it can positively identify the disk as an Archwright install in
# progress: our filesystem labels, and our state file on the ESP. Anything else
# and it stops. Never predict a partition number here either - the partitions
# are found by label and filesystem type, not by position.

AW_STATE_DIR_REL="archwright"
AW_STATE_FILE_REL="$AW_STATE_DIR_REL/install-state"

# Record that a phase finished. A no-op until the ESP is mounted, which means
# preflight and disk are never recorded from inside themselves - the disk phase
# records itself once /mnt/boot exists.
aw_phase_record() {
  local name="$1"
  mountpoint -q /mnt/boot 2>/dev/null || return 0
  install -d -m 0755 "/mnt/boot/$AW_STATE_DIR_REL"
  if ! grep -qx "$name" "/mnt/boot/$AW_STATE_FILE_REL" 2>/dev/null; then
    printf '%s\n' "$name" >> "/mnt/boot/$AW_STATE_FILE_REL"
  fi
}

aw_phase_is_done() {
  [ -f "/mnt/boot/$AW_STATE_FILE_REL" ] || return 1
  grep -qx "$1" "/mnt/boot/$AW_STATE_FILE_REL"
}

# Find a partition on the target disk by filesystem type, and optionally label.
# Uses lsblk rather than assuming a partition number - see lib/partition.sh for
# why predicting numbers is forbidden.
_aw_find_part() {
  local fstype="$1" label="${2:-}" name kname ktype klabel
  while read -r kname ktype klabel; do
    [ "$ktype" = "$fstype" ] || continue
    if [ -n "$label" ] && [ "$klabel" != "$label" ]; then continue; fi
    name="$kname"
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -rno NAME,FSTYPE,LABEL "$AW_DISK" 2>/dev/null | tail -n +2)
  return 1
}

# Reopen an existing Archwright install and mount its tree at /mnt.
aw_resume_prepare() {
  local esp root mapped

  [ -b "$AW_DISK" ] || aw_die "resume: target disk is not a block device: $AW_DISK"

  esp="$(_aw_find_part vfat ESP)" \
    || aw_die "resume: no ESP labelled 'ESP' on $AW_DISK - this does not look like an Archwright install"
  root="$(_aw_find_part crypto_LUKS)" \
    || aw_die "resume: no LUKS container on $AW_DISK - this does not look like an Archwright install"

  aw_log info "resume: found ESP=$esp, LUKS=$root"

  # Prove it is OURS before touching anything, by mounting the ESP read-only
  # and looking for the state file. If this is somebody else's encrypted disk,
  # we stop here having changed nothing.
  local probe
  probe="$(mktemp -d)"
  mount -o ro "$esp" "$probe" || aw_die "resume: could not mount the ESP to inspect it"
  if [ ! -f "$probe/$AW_STATE_FILE_REL" ]; then
    umount "$probe"; rmdir "$probe"
    aw_die "resume: no Archwright install state on the ESP - refusing to touch this disk"
  fi
  local completed
  completed="$(tr '\n' ' ' < "$probe/$AW_STATE_FILE_REL")"
  umount "$probe"; rmdir "$probe"
  aw_log info "resume: phases already completed: $completed"

  AW_CRYPT_NAME="${AW_CRYPT_NAME:-cryptroot}"
  if [ ! -e "/dev/mapper/$AW_CRYPT_NAME" ]; then
    aw_log info "resume: unlocking the container"
    printf '%s' "$AW_LUKS_PASSPHRASE" \
      | cryptsetup open "$root" "$AW_CRYPT_NAME" - \
      || aw_die "resume: could not unlock the LUKS container - is LUKS_PASSPHRASE correct?"
  fi
  mapped="/dev/mapper/$AW_CRYPT_NAME"

  if ! mountpoint -q /mnt; then
    aw_log info "resume: mounting the subvolume tree"
    local subvol mountpoint_ opts
    while IFS=$'\t' read -r subvol mountpoint_ opts; do
      [ "$mountpoint_" = "/" ] || continue
      mount -o "subvol=$subvol,$opts" "$mapped" /mnt \
        || aw_die "resume: could not mount the root subvolume"
    done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")
    mountpoint -q /mnt || aw_die "resume: root subvolume did not mount"

    while IFS=$'\t' read -r subvol mountpoint_ opts; do
      [ "$mountpoint_" != "/" ] || continue
      mkdir -p "/mnt$mountpoint_"
      mountpoint -q "/mnt$mountpoint_" && continue
      mount -o "subvol=$subvol,$opts" "$mapped" "/mnt$mountpoint_" \
        || aw_die "resume: could not mount $subvol at $mountpoint_"
    done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")
  fi

  mountpoint -q /mnt/boot || mount "$esp" /mnt/boot \
    || aw_die "resume: could not mount the ESP at /mnt/boot"

  # Later phases read these from the state file rather than from the disk phase,
  # which did not run this time.
  aw_state_set esp_dev "$esp"
  aw_state_set root_dev "$root"
  aw_state_set crypt_name "$AW_CRYPT_NAME"
  local espnum
  if espnum="$(aw_partition_number_of "$esp")"; then
    aw_state_set esp_num "$espnum"
  fi

  aw_log info "resume: ready - continuing from where the last attempt stopped"
}
