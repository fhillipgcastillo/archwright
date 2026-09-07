#!/usr/bin/env bash
# Suspend and lid behaviour, on portable machines only.
#
# Deliberately small. systemd's defaults are sensible on most laptops, so this
# fixes the one thing that is reliably wrong on an encrypted machine: the
# screen is not locked before suspending, which means the disk is unlocked and
# the session is open to anyone who opens the lid.

hw_suspend_detect() {
  aw_hw_is_laptop
}

hw_suspend_apply() {
  aw_hw_log "portable machine: locking the session before suspend"
  # hyprlock is already installed by the shell layer. This is a SYSTEM unit
  # because it has to run before the machine sleeps, which is not something a
  # user service can be relied on to do.
  aw_hw_write /etc/systemd/system/archwright-lock-before-suspend.service <<'UNIT'
# Added by Archwright. Locks every session before the machine suspends.
#
# Without this, closing the lid on an encrypted laptop leaves the disk unlocked
# and the desktop open - the encryption protects the machine when it is off and
# does nothing at all when it is merely asleep.
[Unit]
Description=Lock sessions before suspend
Before=sleep.target

[Service]
Type=forking
ExecStart=/usr/bin/loginctl lock-sessions

[Install]
WantedBy=sleep.target
UNIT
  if [ -n "$AW_HW_ROOT" ]; then
    aw_run_in_chroot "systemctl enable archwright-lock-before-suspend.service" \
      || aw_die "could not enable the suspend lock"
  else
    systemctl enable archwright-lock-before-suspend.service \
      || aw_die "could not enable the suspend lock"
  fi
}
