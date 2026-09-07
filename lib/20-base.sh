#!/usr/bin/env bash
# Phase 3: pacstrap the base system and configure identity.
#
# ORDERING NOTE, and it is load-bearing: packages that seed /etc/skel must be
# installed BEFORE useradd, because useradd copies /etc/skel exactly once.
# There is no second chance to fix a home directory that was created too
# early. The VM phase asserts this so it cannot silently regress.

aw_base() {
  local packages count
  packages="$(aw_manifest_packages "$AW_ROOT/manifest/core.packages")"
  count="$(printf '%s\n' "$packages" | grep -c .)"
  [ "$count" -gt 0 ] || aw_die "manifest/core.packages produced no packages"
  aw_log info "pacstrap: $count packages"

  # -c makes pacstrap use the LIVE ENVIRONMENT's package cache rather than the
  # target's. Only safe when that cache is real storage: on a stock Arch ISO it
  # is a tmpfs in RAM and would be exhausted. The test harness passes the flag
  # after mounting a host directory there over 9p, which is what turns a
  # 15-minute run into a 3-minute one.
  local pacstrap_args=(-K)
  if [ "${HOST_PKG_CACHE:-0}" = "1" ]; then
    aw_log info "using the live environment's package cache"
    pacstrap_args+=(-c)
  fi

  # shellcheck disable=SC2086
  # Intentional word splitting: pacstrap takes each package as its own
  # argument, and manifest entries are validated to contain no whitespace.
  pacstrap "${pacstrap_args[@]}" /mnt $packages || aw_die "pacstrap failed"

  aw_log info "generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab
  grep -qE '[[:space:]]/[[:space:]]' /mnt/etc/fstab \
    || aw_die "genfstab produced no root entry"
  grep -q 'subvol=/@' /mnt/etc/fstab \
    || aw_die "genfstab did not record the btrfs subvolumes"

  aw_log info "timezone, clock, locale and hostname"
  [ -f "/mnt/usr/share/zoneinfo/$AW_TIMEZONE" ] \
    || aw_die "unknown timezone: $AW_TIMEZONE"
  aw_run_in_chroot "ln -sf /usr/share/zoneinfo/$AW_TIMEZONE /etc/localtime"
  aw_run_in_chroot "hwclock --systohc"

  printf '%s UTF-8\n' "$AW_LOCALE" > /mnt/etc/locale.gen
  aw_run_in_chroot "locale-gen" || aw_die "locale-gen failed for $AW_LOCALE"
  printf 'LANG=%s\n' "$AW_LOCALE" > /mnt/etc/locale.conf
  printf 'KEYMAP=%s\n' "$AW_KEYMAP" > /mnt/etc/vconsole.conf
  printf '%s\n' "$AW_HOSTNAME" > /mnt/etc/hostname
  cat > /mnt/etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$AW_HOSTNAME.localdomain	$AW_HOSTNAME
EOF

  # Archwright's own tree: ours, package-owned, never hand-edited.
  # See the ownership contract in docs/research-extract.md section 10.
  install -d -m 0755 /mnt/usr/share/archwright
  printf 'milestone-1\n' > /mnt/usr/share/archwright/VERSION

  # Skeleton seeding. This MUST stay above useradd.
  install -d -m 0755 /mnt/etc/skel/.local/state/archwright

  aw_log info "creating user $AW_USERNAME"
  aw_run_in_chroot "useradd -m -G wheel -s /bin/bash '$AW_USERNAME'" \
    || aw_die "useradd failed"
  # Passwords travel on stdin only, never as arguments.
  printf '%s:%s\n' "$AW_USERNAME" "$AW_USER_PASSWORD" \
    | arch-chroot /mnt chpasswd || aw_die "could not set the user password"
  arch-chroot /mnt passwd -l root >/dev/null \
    || aw_log warn "could not lock the root account"

  install -d -m 0750 /mnt/etc/sudoers.d
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
  chmod 0440 /mnt/etc/sudoers.d/10-wheel
  # A malformed sudoers file locks everyone out of root, so validate before
  # trusting it.
  arch-chroot /mnt visudo -cf /etc/sudoers.d/10-wheel >/dev/null \
    || aw_die "generated sudoers file is invalid"

  aw_log info "configuring the firewall"
  # The config files are edited directly rather than running `ufw` here.
  # Running it would manipulate the LIVE INSTALLER's kernel firewall - the
  # chroot shares the running kernel's netfilter tables - which is not ours to
  # change and would not persist to the target anyway.
  [ -f /mnt/etc/default/ufw ] || aw_die "ufw is not installed in the target"
  sed -i \
    -e 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' \
    -e 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' \
    -e 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' \
    /mnt/etc/default/ufw
  sed -i 's/^ENABLED=.*/ENABLED=yes/' /mnt/etc/ufw/ufw.conf
  grep -q '^DEFAULT_INPUT_POLICY="DROP"' /mnt/etc/default/ufw \
    || aw_die "failed to set the default inbound policy to DROP"
  grep -q '^ENABLED=yes' /mnt/etc/ufw/ufw.conf \
    || aw_die "failed to enable ufw in its own config"

  aw_log info "enabling services"
  aw_run_in_chroot "systemctl enable NetworkManager.service ufw.service" \
    || aw_die "could not enable base services"

  # sshd is installed but deliberately NOT enabled, and no port is opened.
  # A base system that anyone can install should not start listening on the
  # network without being asked. Turn it on with:
  #   sudo ufw allow ssh && sudo systemctl enable --now sshd
  aw_run_in_chroot "systemctl disable sshd.service" >/dev/null 2>&1 || true

  # Nothing in the session needs to block on the network, and waiting for DHCP
  # stalls graphical.target on every boot.
  aw_run_in_chroot "systemctl mask NetworkManager-wait-online.service" \
    || aw_die "could not mask NetworkManager-wait-online"

  printf '[zram0]\nzram-size = min(ram / 2, 8192)\n' \
    > /mnt/etc/systemd/zram-generator.conf

  aw_log info "base system configured"
}
