#!/usr/bin/env bash
# Phase 5: the session stack - greetd, uwsm, Hyprland.
#
# Packages are already installed: the base phase pacstraps everything in
# manifest/core.packages. This phase only configures.

aw_session() {
  local home="/mnt/home/$AW_USERNAME"
  [ -d "$home" ] || aw_die "user home $home does not exist - did the base phase run?"

  aw_log info "installing package-owned default configuration"
  aw_install_defaults "$AW_ROOT/config" /mnt \
    || aw_die "could not install the default config tree"

  aw_log info "seeding the user's configuration"
  local defaults="/mnt/usr/share/archwright/default-config"
  local rel rc
  for rel in hypr/hyprland.conf foot/foot.ini; do
    rc=0
    aw_seed_config "$defaults" "$home/.config" "$rel" || rc=$?
    [ "$rc" -le 1 ] || aw_die "could not seed $rel"
  done
  # The user must own their own config directory.
  aw_run_in_chroot "chown -R '$AW_USERNAME:$AW_USERNAME' '/home/$AW_USERNAME/.config'" \
    || aw_die "could not chown the user config directory"

  aw_log info "configuring greetd"
  install -d -m 0755 /mnt/etc/greetd
  # tuigreet on VT1 is the interactive default. uwsm launches Hyprland as a
  # proper systemd user session rather than a bare process, which is what makes
  # `systemctl --user` work for session services.
  cat > /mnt/etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --cmd 'uwsm start -- hyprland.desktop'"
user = "greeter"
EOF

  if [ "${AW_AUTOLOGIN:-0}" = "1" ]; then
    aw_log warn "AUTOLOGIN=1: the session starts without a login prompt"
    cat >> /mnt/etc/greetd/config.toml <<EOF

[initial_session]
command = "uwsm start -- hyprland.desktop"
user = "$AW_USERNAME"
EOF
  fi

  # A missing session desktop file means greetd starts, fails, and retries
  # forever with nothing on screen. Catch it here instead.
  [ -f /mnt/usr/share/wayland-sessions/hyprland.desktop ] \
    || aw_die "hyprland.desktop is missing from /usr/share/wayland-sessions - uwsm cannot start the session"

  aw_log info "enabling session services"
  aw_run_in_chroot "systemctl enable greetd.service" \
    || aw_die "could not enable greetd"

  # PipeWire and WirePlumber are USER services. `systemctl --global enable`
  # sets the default for every user without needing a live session to talk to,
  # which is the only option available from inside a chroot.
  aw_run_in_chroot "systemctl --global enable pipewire.service pipewire-pulse.service wireplumber.service" \
    || aw_die "could not enable the audio user services"

  aw_log info "session phase complete"
}
