#!/usr/bin/env bash
# Runs inside the INSTALLED system and checks the milestone 1 gate.
#
# Deliberately does not use `set -e`: every check must run so one failure
# does not hide the rest of the report.
set -uo pipefail

fails=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label"
    fails=$((fails + 1))
  fi
}

check "root filesystem is btrfs"    test "$(findmnt -no FSTYPE /)" = "btrfs"
check "root is the @ subvolume"     sh -c 'findmnt -no OPTIONS / | tr "," "\n" | grep -qx "subvol=/@"'
check "/boot is vfat (the ESP)"     test "$(findmnt -no FSTYPE /boot)" = "vfat"
check "/home is a separate mount"   mountpoint -q /home
check "/.snapshots is mounted"      mountpoint -q /.snapshots
check "/var/log is a separate mount" mountpoint -q /var/log
check "root sits on a LUKS device"  sh -c 'lsblk -no TYPE | grep -q "^crypt$"'
LUKS_DEV="$(cryptsetup status cryptroot 2>/dev/null | awk '/device:/ {print $2}')"
check "LUKS header is version 2"    sh -c "cryptsetup luksDump '$LUKS_DEV' | grep -q 'Version:.*2'"
check "snapper has a snapshot"      sh -c 'snapper -c root list | grep -qE "^[[:space:]]*[1-9]"'
check "timeline timer is OFF"       sh -c '! systemctl is-enabled snapper-timeline.timer 2>/dev/null | grep -qx enabled'
check "cleanup timer is ON"         sh -c 'systemctl is-enabled snapper-cleanup.timer 2>/dev/null | grep -qx enabled'
check "kernel is on the ESP"        test -f /boot/vmlinuz-linux
check "initramfs is on the ESP"     test -f /boot/initramfs-linux.img
check "limine.conf present"         test -f /boot/limine.conf
check "limine.conf boots the kernel" sh -c 'grep -q "path: boot():/vmlinuz-linux" /boot/limine.conf'
check "limine-update tool present"  test -x /usr/bin/archwright-limine-update
check "NetworkManager enabled"      sh -c 'systemctl is-enabled NetworkManager.service | grep -qx enabled'
check "wait-online is masked"       sh -c 'systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null | grep -qx masked'
check "firewall is active"          sh -c 'ufw status | grep -qi "^Status: active"'
check "inbound is denied"           sh -c 'ufw status verbose | grep -qi "deny (incoming)"'
check "outbound is allowed"         sh -c 'ufw status verbose | grep -qi "allow (outgoing)"'
check "no ports are open"           sh -c '! ufw status | grep -qE "ALLOW +Anywhere"'
check "sshd is NOT enabled"         sh -c '! systemctl is-enabled sshd.service 2>/dev/null | grep -qx enabled'
check "sshd is NOT listening"       sh -c '! ss -Hltn "sport = :22" | grep -q .'
check "archwright tree installed"   test -f /usr/share/archwright/VERSION

# --- Milestone 2: the session stack -----------------------------------------
#
# Hyprland runs in the USER's session, not this one, so these look at it from
# the outside: the process, its socket, and hyprctl pointed at the right
# runtime directory.
AW_USER="${SUDO_USER:-$USER}"
AW_UID="$(id -u "$AW_USER" 2>/dev/null || echo 1000)"
AW_XDG="/run/user/$AW_UID"

# hyprctl needs HYPRLAND_INSTANCE_SIGNATURE to find the compositor; without it
# it has no idea which socket to talk to, and fails in a way that looks exactly
# like "the session did not start". The signature is the directory name under
# $XDG_RUNTIME_DIR/hypr, newest first.
hyprctl_user() {
  local sig
  sig="$(find "$AW_XDG/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' \
           2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$sig" ]; then
    echo "no Hyprland instance under $AW_XDG/hypr" >&2
    ls -la "$AW_XDG" >&2 2>/dev/null
    return 1
  fi
  runuser -u "$AW_USER" -- \
    env XDG_RUNTIME_DIR="$AW_XDG" HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl "$@"
}

# A bounded wait, not a fixed sleep: the session starts in parallel with our
# login, so how long it takes varies with disk and CPU. Waiting for the actual
# condition is faster when it is ready and more informative when it is not.
wait_for_session() {
  local i=0
  while [ "$i" -lt 90 ]; do
    if pgrep -x Hyprland >/dev/null 2>&1 \
       && ls "$AW_XDG"/wayland-* >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

if wait_for_session; then
  printf 'ok    the Hyprland session came up\n'
else
  printf 'FAIL  the Hyprland session came up\n'
  printf '      --- greetd journal ---\n'
  journalctl -u greetd --no-pager -n 40 2>/dev/null | sed 's/^/      /'
  fails=$((fails + 1))
fi

check "greetd is enabled"           sh -c 'systemctl is-enabled greetd.service | grep -qx enabled'
check "greetd is active"            systemctl is-active --quiet greetd.service
check "greetd offers tuigreet"      sh -c 'grep -q tuigreet /etc/greetd/config.toml'
check "Hyprland is running"         pgrep -x Hyprland
# These are functions rather than `sh -c '...'` strings on purpose: a child
# shell would see neither AW_XDG (never exported) nor hyprctl_user (a shell
# function), so those checks would have failed for the wrong reason entirely.
# `check` runs its arguments in THIS shell, where both exist.
have_wayland_socket() { ls "$AW_XDG"/wayland-* >/dev/null 2>&1; }
hyprctl_answers()     { hyprctl_user version  | grep -qi hyprland; }
hypr_has_monitor()    { hyprctl_user monitors | grep -qE "^Monitor "; }
hypr_monitor_mode()   { hyprctl_user monitors | grep -qE "[0-9]+x[0-9]+@"; }

check "the wayland socket exists"   have_wayland_socket
check "hyprctl answers"             hyprctl_answers
check "a monitor is present"        hypr_has_monitor
check "the monitor has a mode"      hypr_monitor_mode
check "pipewire is running"         pgrep -x pipewire
check "wireplumber is running"      pgrep -x wireplumber
# Portals are D-Bus ACTIVATED: they start when an application asks for one.
# With nothing running that wants a file picker or a screencast, the portal is
# correctly not running, so asserting that it is tests nothing. Assert instead
# that it is installed and registered for this desktop, which is the part the
# installer is actually responsible for.
check "hyprland portal installed"   test -x /usr/lib/xdg-desktop-portal-hyprland
check "hyprland portal registered"  test -f /usr/share/xdg-desktop-portal/portals/hyprland.portal
check "gtk portal registered"       test -f /usr/share/xdg-desktop-portal/portals/gtk.portal
check "portal is dbus-activatable"  test -f /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service
check "user hyprland.conf seeded"   test -f "/home/$AW_USER/.config/hypr/hyprland.conf"
check "user foot.ini seeded"        test -f "/home/$AW_USER/.config/foot/foot.ini"
check "packaged defaults present"   test -f /usr/share/archwright/default-config/hypr/hyprland.conf

# --- Milestone 3: the shell layer -------------------------------------------
systemctl_user() {
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" systemctl --user "$@"
}
as_user() {
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" "$@"
}

wait_for_shell() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if pgrep -x waybar >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

if wait_for_shell; then
  printf 'ok    the shell layer came up\n'
else
  printf 'FAIL  the shell layer came up\n'
  printf '      --- archwright user units ---\n'
  systemctl_user list-units 'archwright*' --no-pager 2>&1 | sed 's/^/      /'
  printf '      --- waybar journal ---\n'
  journalctl --user-unit waybar -n 20 --no-pager 2>&1 | sed 's/^/      /'
  fails=$((fails + 1))
fi

shell_target_active() { systemctl_user is-active --quiet archwright-shell.target; }
check "shell target is active"      shell_target_active
check "waybar is running"           pgrep -x waybar
check "mako is running"             pgrep -x mako
check "swaybg is running"           pgrep -x swaybg
check "hypridle is running"         pgrep -x hypridle
check "polkit agent is running"     pgrep -f hyprpolkitagent

# On-demand, NOT services. Asserting these were running would repeat the
# mistake recorded as L27.
check "hyprlock is installed"       test -x /usr/bin/hyprlock
check "fuzzel is installed"         test -x /usr/bin/fuzzel
check "hyprlock is NOT running"     sh -c '! pgrep -x hyprlock >/dev/null'

# Notifications end to end, before the boundary test restarts everything.
notify_works() {
  as_user notify-send "archwright test" "hello" || return 1
  sleep 1
  as_user makoctl list | grep -q "archwright test"
}
check "notifications reach mako"    notify_works

check "waybar config seeded"        test -f "/home/$AW_USER/.config/waybar/config.jsonc"
check "mako config seeded"          test -f "/home/$AW_USER/.config/mako/config"
check "shell.conf seeded"           test -f "/home/$AW_USER/.config/hypr/shell.conf"

# The boundary itself (D3). This is what makes the swap claim real rather than
# aspirational: one target must control the whole layer. Deliberately LAST,
# because it restarts the desktop mid-test and anything after it would fail for
# an unrelated reason.
boundary_stops() {
  systemctl_user stop archwright-shell.target
  sleep 3
  ! pgrep -x waybar >/dev/null && ! pgrep -x mako >/dev/null \
    && ! pgrep -x swaybg >/dev/null
}
boundary_starts() {
  systemctl_user start archwright-shell.target
  local i=0
  while [ "$i" -lt 30 ]; do
    if pgrep -x waybar >/dev/null && pgrep -x mako >/dev/null \
       && pgrep -x swaybg >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}
check "stopping the target stops the whole layer" boundary_stops
check "starting the target restores it"           boundary_starts

# --- Milestone 4: applications ----------------------------------------------
check "firefox installed"           test -x /usr/bin/firefox
check "neovim installed"            test -x /usr/bin/nvim
check "nautilus installed"          test -x /usr/bin/nautilus
check "image viewer installed"      test -x /usr/bin/imv
check "video player installed"      test -x /usr/bin/mpv
check "pdf viewer installed"        test -x /usr/bin/evince
check "cli staples installed"       sh -c 'command -v eza bat fd fzf lazygit btop >/dev/null'
check "vim is gone"                 sh -c '! test -x /usr/bin/vim'

# The default handlers must actually RESOLVE, not merely be written to a file.
mime_is() {
  [ "$(runuser -u "$AW_USER" -- xdg-mime query default "$1" 2>/dev/null)" = "$2" ]
}
check "html opens in firefox"       mime_is text/html firefox.desktop
check "png opens in imv"            mime_is image/png imv.desktop
check "mp4 opens in mpv"            mime_is video/mp4 mpv.desktop
check "pdf opens in evince"         mime_is application/pdf org.gnome.Evince.desktop
check "folders open in nautilus"    mime_is inode/directory org.gnome.Nautilus.desktop

# Selected extras present, unselected absent, and no repository enabled that
# nothing asked for.
check "selected extra installed"    pacman -Q docker
check "unselected extra absent"     sh -c '! pacman -Q libreoffice-fresh >/dev/null 2>&1'
check "multilib not enabled"        sh -c '! grep -qE "^\[multilib\]" /etc/pacman.conf'

# Snapshot boot entries are the entire reason Limine was chosen over
# systemd-boot, so this one is reported separately and loudly.
if grep -q "rootflags=subvol=@snapshots/" /boot/limine.conf 2>/dev/null; then
  printf 'ok    limine.conf carries a snapshot entry\n'
else
  printf 'FAIL  limine.conf carries a snapshot entry\n'
  printf '      --- limine.conf ---\n'
  sed 's/^/      /' /boot/limine.conf 2>/dev/null
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  printf 'ASSERTIONS-FAILED:%d\n' "$fails"
  exit 1
fi
printf 'ASSERTIONS-PASSED\n'
