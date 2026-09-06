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
