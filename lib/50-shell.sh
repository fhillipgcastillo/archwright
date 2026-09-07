#!/usr/bin/env bash
# Phase 6: the shell layer - bar, notifications, launcher, wallpaper, idle,
# lock. Packages are already installed by the base phase; this only configures.
#
# Everything long-lived hangs off archwright-shell.target so the whole layer can
# be replaced at once (decision D3).

# Upstream units we adopt. These ship with their packages and are package-owned,
# so they are never edited - only symlinked into our target's .wants.
AW_SHELL_UPSTREAM_UNITS="waybar.service mako.service hypridle.service hyprpolkitagent.service"
# Units Archwright supplies because upstream has none.
AW_SHELL_OWN_UNITS="archwright-swaybg.service"

aw_shell() {
  local home="/mnt/home/$AW_USERNAME"
  [ -d "$home" ] || aw_die "user home $home does not exist - did the base phase run?"

  aw_log info "installing shell units"
  install -d -m 0755 /mnt/etc/systemd/user
  local unit
  for unit in archwright-shell.target $AW_SHELL_OWN_UNITS; do
    [ -f "$AW_ROOT/config/systemd/$unit" ] \
      || aw_die "missing unit file: config/systemd/$unit"
    install -m 0644 "$AW_ROOT/config/systemd/$unit" "/mnt/etc/systemd/user/$unit" \
      || aw_die "could not install $unit"
  done

  # Wire everything to the target by symlink rather than by editing upstream
  # units, which belong to their packages and would be overwritten on update.
  #
  # A .wants symlink is a START dependency ONLY. Stopping the target does NOT
  # stop a unit that merely wants it - verified the hard way: the first gate run
  # showed the layer starting correctly and refusing to stop. `PartOf=` is what
  # gives stop and restart propagation, and it has to be declared BY the unit.
  # Since these units are package-owned, that goes in a drop-in under /etc,
  # which is administrator territory and survives package updates.
  aw_log info "wiring units to archwright-shell.target"
  install -d -m 0755 /mnt/etc/systemd/user/archwright-shell.target.wants
  for unit in $AW_SHELL_UPSTREAM_UNITS; do
    [ -f "/mnt/usr/lib/systemd/user/$unit" ] \
      || aw_die "expected upstream unit is missing: /usr/lib/systemd/user/$unit"
    ln -sf "/usr/lib/systemd/user/$unit" \
      "/mnt/etc/systemd/user/archwright-shell.target.wants/$unit"

    install -d -m 0755 "/mnt/etc/systemd/user/$unit.d"
    cat > "/mnt/etc/systemd/user/$unit.d/archwright-shell.conf" <<EOF
# Added by Archwright. The upstream unit is package-owned and never edited;
# this drop-in binds it to the shell target so stopping the target stops the
# whole layer, not just the parts Archwright happens to own.
[Unit]
PartOf=archwright-shell.target
EOF
  done
  for unit in $AW_SHELL_OWN_UNITS; do
    ln -sf "/etc/systemd/user/$unit" \
      "/mnt/etc/systemd/user/archwright-shell.target.wants/$unit"
  done

  aw_log info "refreshing package-owned default configuration"
  aw_install_defaults "$AW_ROOT/config" /mnt \
    || aw_die "could not refresh the default config tree"

  aw_log info "seeding the user's shell configuration"
  local defaults="/mnt/usr/share/archwright/default-config"
  local rel rc
  for rel in hypr/shell.conf hypr/hyprlock.conf hypr/hypridle.conf \
             waybar/config.jsonc waybar/style.css \
             mako/config fuzzel/fuzzel.ini; do
    rc=0
    aw_seed_config "$defaults" "$home/.config" "$rel" || rc=$?
    [ "$rc" -le 1 ] || aw_die "could not seed $rel"
  done
  aw_run_in_chroot "chown -R '$AW_USERNAME:$AW_USERNAME' '/home/$AW_USERNAME/.config'" \
    || aw_die "could not chown the user config directory"

  aw_log info "shell phase complete"
}
