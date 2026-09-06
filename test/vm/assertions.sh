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
