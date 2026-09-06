#!/usr/bin/env bash
# Phase 4: initramfs, Limine as the bootloader, snapper wired to it.
#
# Limine is not interchangeable here. Snapshot rollback from the boot menu is
# the whole reason it was chosen over systemd-boot.
#
# NO UNIFIED KERNEL IMAGE, deliberately. A UKI bakes its command line into the
# binary, so booting a snapshot - which needs a different rootflags=subvol= -
# would require one UKI per snapshot. The upstream tooling that does that is a
# Java project needing gradle and a ~330MB GraalVM download, is not in Arch's
# official repositories, and cannot reasonably be built during an install.
# Plain kernel + initramfs on the ESP keeps the command line editable per
# entry, which is what lets bin/archwright-limine-update do the same job in
# forty lines of shell. See D2 in docs/decisions.md.

# Recover the facts the disk phase established. Each phase is a separate
# process, so they come from the state file - or, if a phase was run
# standalone, are derived from the running system.
_aw_boot_load_state() {
  AW_CRYPT_NAME="$(aw_state_get crypt_name 2>/dev/null || echo cryptroot)"

  if ! AW_ESP_DEV="$(aw_state_get esp_dev 2>/dev/null)"; then
    AW_ESP_DEV="$(findmnt -no SOURCE /mnt/boot 2>/dev/null || true)"
    [ -n "$AW_ESP_DEV" ] || aw_die "cannot determine the ESP device; is /mnt/boot mounted?"
    aw_log warn "no saved state; derived ESP=$AW_ESP_DEV from the mount table"
  fi

  if ! AW_ROOT_DEV="$(aw_state_get root_dev 2>/dev/null)"; then
    AW_ROOT_DEV="$(cryptsetup status "$AW_CRYPT_NAME" 2>/dev/null \
                    | awk '/device:/ {print $2}')"
    [ -n "$AW_ROOT_DEV" ] || aw_die "cannot determine the LUKS backing device"
    aw_log warn "no saved state; derived root=$AW_ROOT_DEV from cryptsetup"
  fi

  if ! AW_ESP_NUM="$(aw_state_get esp_num 2>/dev/null)"; then
    AW_ESP_NUM="$(aw_partition_number_of "$AW_ESP_DEV")" \
      || aw_die "cannot determine the ESP partition number"
  fi
}

aw_boot() {
  _aw_boot_load_state
  aw_log info "ESP=$AW_ESP_DEV (partition $AW_ESP_NUM), root=$AW_ROOT_DEV, mapper=$AW_CRYPT_NAME"

  aw_log info "configuring mkinitcpio"
  install -d /mnt/etc/mkinitcpio.conf.d
  cat > /mnt/etc/mkinitcpio.conf.d/archwright.conf <<'EOF'
# LUKS on the root device needs systemd-based early userspace so the
# passphrase can be prompted for before the root filesystem is mounted.
# sd-encrypt replaces the older 'encrypt' hook and reads rd.luks.* from the
# kernel command line.
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
EOF

  # The command line WITHOUT rootflags: archwright-limine-update appends the
  # right subvolume per entry.
  local root_uuid cmdline
  root_uuid="$(blkid -s UUID -o value "$AW_ROOT_DEV")"
  [ -n "$root_uuid" ] || aw_die "could not read the LUKS UUID of $AW_ROOT_DEV"
  cmdline="rd.luks.name=$root_uuid=$AW_CRYPT_NAME root=/dev/mapper/$AW_CRYPT_NAME"
  if [ "${AW_SERIAL_CONSOLE:-0}" = "1" ]; then
    cmdline="$cmdline console=ttyS0,115200"
    aw_log warn "SERIAL_CONSOLE=1: adding console=ttyS0 to the kernel cmdline (test builds only)"
  fi
  install -d -m 0755 /mnt/etc/archwright
  printf '%s\n' "$cmdline" > /mnt/etc/archwright/cmdline
  aw_log info "base kernel cmdline: $cmdline"

  aw_log info "building the initramfs"
  aw_run_in_chroot "mkinitcpio -P" || aw_die "mkinitcpio failed"
  [ -f /mnt/boot/vmlinuz-linux ]       || aw_die "no kernel on the ESP"
  [ -f /mnt/boot/initramfs-linux.img ] || aw_die "no initramfs was produced"

  aw_log info "installing the Limine EFI binary"
  install -d /mnt/boot/EFI/BOOT
  aw_run_in_chroot "cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI" \
    || aw_die "could not copy the Limine EFI binary"

  aw_log info "installing archwright-limine-update"
  [ -f "$AW_ROOT/bin/archwright-limine-update" ] || aw_die "bin/archwright-limine-update is missing from the installer tree"
  install -d -m 0755 /mnt/usr/share/archwright/bin
  install -m 0755 "$AW_ROOT/bin/archwright-limine-update" \
    /mnt/usr/share/archwright/bin/archwright-limine-update
  ln -sf /usr/share/archwright/bin/archwright-limine-update \
    /mnt/usr/bin/archwright-limine-update

  # The removable-media path (EFI/BOOT/BOOTX64.EFI) boots without an NVRAM
  # entry, so a failure here is not fatal - some firmware refuses new entries.
  aw_run_in_chroot "efibootmgr --create --disk $AW_DISK --part $AW_ESP_NUM \
      --loader '\\EFI\\BOOT\\BOOTX64.EFI' --label 'Archwright' --unicode" >/dev/null 2>&1 \
    || aw_log warn "could not create an NVRAM boot entry; the removable-media path will still boot"

  aw_log info "configuring snapper"
  # snapper insists on creating /.snapshots itself and refuses if the path
  # already exists. So: unmount the subvolume we made, let snapper create its
  # own directory, delete that, and remount the real subvolume. This dance is
  # required, not incidental.
  umount /mnt/.snapshots || aw_die "could not unmount /mnt/.snapshots"
  rmdir /mnt/.snapshots
  aw_run_in_chroot "snapper --no-dbus -c root create-config /" \
    || aw_die "snapper create-config failed"
  aw_run_in_chroot "btrfs subvolume delete /.snapshots" \
    || aw_die "could not remove snapper's own .snapshots subvolume"
  mkdir -p /mnt/.snapshots
  mount -o "subvol=@snapshots,compress=zstd:1,noatime" \
    "/dev/mapper/$AW_CRYPT_NAME" /mnt/.snapshots \
    || aw_die "could not remount @snapshots"
  chmod 750 /mnt/.snapshots

  # Snapshots happen on updates, not on a clock.
  aw_run_in_chroot "systemctl disable snapper-timeline.timer" >/dev/null 2>&1 || true
  aw_run_in_chroot "systemctl enable snapper-cleanup.timer" >/dev/null \
    || aw_log warn "could not enable snapper-cleanup.timer"

  aw_log info "taking the baseline snapshot"
  aw_run_in_chroot "snapper --no-dbus -c root create --description 'archwright install baseline'" \
    || aw_die "could not create the baseline snapshot"

  # Generate the boot menu LAST, so the baseline snapshot already exists and
  # gets an entry. This is the step that proves the whole approach works.
  aw_log info "generating the Limine boot menu"
  aw_run_in_chroot "archwright-limine-update" || aw_die "archwright-limine-update failed"
  grep -qi 'snapshot' /mnt/boot/limine.conf \
    || aw_die "the generated boot menu has no snapshot entry"

  aw_log info "boot phase complete"
}
