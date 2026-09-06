#!/usr/bin/env bash
# Phase 2: GPT + ESP + LUKS2 + btrfs subvolumes + the mount tree.
#
# This is the destructive phase. Everything it creates is recorded via
# aw_track so a rollback can undo exactly this run's work and nothing else.

AW_ESP_SIZE_MIB=1024
AW_CRYPT_NAME=cryptroot

_aw_parted_print() {
  parted -ms "$AW_DISK" unit B print 2>/dev/null || true
}

# Create one partition and return the number parted actually assigned.
#
# Never predicts the number: snapshots the table before and after and takes
# the difference. See lib/partition.sh for why that matters.
_aw_make_partition() {
  local label="$1" fstype="$2" start="$3" end="$4"
  local before after num
  before="$(_aw_parted_print)"
  parted -s -a optimal "$AW_DISK" mkpart "$label" "$fstype" "$start" "$end" \
    || aw_die "parted mkpart failed for $label"
  partprobe "$AW_DISK" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  after="$(_aw_parted_print)"
  num="$(aw_new_partition_number "$before" "$after")" \
    || aw_die "could not determine which partition parted created - refusing to format anything"
  printf '%s\n' "$num"
}

# Wait for a device node to appear. partprobe and udev are asynchronous, and
# formatting a path that does not exist yet fails confusingly.
_aw_wait_for_device() {
  local dev="$1" tries=0
  while [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    [ -b "$dev" ] && return 0
    udevadm settle 2>/dev/null || true
    sleep 0.2
  done
  aw_die "device node never appeared: $dev"
}

aw_disk() {
  aw_log info "wiping and partitioning $AW_DISK"

  # Tear down anything holding the disk from a previous attempt, so a re-run
  # after a failure is not blocked by its own leftovers.
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
  cryptsetup close "$AW_CRYPT_NAME" 2>/dev/null || true

  wipefs -af "$AW_DISK" >/dev/null
  sgdisk --zap-all "$AW_DISK" >/dev/null
  partprobe "$AW_DISK" 2>/dev/null || true
  parted -s "$AW_DISK" mklabel gpt || aw_die "could not create a GPT label on $AW_DISK"

  local esp_num root_num esp_size_b actual_b
  esp_num="$(_aw_make_partition ESP fat32 1MiB "$((AW_ESP_SIZE_MIB + 1))MiB")"
  parted -s "$AW_DISK" set "$esp_num" esp on
  AW_ESP_DEV="$(aw_partition_device "$AW_DISK" "$esp_num")"
  _aw_wait_for_device "$AW_ESP_DEV"
  aw_track partition "$AW_ESP_DEV"

  esp_size_b=$((AW_ESP_SIZE_MIB * 1048576))
  actual_b="$(blockdev --getsize64 "$AW_ESP_DEV")"
  aw_assert_size_within "$actual_b" "$esp_size_b" 1048576 \
    || aw_die "ESP size sanity check failed - refusing to format $AW_ESP_DEV"

  root_num="$(_aw_make_partition archwright btrfs "$((AW_ESP_SIZE_MIB + 1))MiB" 100%)"
  AW_ROOT_DEV="$(aw_partition_device "$AW_DISK" "$root_num")"
  _aw_wait_for_device "$AW_ROOT_DEV"
  aw_track partition "$AW_ROOT_DEV"

  aw_log info "ESP=$AW_ESP_DEV (partition $esp_num), root=$AW_ROOT_DEV (partition $root_num)"

  aw_log info "creating the LUKS2 container on $AW_ROOT_DEV"
  # The passphrase goes in on stdin, never on a command line: an argument
  # would be visible in /proc to every process on the machine.
  printf '%s' "$AW_LUKS_PASSPHRASE" \
    | cryptsetup luksFormat --type luks2 --batch-mode "$AW_ROOT_DEV" - \
    || aw_die "cryptsetup luksFormat failed"
  printf '%s' "$AW_LUKS_PASSPHRASE" \
    | cryptsetup open "$AW_ROOT_DEV" "$AW_CRYPT_NAME" - \
    || aw_die "cryptsetup open failed"
  aw_track luks "$AW_CRYPT_NAME"

  local mapped="/dev/mapper/$AW_CRYPT_NAME"
  _aw_wait_for_device "$mapped"

  aw_log info "formatting"
  mkfs.fat -F32 -n ESP "$AW_ESP_DEV" >/dev/null || aw_die "mkfs.fat failed"
  mkfs.btrfs -f -L archwright "$mapped" >/dev/null || aw_die "mkfs.btrfs failed"

  aw_log info "creating subvolumes"
  mount "$mapped" /mnt || aw_die "could not mount the new btrfs filesystem"
  local subvol mountpoint opts
  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ -n "$subvol" ] || continue
    btrfs subvolume create "/mnt/$subvol" >/dev/null || aw_die "could not create subvolume $subvol"
    aw_track subvolume "$subvol"
    aw_log debug "  created $subvol -> $mountpoint"
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")
  umount /mnt

  aw_log info "mounting the tree"
  # The row whose mountpoint is '/' mounts first; everything else nests
  # under it, so ordering here is not optional.
  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ "$mountpoint" = "/" ] || continue
    mount -o "subvol=$subvol,$opts" "$mapped" /mnt \
      || aw_die "could not mount root subvolume $subvol"
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")

  mountpoint -q /mnt || aw_die "no subvolume with mountpoint '/' in manifest/subvolumes.tsv"

  while IFS=$'\t' read -r subvol mountpoint opts; do
    [ "$mountpoint" != "/" ] || continue
    mkdir -p "/mnt$mountpoint"
    mount -o "subvol=$subvol,$opts" "$mapped" "/mnt$mountpoint" \
      || aw_die "could not mount $subvol at $mountpoint"
  done < <(aw_manifest_subvolumes "$AW_ROOT/manifest/subvolumes.tsv")

  mkdir -p /mnt/boot
  mount "$AW_ESP_DEV" /mnt/boot || aw_die "could not mount the ESP at /mnt/boot"

  # Persist what the boot phase needs: it runs as a separate process.
  aw_state_set esp_dev    "$AW_ESP_DEV"
  aw_state_set root_dev   "$AW_ROOT_DEV"
  aw_state_set esp_num    "$esp_num"
  aw_state_set crypt_name "$AW_CRYPT_NAME"

  aw_log info "mount tree:"
  findmnt -R /mnt >&2
}
