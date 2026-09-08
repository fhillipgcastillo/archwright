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

# Like check, but shows the command's own output when it fails. For assertions
# where "it failed" is not enough to act on and the next step would otherwise be
# a whole gate run spent guessing.
check_v() {
  local label="$1"; shift
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" -eq 0 ]; then
    printf 'ok    %s\n' "$label"
  else
    printf 'FAIL  %s (exit %s)\n' "$label" "$status"
    printf '%s\n' "$out" | head -14 | sed 's/^/      | /'
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

# Run something as the logged-in user, inside their session. Defined HERE
# rather than further down with the shell-layer helpers: the audio assertions
# in the section above call it, and a function defined after its first caller
# is simply not there - the gate reported "as_user: command not found" and
# nothing else, which read like a broken audio stack.
as_user() {
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" "$@"
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

# Those two are PROCESS checks. "Audio works" was claimed on the strength of
# them from milestone 2 onward, and no sound had ever been produced anywhere -
# the VM did not even have a sound card until this was written. A running
# daemon with no hardware under it is exactly as silent as a broken one.
check "the guest has a sound card" \
  sh -c 'grep -qi "audio" /proc/asound/cards 2>/dev/null || test -d /proc/asound/card0'

# WirePlumber has to have picked the card up and made a sink of it. Without
# this, PipeWire is running and there is nowhere for audio to go.
audio_sink_exists() {
  local out
  out="$(as_user wpctl status 2>&1)"
  # Print what was seen. The first version piped straight into grep -q, so a
  # failure reported "exit 1" and nothing else - precisely the blindness
  # check_v exists to remove, reintroduced inside the function it calls.
  printf '%s\n' "$out" | head -30
  printf '%s' "$out" | sed -n '/Sinks:/,/^$/p' | grep -qE '[0-9]+\.'
}
check_v "wireplumber published a sink"  audio_sink_exists

# And the end of it: play something and require the pipeline to accept it.
# The backend discards the samples - the gate has no speakers - but everything
# from the application down to the device is exercised, which is the part that
# was never checked.
audio_plays() {
  local wav=/tmp/aw-audio-check.wav out rc
  # A second of silence, generated rather than shipped, so no asset lives in
  # the repository. Errors are NOT suppressed: the first version sent python's
  # stderr to /dev/null and returned 1, so a broken generator and a broken
  # audio stack looked identical from the outside.
  out="$(as_user python3 -c "
import wave
w = wave.open('$wav', 'wb')
w.setnchannels(1); w.setsampwidth(1); w.setframerate(8000)
w.writeframes(bytes([128]) * 8000)
w.close()
" 2>&1)" || { printf 'could not generate the wav:\n%s\n' "$out"; return 1; }
  [ -s "$wav" ] || { printf 'the generated wav is empty\n'; return 1; }

  out="$(as_user pw-play "$wav" 2>&1)"; rc=$?
  printf 'pw-play exit %s\n%s\n' "$rc" "$out"
  return "$rc"
}
check_v "audio actually plays through the stack" audio_plays
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

# --- Milestone 5: the AI layer ----------------------------------------------
AW_HOME="/home/$AW_USER"

check "archwright command installed" test -x /usr/bin/archwright
check "archwright help exits 0"      archwright help

# `aw` is the name people actually type. A symlink that is missing or dangling
# fails as "command not found", which reads like the install went wrong rather
# than like one link was forgotten.
check "the short name is installed"  test -x /usr/bin/aw
check "aw help exits 0"              aw help
same_command() { [ "$(readlink -f /usr/bin/aw)" = "$(readlink -f /usr/bin/archwright)" ]; }
check "both names are the same command" same_command
check "aw does real work, not just help" aw theme show
# Nothing else may own /usr/bin/aw. If a future package claims it, pacman would
# report a conflict at install time - this catches the case where something has
# already replaced our symlink.
check "the short name is ours" \
  sh -c 'readlink /usr/bin/aw | grep -q "^/usr/share/archwright/"'
exits_two() { archwright no-such-subcommand >/dev/null 2>&1; [ "$?" -eq 2 ]; }
check "unknown subcommand exits 2"   exits_two

check "mise installed"               test -x /usr/bin/mise
check "github cli installed"         test -x /usr/bin/gh
check "node toolchain installed"     sh -c 'command -v node npm >/dev/null'

# The stub tree is ours; the copies in the user's ~/.local/bin are what
# actually runs. The names are written out here rather than read from the
# manifest on purpose: an assertion that reads the same data it is checking
# passes when a row is deleted.
check "stub tree installed"          test -d /usr/share/archwright/agent-stubs
for agent in claude codex opencode crush pi; do
  check "launcher seeded: $agent"    test -x "$AW_HOME/.local/bin/$agent"
done
check "launcher calls mise"          sh -c 'grep -q "exec mise exec" '"$AW_HOME"'/.local/bin/claude'

owned_by_user() { [ "$(stat -c %U "$1")" = "$AW_USER" ]; }
check "launchers belong to the user" owned_by_user "$AW_HOME/.local/bin/claude"
check "state dir belongs to the user" owned_by_user "$AW_HOME/.local/state/archwright"

# The shared skill has to be reachable THROUGH each symlink. Checking that a
# symlink exists would pass on a dangling one, which is the failure that
# actually happens when a path changes - and these are not all at the same
# depth, so the relative link is computed rather than assumed.
check "canonical skill installed"    test -f /usr/share/archwright/agent-skills/archwright/SKILL.md
check "shared skill seeded"          test -f "$AW_HOME/.local/share/archwright/agent-skills/archwright/SKILL.md"
for skilldir in .claude/skills .codex/skills .pi/agent/skills .agents/skills; do
  check "skill link is a symlink: $skilldir" test -L "$AW_HOME/$skilldir/archwright"
  check "skill link resolves: $skilldir"     test -f "$AW_HOME/$skilldir/archwright/SKILL.md"
done

# Login-shell wiring. A LOGIN shell, not this one: /etc/profile.d is only read
# at login, so checking the current environment would test nothing.
#
# The probe is a file rather than `bash -lc '...'` so nothing in it has to be
# quoted against two levels of shell at once. It runs once and the three
# assertions read its output.
cat > /tmp/aw-login-probe.sh <<'PROBE'
printf 'PATH=%s\n' "$PATH"
printf 'LOCALBIN=%s\n' "$(printf '%s' "$PATH" | tr ':' '\n' | grep -c -x "$HOME/.local/bin")"
if type a >/dev/null 2>&1; then printf 'A=yes\n'; else printf 'A=no\n'; fi
PROBE
chmod 0644 /tmp/aw-login-probe.sh
login_probe="$(runuser -u "$AW_USER" -- bash -l /tmp/aw-login-probe.sh 2>/dev/null)"

# A function, not `sh -c`: a child shell would see neither $login_probe (never
# exported) nor this function - the mistake caught in milestone 2.
probe_says() { case "$login_probe" in *"$1"*) return 0 ;; esac; return 1; }

# Exactly once. Zero means the profile script never ran; two means it appends
# on every login and PATH grows without bound.
check "the local bin dir is on the login PATH exactly once" probe_says "LOCALBIN=1"
check "the a shortcut is defined in a login shell"          probe_says "A=yes"

check "agent settings seeded"        test -f "$AW_HOME/.config/archwright/agents.sh"
# The whole point of D-divergence: unattended modes ship OFF. An uncommented
# alias here would hand a fresh machine to an agent that never stops to ask.
no_live_yolo() {
  ! grep -qE '^[[:space:]]*(alias|export)[[:space:]]' "$AW_HOME/.config/archwright/agents.sh"
}
check "no unattended mode is enabled" no_live_yolo

check "the work directory exists"    test -d "$AW_HOME/Work"
check "a default agent is recorded"  sh -c 'grep -qx claude '"$AW_HOME"'/.local/state/archwright/default-agent'
check "the agent keybind is seeded"  grep -q "aw agent" "$AW_HOME/.config/hypr/shell.conf"

# A stub must actually resolve its package on first invocation. This downloads
# for real and is the slowest assertion in the file; it is also the only one
# that proves the lazy-launcher idea works at all.
#
# pi rather than any of the others, deliberately. The unit test pins pi's spec
# string, but a test that reads the same manifest it is checking only proves
# nobody edited the row - it cannot tell that the package exists or that it
# ships the command named in the third field. A previous version of this
# project recorded, wrongly, that no pi CLI existed at all. This resolves the
# package for real, which is the only assertion in the suite that could catch
# that class of mistake.
stub_first_run() {
  runuser -u "$AW_USER" -- env HOME="$AW_HOME" "$AW_HOME/.local/bin/pi" --version
}
check "a stub installs its agent on first run" stub_first_run

# The sudo window. This script runs under sudo, so SUDO_USER is already the
# real user and the drop-in is written for them - the same path a user takes.
# The re-exec through sudo itself is not covered here, because we are already
# root.
SUDO_DROPIN=/etc/sudoers.d/99-archwright-sudo-window
rm -f "$SUDO_DROPIN"
archwright sudo-window 1 >/dev/null 2>&1
check "sudo window is granted"       test -f "$SUDO_DROPIN"
check "the window names the user"    grep -q "^$AW_USER " "$SUDO_DROPIN"
# The drop-in must not break sudo for the whole machine. A malformed file here
# is unrecoverable from a running session, so this is the assertion that
# matters most in the file.
check "sudoers still parses"         visudo -c
check "the revert timer is armed"    sh -c 'systemctl is-active archwright-sudo-window-revert.timer >/dev/null'

# Auto-revert is the property that makes the window safe to ship: the grant
# must disappear even though nothing is left running to remove it. Waiting is
# the only honest way to test that.
#
# 75s for a 1-minute window is a 15-second margin, which is only enough because
# the timer sets AccuracySec explicitly. On systemd's default one-minute slack
# this assertion fails - which is how that default was found.
sleep 75
check "the window reverted on its own" sh -c "! test -f $SUDO_DROPIN"
check "sudoers still parses after the revert" visudo -c

# The reboot case, which the timer alone does NOT cover: /etc/sudoers.d is
# persistent and a transient timer is not, so a machine that reboots mid-window
# would come back with permanent passwordless root and nothing left to remove
# it. A tmpfiles rule closes that.
#
# This runs the same removal pass a boot runs, scoped to the one prefix, rather
# than rebooting the VM. Boot itself runs
# `--create --remove --boot --exclude-prefix=/dev` over the whole tree.
AW_TMPFILES_RULE=/usr/lib/tmpfiles.d/archwright-sudo-window.conf
check "boot cleanup rule installed" test -f "$AW_TMPFILES_RULE"
# Both checks below are meaningless without the rule, and would BOTH pass if it
# were deleted - "the file survived" is trivially true when nothing is
# configured to remove it. Assert the rule's content, so the tests cannot
# quietly become vacuous.
check "the rule removes the drop-in, boot-only" \
  grep -qx 'r! /etc/sudoers.d/99-archwright-sudo-window' "$AW_TMPFILES_RULE"

write_window() { printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$AW_USER" > "$SUDO_DROPIN"; chmod 0440 "$SUDO_DROPIN"; }

boot_cleanup_removes_it() {
  write_window
  [ -f "$SUDO_DROPIN" ] || return 1
  systemd-tmpfiles --remove --boot --prefix=/etc/sudoers.d >/dev/null 2>&1
  local gone=1
  [ -f "$SUDO_DROPIN" ] && gone=0
  # Never leave a live NOPASSWD rule behind on the way out: if this check
  # fails, the removal under test did not happen and nothing else would.
  rm -f "$SUDO_DROPIN"
  [ "$gone" -eq 1 ]
}
check "a window left by a reboot is removed at boot" boot_cleanup_removes_it

# The other direction: nothing outside boot may close a window that is
# legitimately open. `--clean` is what systemd-tmpfiles-clean.timer runs; the
# plain `--remove` is the stronger case, since that is the flag that WOULD act
# on this rule if the '!' were ever dropped.
periodic_clean_leaves_it() {
  write_window
  systemd-tmpfiles --clean --prefix=/etc/sudoers.d >/dev/null 2>&1
  systemd-tmpfiles --remove --prefix=/etc/sudoers.d >/dev/null 2>&1
  local still=0
  [ -f "$SUDO_DROPIN" ] && still=1
  rm -f "$SUDO_DROPIN"
  [ "$still" -eq 1 ]
}
check "an open window survives a non-boot cleanup" periodic_clean_leaves_it
check "no window is left behind by these checks" sh -c "! test -f $SUDO_DROPIN"
check "sudoers still parses at the end" visudo -c

# --- the commands, not the files they leave behind ---------------------------
#
# Everything above this point checks that artifacts exist. None of it runs what
# a user types. `archwright agent` is what Super+Shift+Ctrl+A launches and what
# the `a` shortcut calls - the primary surface of this whole milestone - and
# until these assertions existed it had only ever run against a fake agent in a
# unit test. The "a stub installs on first run" check above deliberately invokes
# the stub DIRECTLY, so it proves mise works and says nothing about the command.

aw_user_run() { runuser -u "$AW_USER" -- env HOME="$AW_HOME" "$@"; }

# A launcher we control, so the dispatcher can be driven end to end without
# downloading an agent or depending on one's behaviour.
# $PWD and $* belong to the generated script and must not expand here - that is
# the whole point of the probe.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "CWD=%s\n" "$PWD"' 'printf "ARGS=%s\n" "$*"' \
  > "$AW_HOME/.local/bin/awgate"
chmod 0755 "$AW_HOME/.local/bin/awgate"
chown "$AW_USER:$AW_USER" "$AW_HOME/.local/bin/awgate"

check "default agent can be set"     aw_user_run archwright default agent awgate
default_agent_is() { [ "$(aw_user_run archwright default agent)" = "$1" ]; }
check "the CLI reads back what it set"   default_agent_is awgate
check "the choice reached the state file" \
  grep -qx awgate "$AW_HOME/.local/state/archwright/default-agent"

# Launched from $HOME, which must be redirected: agents refuse to treat the
# home directory as a workspace, and this redirect has never been exercised
# outside a unit test.
agent_output="$(cd "$AW_HOME" && aw_user_run archwright agent --probe one 2>&1)"
agent_says() { case "$agent_output" in *"$1"*) return 0 ;; esac; return 1; }
check "archwright agent launches the default agent" agent_says "ARGS="
check "it forwards its arguments"                   agent_says "ARGS=--probe one"
check "a launch from HOME lands in ~/Work"          agent_says "CWD=$AW_HOME/Work"

# The `a` shortcut has to reach the same dispatcher. Asserting it is DEFINED,
# which is all the earlier probe did, does not prove it runs anything.
cat > /tmp/aw-a-probe.sh <<'PROBE'
cd "$HOME" || exit 1
a --probe two
PROBE
a_output="$(runuser -u "$AW_USER" -- bash -l /tmp/aw-a-probe.sh 2>&1)"
a_says() { case "$a_output" in *"$1"*) return 0 ;; esac; return 1; }
check "the a shortcut runs the default agent" a_says "ARGS=--probe two"
check "the a shortcut redirects out of HOME"  a_says "CWD=$AW_HOME/Work"

# mise-install writes a launcher; it does not need the network to do it. The
# name is inferred from the spec, which is the half that was broken while its
# test passed an explicit name.
check "mise-install accepts a pinned spec" \
  aw_user_run archwright mise-install npm:gate-probe@1.2.3
check "it inferred the name without the pin" test -x "$AW_HOME/.local/bin/gate-probe"
check "the generated launcher is valid bash" bash -n "$AW_HOME/.local/bin/gate-probe"
check "the generated launcher carries the spec" \
  grep -q 'npm:gate-probe@1.2.3' "$AW_HOME/.local/bin/gate-probe"

rm -f "$AW_HOME/.local/bin/awgate" "$AW_HOME/.local/bin/gate-probe" /tmp/aw-a-probe.sh
aw_user_run archwright default agent claude >/dev/null 2>&1
check "the default agent was restored" default_agent_is claude

# --- every agent package, against the real registry --------------------------
#
# Resolving one package proves mise works. It does not prove the other four
# exist: those are guarded only by assertions that read the same manifest they
# check, which L60 says is not an oracle - and a wrong package name is exactly
# the mistake that produced the original D17.
#
# `npm view` asks the registry without installing, so all five cost seconds
# rather than minutes. It reads the GENERATED stubs, not the manifest, so it
# also catches the generator dropping or mangling a field.
npm_declares_bin() {
  local spec="$1" want="$2" pkg
  case "$spec" in npm:*) pkg="${spec#npm:}" ;; *) return 0 ;; esac
  # npm view failing IS a failure of this assertion, so the pipefail
  # behaviour is what we want here.
  aw_user_run npm view "$pkg" bin --json 2>/dev/null | grep -q "\"$want\""  # lint-ok: pipefail
}
for stub in /usr/share/archwright/agent-stubs/*; do
  [ -f "$stub" ] || continue
  stub_name="$(basename "$stub")"
  stub_spec="$(sed -n 's/.*mise exec "\([^"]*\)".*/\1/p' "$stub")"
  stub_bin="$(sed -n 's/.*-- \([^ ]*\) .*/\1/p' "$stub")"
  check "stub $stub_name names a spec"       test -n "$stub_spec"
  check "stub $stub_name names an executable" test -n "$stub_bin"
  check "the registry says $stub_spec ships '$stub_bin'" \
    npm_declares_bin "$stub_spec" "$stub_bin"
done

# --- Milestone 6: theming ----------------------------------------------------
#
# The point of these is that a colour actually reaches the running system.
# Checking that a file contains a hex string proves nothing - the file could be
# ignored, the include could be silently dropped, and the desktop would look
# exactly as plain as before while the gate stayed green. So where a component
# can be asked what colour it is using, it is asked.

check "theming packages installed"  sh -c 'pacman -Q adw-gtk-theme papirus-icon-theme >/dev/null'
check "palettes installed"          test -f /usr/share/archwright/palettes/mocha.palette
palette_count_is() {
  [ "$(find /usr/share/archwright/palettes -name '*.palette' | wc -l)" -eq "$1" ]
}
check "all seven palettes shipped"  palette_count_is 7
check "templates installed"         test -f /usr/share/archwright/theme/theme-files.tsv
check "theme library installed"     test -f /usr/share/archwright/lib/theme.sh
check "wallpapers installed"        test -f /usr/share/archwright/wallpapers/mocha.png
check "the selected theme is recorded" \
  sh -c 'grep -qx mocha '"$AW_HOME"'/.local/state/archwright/theme'

# The generated colour files.
for f in hypr/colors.conf waybar/colors.css foot/colors.ini mako/colors \
         fuzzel/colors.ini gtk-3.0/settings.ini gtk-4.0/settings.ini; do
  check "colour file generated: $f" test -f "$AW_HOME/.config/$f"
done
check "no placeholder survived generation" \
  sh -c '! grep -rlE "@[a-z][a-z0-9_]*@" '"$AW_HOME"'/.config/hypr/colors.conf '"$AW_HOME"'/.config/waybar/colors.css '"$AW_HOME"'/.config/foot/colors.ini 2>/dev/null | grep -q .'
check "the palette reached the colour file" \
  grep -q "cba6f7" "$AW_HOME/.config/hypr/colors.conf"

# The user-owned configs carry the include, with an absolute path - foot and
# fuzzel both document that they will not accept anything else.
check "foot.ini includes its colours" \
  grep -qx "include=$AW_HOME/.config/foot/colors.ini" "$AW_HOME/.config/foot/foot.ini"
check "fuzzel.ini includes its colours" \
  grep -qx "include=$AW_HOME/.config/fuzzel/colors.ini" "$AW_HOME/.config/fuzzel/fuzzel.ini"
check "mako config includes its colours" \
  grep -q "include=" "$AW_HOME/.config/mako/config"
check "hyprland sources its colours" \
  grep -q "source = ~/.config/hypr/colors.conf" "$AW_HOME/.config/hypr/hyprland.conf"
check "waybar imports its colours" \
  grep -q 'colors.css' "$AW_HOME/.config/waybar/style.css"

# Each of these parses its own config and says so. This is what catches a
# broken include, which is otherwise invisible until first login.
check_v "foot accepts the themed config" \
  runuser -u "$AW_USER" -- env HOME="$AW_HOME" foot --check-config
check_v "fuzzel accepts the themed config" \
  runuser -u "$AW_USER" -- env HOME="$AW_HOME" fuzzel --check-config

# The compositor is the real oracle: ask the running Hyprland what colour its
# active border is, rather than trusting that the file was read.
hypr_border_is_accent() {
  # hyprctl failing IS a failure of this assertion.
  hyprctl_user getoption general:col.active_border | grep -qi "cba6f7"  # lint-ok: pipefail
}
check "hyprland is using the palette's accent" hypr_border_is_accent

hypr_rounding_applied() {
  # hyprctl failing IS a failure of this assertion.
  hyprctl_user getoption decoration:rounding | grep -qE "int: 10"  # lint-ok: pipefail
}
check "the rounded-corner look applied" hypr_rounding_applied

# Hyprland does not refuse to start on a bad option - it starts, ignores the
# line, and paints a list of complaints over the desktop. So every assertion
# above can pass while the user is looking at an error overlay, which is
# exactly what happened: milestone 6 shipped config errors that the gate had no
# way to see. Ask the compositor directly.
hypr_config_is_clean() {
  local out
  out="$(hyprctl_user configerrors 2>&1)"
  printf '%s\n' "$out"
  # Clean is EMPTY output on this version; some print "no errors". Requiring
  # that magic string made a perfectly clean config report as broken - the
  # first version of this check failed for the opposite reason to the bug it
  # was written to catch.
  case "$(printf '%s' "$out" | tr -d '[:space:]')" in
    "") return 0 ;;
  esac
  printf '%s' "$out" | grep -qi 'no errors'
}
check_v "hyprland reports no configuration errors" hypr_config_is_clean

# waybar behaves the same way with CSS: it starts, drops the rule it cannot
# parse, and says so only in the journal.
waybar_journal_is_clean() {
  local out bad
  # The user's journal, read as the user - waybar runs as a user unit and root's
  # journalctl would not see it.
  out="$(runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" \
           journalctl --user-unit waybar -n 200 --no-pager 2>/dev/null || true)"

  # Match waybar's own severity markers, not the word "css". The first version
  # of this grepped for 'css|style|parse' and matched waybar's perfectly normal
  # "[info] Using CSS file ..." line, so it failed on a healthy bar - a check
  # that cannot pass is no better than one that cannot fail.
  #
  # Two warnings are statements about the HARDWARE, not defects: this VM has no
  # battery and no bluetooth controller, and a desktop machine would report the
  # same. waybar hides those modules when their hardware is absent, which is
  # the correct behaviour - failing on them would mean the gate could only ever
  # pass on a laptop.
  bad="$(printf '%s' "$out" | grep -E '\[(error|critical)\]' || true)"
  bad="$bad$(printf '%s' "$out" | grep -E '\[warning\]' \
             | grep -viE 'no batteries|no bluetooth controller' || true)"
  printf '%s\n' "$bad"
  [ -z "$bad" ]
}
check_v "waybar started without errors or warnings" waybar_journal_is_clean

# --- probe: the 0.53+ layer rule syntax --------------------------------------
#
# INFORMATIONAL. Hyprland 0.53 replaced the rule syntax; the pre-0.53 form was
# removed rather than guessed at, and blur on the bar has been off since.
#
# The previous attempt at this probe went through `hyprctl keyword layerrule`
# and reported all four candidates rejected - which read as decisive and proved
# nothing, because that command does not apply layer rules on this version at
# all. A rejection meant either a wrong syntax or a channel that never works.
#
# This one writes the candidate into a file the config sources and reloads, so
# a rejection has exactly one explanation: the parser refused it. The config is
# restored afterwards either way.
probe_layerrule() {
  local candidate="$1" conf="$AW_HOME/.config/hypr/probe-layerrule.conf" out
  printf '%s\n' "$candidate" > "$conf"
  chown "$AW_USER:$AW_USER" "$conf"
  printf 'source = %s\n' "$conf" >> "$AW_HOME/.config/hypr/hyprland.conf"
  hyprctl_user reload >/dev/null 2>&1
  out="$(hyprctl_user configerrors 2>&1)"
  # Put the config back before judging, so a failure cannot leave the VM broken
  # for every assertion after this one.
  sed -i "\|^source = $conf\$|d" "$AW_HOME/.config/hypr/hyprland.conf"
  rm -f "$conf"
  hyprctl_user reload >/dev/null 2>&1
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]
}

printf '      --- layerrule syntax probe (informational) ---\n'
for candidate in \
  'layerrule = blur, waybar' \
  'layerrule = blur on, match:namespace waybar' \
  'layerrule = match:namespace = waybar, blur = true' \
  'layerrule = blur = true, match:namespace = waybar'
do
  if probe_layerrule "$candidate"; then
    printf '      ACCEPTED: %s\n' "$candidate"
  else
    printf '      rejected: %s\n' "$candidate"
  fi
done
check "the probe left the config clean" hypr_config_is_clean

# The wallpaper: a link the user owns, so a theme change needs no root.
check "the wallpaper link resolves"  test -f "$AW_HOME/.local/state/archwright/wallpaper.png"
check "it points into the shared tree" \
  sh -c 'readlink '"$AW_HOME"'/.local/state/archwright/wallpaper.png | grep -q "^/usr/share/archwright/wallpapers/mocha.png$"'
check "swaybg is running with an image" \
  sh -c 'pgrep -a swaybg | grep -q -- "--image"'

# --- changing theme after install --------------------------------------------
#
# Seven palettes only matter if switching between them works and does not
# destroy the user's own configuration on the way.
foot_ini_before="$(md5sum "$AW_HOME/.config/foot/foot.ini" 2>/dev/null | cut -d' ' -f1)"
style_before="$(md5sum "$AW_HOME/.config/waybar/style.css" 2>/dev/null | cut -d' ' -f1)"
printf '\n/* a line the user added */\n' >> "$AW_HOME/.config/waybar/style.css"
style_edited="$(md5sum "$AW_HOME/.config/waybar/style.css" | cut -d' ' -f1)"

# Functions, not `sh -c`: a child shell sees neither these variables nor
# aw_user_run, which is the mistake milestone 2 already made once.
# Capture, then match. `cmd | grep -q` inverts under `set -o pipefail`: the
# pipeline reports the command's exit status, not grep's verdict. That has
# already cost this project one debugging round (L46).
theme_list_marks_current() {
  local out; out="$(aw_user_run archwright theme list 2>&1)"
  printf '%s\n' "$out"
  printf '%s' "$out" | grep -q '^\* mocha'
}
theme_show_names_it() {
  local out; out="$(aw_user_run archwright theme show 2>&1)"
  printf '%s\n' "$out"
  printf '%s' "$out" | grep -q mocha
}
unknown_theme_refused() { ! aw_user_run archwright theme set nosuchtheme >/dev/null 2>&1; }

check_v "theme list marks the current one" theme_list_marks_current
check_v "theme show names it"              theme_show_names_it
check   "an unknown theme is refused"      unknown_theme_refused

check "theme set succeeds" \
  runuser -u "$AW_USER" -- env HOME="$AW_HOME" archwright theme set tokyonight
check "the colour file changed" \
  grep -q "7aa2f7" "$AW_HOME/.config/hypr/colors.conf"
check "the recorded theme changed" \
  sh -c 'grep -qx tokyonight '"$AW_HOME"'/.local/state/archwright/theme'
check "the wallpaper followed" \
  sh -c 'readlink '"$AW_HOME"'/.local/state/archwright/wallpaper.png | grep -q "tokyonight.png$"'

# The whole reason the colour files are separate: a theme change must not touch
# a file the user owns.
digest() { md5sum "$1" | cut -d' ' -f1; }
unchanged() { [ "$(digest "$1")" = "$2" ]; }
changed()   { [ "$(digest "$1")" != "$2" ]; }

check "the user's foot.ini was not rewritten" \
  unchanged "$AW_HOME/.config/foot/foot.ini" "$foot_ini_before"
check "the user's edit to style.css survived" \
  unchanged "$AW_HOME/.config/waybar/style.css" "$style_edited"
check "and it is not the shipped file either" \
  changed "$AW_HOME/.config/waybar/style.css" "$style_before"

# Put it back, so later assertions and any manual poke around the VM see the
# documented default.
runuser -u "$AW_USER" -- env HOME="$AW_HOME" archwright theme set mocha >/dev/null 2>&1
check "switching back works too" \
  grep -q "cba6f7" "$AW_HOME/.config/hypr/colors.conf"

# --- Milestone 6: hardware ---------------------------------------------------
#
# This VM has a virtio GPU and no battery, so every script here finds nothing.
# That is the property being tested: the same set has to run unchanged on a
# laptop with an NVIDIA card and in a virtual machine, and "no-ops cleanly, and
# leaves nothing behind" is exactly what cannot be checked by reading the code.
#
# What real hardware does with these is NOT tested and cannot be here - see the
# gaps table in docs/decisions.md. The detection logic is covered by unit tests
# against fixture sysfs trees instead.

check "hardware scripts installed"  test -f /usr/share/archwright/hardware/10-gpu.sh
check "hardware library installed"  test -f /usr/share/archwright/lib/hardware.sh
hardware_script_count_is() {
  [ "$(find /usr/share/archwright/hardware -name '[0-9][0-9]-*.sh' | wc -l)" -eq "$1" ]
}
check "all three shipped"           hardware_script_count_is 3

# The mask must not outlive the phase. A pacman hook left pointing at /dev/null
# means every future kernel update silently skips the initramfs rebuild, and
# the machine keeps booting an increasingly stale image until it does not.
check "the mkinitcpio install hook is not masked" \
  sh -c '! test -L /etc/pacman.d/hooks/90-mkinitcpio-install.hook'
check "the mkinitcpio remove hook is not masked" \
  sh -c '! test -L /etc/pacman.d/hooks/60-mkinitcpio-remove.hook'
check "the initramfs was built"     test -s /boot/initramfs-linux.img

# Nothing vendor-specific may be installed on a machine with no such vendor.
# Installing "just in case" is the behaviour these scripts exist to avoid.
check "no Intel driver on a virtio GPU"  sh -c '! pacman -Q vulkan-intel >/dev/null 2>&1'
check "no AMD driver on a virtio GPU"    sh -c '! pacman -Q vulkan-radeon >/dev/null 2>&1'
check "no NVIDIA driver on a virtio GPU" sh -c '! pacman -Q nvidia-utils >/dev/null 2>&1'
check "no NVIDIA modprobe config"        sh -c '! test -e /etc/modprobe.d/archwright-nvidia.conf'
# No battery in the VM, so the suspend lock must not have been installed.
check "no suspend lock on a machine with no battery" \
  sh -c '! test -e /etc/systemd/system/archwright-lock-before-suspend.service'
# mesa is what actually drives this VM, and it comes from core.
check "mesa is installed"           pacman -Q mesa

# Re-running on the installed system has to work, and has to be a no-op here.
hardware_reruns_clean() {
  local out
  out="$(echo testpassword | sudo -S archwright hardware 2>&1)"
  printf '%s\n' "$out"
  printf '%s' "$out" | grep -q 'nothing to do'
}
check_v "archwright hardware re-runs and finds nothing" hardware_reruns_clean
check "re-running left no mask behind" \
  sh -c '! test -L /etc/pacman.d/hooks/90-mkinitcpio-install.hook'

# --- P2: graphical answers to system tasks -----------------------------------

for b in nm-applet nm-connection-editor pavucontrol blueman-manager \
         grim slurp swappy nwg-displays file-roller gnome-text-editor \
         gnome-calculator; do
  check "installed: $b"             sh -c "command -v $b >/dev/null"
done
check "screenshot helper installed" test -x /usr/bin/archwright-screenshot
check "the helper answers --help"   archwright-screenshot --help
check "an unknown action exits 2" \
  sh -c 'archwright-screenshot nonsense >/dev/null 2>&1; [ "$?" -eq 2 ]'

# The extras groups must NOT be present - they were not selected.
check "desktop-tools not installed"  sh -c '! pacman -Q gnome-disk-utility >/dev/null 2>&1'
check "theming-gui not installed"    sh -c '! pacman -Q azote >/dev/null 2>&1'
check "no print daemon"              sh -c '! pacman -Q cups >/dev/null 2>&1'

# Handlers, resolved rather than read out of a file.
check "text files open in the GUI editor" mime_is text/plain org.gnome.TextEditor.desktop
check "zip opens in the archive manager"  mime_is application/zip org.gnome.FileRoller.desktop

# Keybinds and bar wiring reached the user's copies.
check "screenshot keybind seeded" \
  grep -q "archwright-screenshot region" "$AW_HOME/.config/hypr/shell.conf"
check "theme picker keybind seeded" \
  grep -q "aw theme pick" "$AW_HOME/.config/hypr/shell.conf"
check "bar opens the network editor" \
  grep -q "nm-connection-editor" "$AW_HOME/.config/waybar/config.jsonc"
check "bar has a bluetooth module" \
  grep -q '"bluetooth"' "$AW_HOME/.config/waybar/config.jsonc"

# --- your own wallpaper, and the rule that a theme change respects it --------
#
# This is the whole point of the feature: choosing an image is a decision, and
# Archwright stops making that decision for you once you have made it.
check "wallpaper show works"        aw_user_run archwright wallpaper show
wallpaper_points_at() {
  [ "$(readlink "$AW_HOME/.local/state/archwright/wallpaper.png")" = "$1" ]
}
check "it starts on the theme's own" \
  wallpaper_points_at /usr/share/archwright/wallpapers/mocha.png

# A picture the user supplies, in their own home.
runuser -u "$AW_USER" -- mkdir -p "$AW_HOME/Pictures"
cp /usr/share/archwright/wallpapers/nord.png "$AW_HOME/Pictures/mine.png"
chown "$AW_USER:$AW_USER" "$AW_HOME/Pictures/mine.png"

check "wallpaper set accepts an image" \
  aw_user_run archwright wallpaper set "$AW_HOME/Pictures/mine.png"
check "the link followed it"        wallpaper_points_at "$AW_HOME/Pictures/mine.png"
check "the choice was recorded"     test -r "$AW_HOME/.local/state/archwright/wallpaper-custom"
check "a missing image is refused" \
  sh -c "! runuser -u $AW_USER -- env HOME=$AW_HOME archwright wallpaper set /no/such.png >/dev/null 2>&1"

# The rule under test: changing theme must NOT take the picture back.
check "theme set still works with a custom wallpaper" \
  aw_user_run archwright theme set gruvbox
check "the colours changed"         grep -q "fabd2f" "$AW_HOME/.config/hypr/colors.conf"
check "the chosen wallpaper SURVIVED a theme change" \
  wallpaper_points_at "$AW_HOME/Pictures/mine.png"

check "wallpaper reset hands it back" aw_user_run archwright wallpaper reset
check "and the theme's own returns" \
  wallpaper_points_at /usr/share/archwright/wallpapers/gruvbox.png
check "the choice was forgotten"    sh -c "! test -e $AW_HOME/.local/state/archwright/wallpaper-custom"

# --- the light palette -------------------------------------------------------
#
# Six of the seven palettes are dark and the gate only ever installed a dark
# one, so the branch in archwright-apply-gtk-theme that decides light from dark
# had never run. That branch is a luma calculation on the palette's own base
# colour - deliberately not a check on the name, so a future light palette works
# without editing the script - and an untested calculation would have shipped a
# light theme with every GTK application rendering dark-on-dark.
# XDG_RUNTIME_DIR, not just HOME. gsettings writes through dconf, which needs
# the session bus, and the bus address is derived from XDG_RUNTIME_DIR. Without
# it the writes fail silently while reads still return the value the session
# set at login - so the first version of these assertions failed on a working
# product, and the final "went back to dark" check passed trivially because
# nothing had ever changed.
aw_session_run() {
  runuser -u "$AW_USER" -- env HOME="$AW_HOME" XDG_RUNTIME_DIR="$AW_XDG" "$@"
}
gsetting_is() {
  [ "$(aw_session_run gsettings get org.gnome.desktop.interface "$1" 2>/dev/null | tr -d "'")" = "$2" ]
}

check "switching to the light palette works" aw_session_run archwright theme set latte
check "the light palette's colours applied" \
  grep -q "8839ef" "$AW_HOME/.config/hypr/colors.conf"
check "GTK follows it into light mode"       gsetting_is color-scheme prefer-light
check "and picks the light GTK theme"        gsetting_is gtk-theme adw-gtk3
check "and the light icon set"               gsetting_is icon-theme Papirus-Light

# Back to the documented default for anyone who pokes around this VM.
aw_session_run archwright theme set mocha >/dev/null 2>&1
check "restored to mocha"           wallpaper_points_at /usr/share/archwright/wallpapers/mocha.png
check "and GTK went back to dark"   gsetting_is color-scheme prefer-dark

# What P2 actually cost, measured rather than estimated - D18 says state the
# trade as a number. Informational.
p2_size() {
  local s p
  for p in network-manager-applet nm-connection-editor pavucontrol blueman \
           grim slurp swappy nwg-displays file-roller gnome-text-editor \
           gnome-calculator; do
    s="$(pacman -Qi "$p" 2>/dev/null | awk -F': *' '/Installed Size/ {print $2}')"
    printf '  %-26s %s\n' "$p" "${s:-not installed}"
  done
  # A number that can be compared between gate runs. The per-package figures
  # above exclude dependencies; this one does not, so it is the honest answer
  # to "what did the system grow by" as long as somebody records it each time.
  printf '  packages installed: %s\n' "$(pacman -Q | wc -l)"
  printf '  total installed size: %s MiB\n' \
    "$(pacman -Qi 2>/dev/null | awk -F': *' '
        /^Installed Size/ {
          v = $2; u = $2
          sub(/[^0-9.].*$/, "", v); sub(/^[0-9.]+ */, "", u)
          if (u ~ /^KiB/) v /= 1024
          else if (u ~ /^B/) v /= 1048576
          total += v
        }
        END { printf "%.0f", total }')"
}
printf '      --- P2 package sizes (informational) ---\n'
p2_size 2>&1 | sed 's/^/      /'

# --- the update guard: snapshots that actually happen ------------------------
#
# Every previous gate asserted "there is a snapshot" - and there was, the one
# the install took. Nothing asserted that a SECOND one ever appears, so the
# machine shipped with a boot menu that would list exactly one entry forever
# and a rollback story that was scenery. This is the loop, end to end.

check "snap-pac installed"          pacman -Q snap-pac
check "boot-menu refresh hook installed" \
  test -f /etc/pacman.d/hooks/zzz-archwright-limine.hook
# The hook has to sort after snap-pac's own post hook, or the menu is rebuilt
# before the snapshot it should list exists.
hook_sorts_after_snap_pac() {
  [ "$(printf 'zz-snap-pac-post.hook\nzzz-archwright-limine.hook\n' \
        | LC_ALL=C sort | tail -1)" = "zzz-archwright-limine.hook" ]
}
check "it sorts after snap-pac's post hook" hook_sorts_after_snap_pac

# Retention. snapper's cleanup algorithms are all off by default, so a cleanup
# timer without these deletes nothing and the disk fills quietly.
for setting in 'NUMBER_CLEANUP="yes"' 'NUMBER_LIMIT="12"' \
               'EMPTY_PRE_POST_CLEANUP="yes"' 'ALLOW_GROUPS="wheel"'; do
  check "retention: $setting" grep -qx "$setting" /etc/snapper/configs/root
done
check "timeline creation stays off" grep -qx 'TIMELINE_CREATE="no"' /etc/snapper/configs/root
check "the cleanup timer is enabled" \
  sh -c 'systemctl is-enabled snapper-cleanup.timer | grep -qx enabled'

# A wheel user can inspect snapshots without sudo - otherwise "check what
# changed" needs a password every time and nobody does it.
check "a normal user can list snapshots" aw_user_run snapper -c root list

snapshot_count() { snapper -c root list --columns number 2>/dev/null | grep -cE '^[[:space:]]*[0-9]+'; }
limine_snapshot_entries() { grep -c 'rootflags=subvol=@snapshots/' /boot/limine.conf 2>/dev/null || printf '0'; }

snaps_before="$(snapshot_count)"
entries_before="$(limine_snapshot_entries)"

# Install something small and real. The package is irrelevant; the transaction
# is the point.
check "a package installs"          pacman -S --noconfirm --needed tree

snaps_after="$(snapshot_count)"
entries_after="$(limine_snapshot_entries)"

more_snapshots() { [ "$snaps_after" -gt "$snaps_before" ]; }
more_entries()   { [ "$entries_after" -gt "$entries_before" ]; }

check_v "a pacman transaction took a snapshot" more_snapshots
check_v "and it became a bootable menu entry"  more_entries
printf '      snapshots %s -> %s, boot entries %s -> %s\n' \
  "$snaps_before" "$snaps_after" "$entries_before" "$entries_after"

# The documented escape hatch: one transaction without a snapshot.
snaps_mid="$(snapshot_count)"
SNAP_PAC_SKIP=y pacman -S --noconfirm --needed tree >/dev/null 2>&1
skip_took_none() { [ "$(snapshot_count)" -eq "$snaps_mid" ]; }
check "SNAP_PAC_SKIP=y skips the snapshot" skip_took_none

check "archwright update rejects arguments" \
  sh -c 'archwright update nonsense >/dev/null 2>&1; [ "$?" -eq 2 ]'

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
