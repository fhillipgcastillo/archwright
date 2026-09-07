# Archwright Milestone 3 — Shell Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Hyprland session gains desktop furniture — a status bar, notifications, an app launcher, a wallpaper, idle handling and a lock screen — all behind a single swappable boundary.

**Architecture:** every long-lived shell component is a systemd **user** service wanted by one target, `archwright-shell.target`. Hyprland's autostart starts that target and nothing else. No layer outside `config/shell/` and `config/systemd/` names waybar, mako or swaybg, so the whole furniture layer can be replaced by repointing one target — decision D3.

**Tech Stack:** waybar, mako, fuzzel, swaybg, hypridle, hyprlock, hyprpolkitagent, wl-clipboard, libnotify, brightnessctl. All verified present in Arch `extra`.

## Global Constraints

Carried forward. Every task implicitly includes these.

- **Installer code never runs on the development host.** Only inside the QEMU VM.
- **No hardcoded package lists in `lib/`.** Packages come from `manifest/`.
- **Ownership split is absolute.** `/usr/share/archwright/` is ours; `~/.config/` is the user's and is never overwritten; state in `~/.local/state/archwright/`.
- **`install.sh` runs under `set -e`** — capture non-zero returns with `|| rc=$?` (L18).
- **Never generate shell code through Python heredocs** (L19); use editor tools for anything with escapes.
- **Assertions needing shell state must be functions, not `sh -c` strings** (L25).
- **Do not assert that a D-Bus-activated service is running** (L27).
- Every script `set -euo pipefail`, clean under `bash test/lint.sh`.

## Milestone 3 gate

`bash test/vm-install.sh --phase all` passes, with these added on the **rebooted** system:

1. `archwright-shell.target` is active in the user session.
2. waybar, mako, swaybg, hypridle and hyprpolkitagent are all running.
3. Each of those is `WantedBy` the target — proving the boundary, not just that they happen to run.
4. Stopping the target stops all of them; starting it brings them back. *This is the actual test of D3.*
5. `notify-send` produces a notification mako reports.
6. The user's shell configs are seeded and owned by the user.
7. `hyprlock` and `fuzzel` are installed and bound, but **not** running — they are on-demand, and asserting otherwise repeats L27's mistake.

## Three decisions taken before planning

**`fuzzel`, not `walker`.** D3 named "walker/wofi". `walker` is **not in Arch's
official repositories** — it is AUR-only, and building AUR packages at install
time is exactly what D2 removed. Between the official alternatives, `fuzzel` is
Wayland-native, actively maintained, and by the same author as `foot`, which we
already ship. `wofi` is the older, less maintained option.

**Upstream units, our target.** waybar, mako, hypridle and hyprpolkitagent all
ship their own `systemd/user` units — we must not edit those, they are
package-owned. Instead `/etc/systemd/user/archwright-shell.target.wants/`
carries symlinks to them. `/etc/systemd/user` is administrator territory, which
is exactly what an installer is. swaybg ships no unit, so we write
`archwright-swaybg.service` ourselves.

**Shell keybinds live in a separate file.** If `hyprland.conf` named `fuzzel`
and `hyprlock` directly, the compositor config would be coupled to the shell and
D3's boundary would be a fiction. `hyprland.conf` gains one `source =` line
pointing at `hypr/shell.conf`, which holds every shell-layer binding and the
target autostart. Swapping the shell means swapping that one file.

---

## File structure

| File | Responsibility |
|---|---|
| `config/systemd/archwright-shell.target` | The boundary. One target, everything hangs off it |
| `config/systemd/archwright-swaybg.service` | swaybg has no upstream unit, so we supply one |
| `config/hypr/shell.conf` | Shell-layer keybinds and the target autostart. The only Hyprland file that names a shell component |
| `config/waybar/config.jsonc` | Bar layout and modules |
| `config/waybar/style.css` | Bar styling |
| `config/mako/config` | Notification appearance and timeouts |
| `config/fuzzel/fuzzel.ini` | Launcher appearance |
| `config/hypr/hyprlock.conf` | Lock screen |
| `config/hypr/hypridle.conf` | Idle timings, and what they trigger |
| `lib/50-shell.sh` | Phase 6. Installs units, wires the target, seeds configs |
| `manifest/core.packages` | Gains `## Group: shell` |

---

## Task 1: Packages

**Files:** `manifest/core.packages`, `test/unit/test_manifest.sh`

- [ ] **Step 1: Write the failing test**

Append to `test/unit/test_manifest.sh`, before `finish_tests`:

```bash
# Milestone 3: the shell layer.
for required in waybar mako fuzzel swaybg hypridle hyprlock hyprpolkitagent \
                wl-clipboard libnotify; do
  if printf '%s\n' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "shell package missing: $required"; fi
done

# walker is AUR-only and must never appear here: building AUR packages at
# install time is what D2 removed.
if printf '%s\n' "$pkgs" | grep -qx "walker"; then
  _fail "core.packages" "walker is AUR-only and cannot be pacstrapped"
else _pass; fi
```

- [ ] **Step 2: Run it, watch it fail**

Run: `bash test/unit/test_manifest.sh`
Expected: nine `shell package missing:` failures.

- [ ] **Step 3: Add the packages**

Append to `manifest/core.packages`:

```
## Group: shell
waybar
mako
fuzzel
swaybg
hypridle
hyprlock
hyprpolkitagent

## Group: shell-support
wl-clipboard
libnotify
brightnessctl
```

- [ ] **Step 4: Verify**

Run: `bash test/run-unit.sh`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
git add manifest/core.packages test/unit/test_manifest.sh
git commit -m "Add the shell layer to the package manifest

fuzzel rather than walker: walker is AUR-only, and building AUR packages at
install time is what D2 removed. fuzzel is Wayland-native, in extra, and by
foot's author."
```

---

## Task 2: The swap boundary

**Files:** `config/systemd/archwright-shell.target`, `config/systemd/archwright-swaybg.service`

**Interfaces:** produces a user target `archwright-shell.target` and a swaybg unit wanted by it.

- [ ] **Step 1: Write the target**

`config/systemd/archwright-shell.target`:

```ini
# The shell swap boundary (decision D3).
#
# Every long-lived piece of desktop furniture - bar, notifications, wallpaper,
# idle handling, polkit agent - is WantedBy this target and nothing else.
# Hyprland's autostart starts this target and names no component directly.
#
# To replace the whole furniture layer (with Quickshell, say): point this
# target's .wants at different units. Nothing else in Archwright has to change,
# which is the entire purpose of the boundary.
[Unit]
Description=Archwright shell layer
Documentation=https://github.com/fhillipgcastillo/archwright
# graphical-session.target is set up by uwsm when Hyprland starts, so binding
# to it means the shell dies with the session instead of lingering.
BindsTo=graphical-session.target
After=graphical-session.target
```

- [ ] **Step 2: Write the swaybg unit**

`config/systemd/archwright-swaybg.service`:

```ini
# swaybg ships no systemd unit of its own, so Archwright supplies one.
#
# A solid colour rather than an image: shipping a wallpaper means shipping a
# binary asset, and the theming milestone will drive this from the palette
# anyway.
[Unit]
Description=Wallpaper (swaybg)
PartOf=archwright-shell.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/swaybg --color '#1d2021'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=archwright-shell.target
```

- [ ] **Step 3: Commit**

```bash
git add config/systemd
git commit -m "Add the shell swap boundary: one target, one unit we own"
```

---

## Task 3: Shell component configuration

**Files:** `config/waybar/config.jsonc`, `config/waybar/style.css`, `config/mako/config`, `config/fuzzel/fuzzel.ini`, `config/hypr/hyprlock.conf`, `config/hypr/hypridle.conf`

- [ ] **Step 1: waybar config** — `config/waybar/config.jsonc`

```jsonc
// Archwright default bar. Seeded into ~/.config/waybar/ on first install and
// yours thereafter. Deliberately small: workspaces, clock, and the handful of
// indicators that tell you something you cannot otherwise see.
{
  "layer": "top",
  "position": "top",
  "height": 30,
  "spacing": 8,
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["pulseaudio", "network", "battery", "tray"],

  "hyprland/workspaces": {
    "format": "{id}",
    "on-click": "activate"
  },
  "clock": {
    "format": "{:%a %d %b  %H:%M}",
    "tooltip-format": "<tt>{calendar}</tt>"
  },
  "pulseaudio": {
    "format": "vol {volume}%",
    "format-muted": "muted",
    "on-click": "pavucontrol"
  },
  "network": {
    "format-wifi": "{essid} {signalStrength}%",
    "format-ethernet": "wired",
    "format-disconnected": "offline"
  },
  "battery": {
    "format": "bat {capacity}%",
    "states": { "warning": 30, "critical": 15 }
  },
  "tray": { "spacing": 8 }
}
```

- [ ] **Step 2: waybar style** — `config/waybar/style.css`

```css
/* Archwright default bar styling. Square, flat, no rounding - matching the
   compositor's own look-and-feel decision. */
* {
  font-family: "JetBrainsMono Nerd Font", monospace;
  font-size: 13px;
  border: none;
  border-radius: 0;
  min-height: 0;
}

window#waybar {
  background: #1d2021;
  color: #ebdbb2;
}

#workspaces button {
  padding: 0 10px;
  color: #928374;
  background: transparent;
}

#workspaces button.active {
  color: #ebdbb2;
  box-shadow: inset 0 -2px #ebdbb2;
}

#clock, #pulseaudio, #network, #battery, #tray {
  padding: 0 10px;
}

#battery.warning  { color: #fabd2f; }
#battery.critical { color: #fb4934; }
```

- [ ] **Step 3: mako config** — `config/mako/config`

```
# Archwright default notification appearance.
font=JetBrainsMono Nerd Font 10
background-color=#1d2021
text-color=#ebdbb2
border-color=#928374
border-size=2
border-radius=0
padding=10
default-timeout=5000
anchor=top-right
margin=10

[urgency=critical]
border-color=#fb4934
default-timeout=0
```

- [ ] **Step 4: fuzzel config** — `config/fuzzel/fuzzel.ini`

```ini
# Archwright default launcher.
font=JetBrainsMono Nerd Font:size=12
lines=12
width=40
horizontal-pad=16
vertical-pad=12

[colors]
background=1d2021ee
text=ebdbb2ff
selection=3c3836ff
selection-text=ebdbb2ff
border=928374ff

[border]
width=2
radius=0
```

- [ ] **Step 5: hyprlock config** — `config/hypr/hyprlock.conf`

```
# Archwright lock screen. Deliberately plain: a solid background and a password
# field. Nothing here should be able to fail in a way that leaves you locked out.
background {
    monitor =
    color = rgb(29, 32, 33)
}

input-field {
    monitor =
    size = 300, 50
    outline_thickness = 2
    dots_size = 0.25
    dots_spacing = 0.3
    outer_color = rgb(146, 131, 116)
    inner_color = rgb(40, 40, 40)
    font_color = rgb(235, 219, 178)
    fade_on_empty = false
    placeholder_text = <i>Password</i>
    position = 0, -20
    halign = center
    valign = center
}

label {
    monitor =
    text = $TIME
    color = rgb(235, 219, 178)
    font_size = 48
    font_family = JetBrainsMono Nerd Font
    position = 0, 100
    halign = center
    valign = center
}
```

- [ ] **Step 6: hypridle config** — `config/hypr/hypridle.conf`

```
# Archwright idle handling.
#
# lock_cmd uses `pidof hyprlock || hyprlock` so a second trigger cannot stack a
# second lock screen on top of the first - a known way to end up with an
# unkillable overlay.
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 360
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
```

- [ ] **Step 7: Commit**

```bash
git add config/waybar config/mako config/fuzzel config/hypr/hyprlock.conf config/hypr/hypridle.conf
git commit -m "Add default configuration for the shell components"
```

---

## Task 4: Shell keybinds, separated from the compositor config

**Files:** `config/hypr/shell.conf`, `config/hypr/hyprland.conf`

- [ ] **Step 1: Write `config/hypr/shell.conf`**

```
# Archwright shell layer bindings and autostart.
#
# This file is the ONLY Hyprland configuration that names a shell component.
# hyprland.conf sources it and otherwise knows nothing about waybar, fuzzel or
# hyprlock - which is what makes the shell swappable (decision D3). Replacing
# the furniture layer means replacing this file and the systemd target it
# starts, and nothing else.

# Start the whole furniture layer as one unit.
exec-once = systemctl --user start archwright-shell.target

$mod = SUPER

# Launcher and lock are ON DEMAND - deliberately not services.
bind = $mod, Space, exec, fuzzel
bind = $mod CTRL, L, exec, loginctl lock-session

# Notifications
bind = $mod, comma, exec, makoctl dismiss
bind = $mod SHIFT, comma, exec, makoctl dismiss --all

# Unified clipboard: these work in the terminal too, which is the single
# biggest Linux papercut this removes.
bind = $mod, C, exec, wl-copy
bind = $mod, V, exec, wl-paste
```

- [ ] **Step 2: Source it from `hyprland.conf`**

In `config/hypr/hyprland.conf`, immediately after the `$mod = SUPER` line in
the keybinds section, add:

```
# The shell layer lives behind its own file so the compositor config never
# names a shell component. See config/hypr/shell.conf and decision D3.
source = ~/.config/hypr/shell.conf
```

- [ ] **Step 3: Commit**

```bash
git add config/hypr
git commit -m "Separate shell keybinds from the compositor config

If hyprland.conf named fuzzel and hyprlock directly, D3's swap boundary would
be a fiction."
```

---

## Task 5: The shell phase

**Files:** `lib/50-shell.sh`, `install.sh`, `test/vm/drive_vm.py`

**Interfaces:** `aw_shell()`. After it: units installed in `/etc/systemd/user`, the target's `.wants` populated, user configs seeded.

- [ ] **Step 1: Write `lib/50-shell.sh`**

```bash
#!/usr/bin/env bash
# Phase 6: the shell layer - bar, notifications, launcher, wallpaper, idle,
# lock. Packages are already installed by the base phase.
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
  [ -d "$home" ] || aw_die "user home $home does not exist"

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
  # units, which belong to their packages.
  aw_log info "wiring units to archwright-shell.target"
  install -d -m 0755 /mnt/etc/systemd/user/archwright-shell.target.wants
  for unit in $AW_SHELL_UPSTREAM_UNITS; do
    [ -f "/mnt/usr/lib/systemd/user/$unit" ] \
      || aw_die "expected upstream unit is missing: /usr/lib/systemd/user/$unit"
    ln -sf "/usr/lib/systemd/user/$unit" \
      "/mnt/etc/systemd/user/archwright-shell.target.wants/$unit"
  done
  for unit in $AW_SHELL_OWN_UNITS; do
    ln -sf "/etc/systemd/user/$unit" \
      "/mnt/etc/systemd/user/archwright-shell.target.wants/$unit"
  done

  aw_log info "installing package-owned default configuration"
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
```

- [ ] **Step 2: Register the phase**

In `install.sh`: add `shell` to the phase validation `case` and its error
message, and after `run_phase session   40-session.sh` add:

```bash
run_phase shell     50-shell.sh
```

- [ ] **Step 3: Add it to the driver's phase list**

In `test/vm/drive_vm.py`, both phase tuples gain `("shell", 900)` after
`("session", 1200)`.

- [ ] **Step 4: In-target checks**

Append to the `check_guest(ser, [...], "boot")` list:

```python
            # --- shell phase ---
            ("test -f /mnt/etc/systemd/user/archwright-shell.target && echo TARGET-OK",
             "TARGET-OK"),
            ("ls /mnt/etc/systemd/user/archwright-shell.target.wants/ | wc -l", "5"),
            ("test -f /mnt/home/test/.config/waybar/config.jsonc && echo WAYBAR-OK",
             "WAYBAR-OK"),
            ("test -f /mnt/home/test/.config/mako/config && echo MAKO-OK", "MAKO-OK"),
            ("test -f /mnt/home/test/.config/hypr/shell.conf && echo SHELLCONF-OK",
             "SHELLCONF-OK"),
            ("grep -c 'archwright-shell.target' /mnt/home/test/.config/hypr/shell.conf",
             "1"),
            ("stat -c %U /mnt/home/test/.config/waybar/config.jsonc", "test"),
```

- [ ] **Step 5: Run the phase**

Run: `bash test/vm-install.sh --phase boot`
Expected: `PASS`, with the seven new checks `ok`.

- [ ] **Step 6: Lint and commit**

```bash
bash test/lint.sh
git add lib/50-shell.sh install.sh test/vm/drive_vm.py
git commit -m "Add the shell phase: units, target wiring, config seeding"
```

---

## Task 6: The gate — a live shell, and a boundary that actually works

**Files:** `test/vm/assertions.sh`

- [ ] **Step 1: Add the assertions**

In `test/vm/assertions.sh`, before the snapshot-entry block:

```bash
# --- Milestone 3: the shell layer -------------------------------------------
systemctl_user() {
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" systemctl --user "$@"
}

wait_for_shell() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if pgrep -x waybar >/dev/null 2>&1; then return 0; fi
    i=$((i + 1)); sleep 1
  done
  return 1
}

if wait_for_shell; then
  printf 'ok    the shell layer came up\n'
else
  printf 'FAIL  the shell layer came up\n'
  printf '      --- user units ---\n'
  systemctl_user list-units 'archwright*' --no-pager 2>&1 | sed 's/^/      /'
  fails=$((fails + 1))
fi

shell_target_active() { systemctl_user is-active --quiet archwright-shell.target; }
check "shell target is active"      shell_target_active
check "waybar is running"           pgrep -x waybar
check "mako is running"             pgrep -x mako
check "swaybg is running"           pgrep -x swaybg
check "hypridle is running"         pgrep -x hypridle
check "polkit agent is running"     pgrep -f hyprpolkitagent

# On-demand, NOT services. Asserting these were running would repeat L27.
check "hyprlock is installed"       test -x /usr/bin/hyprlock
check "fuzzel is installed"         test -x /usr/bin/fuzzel
check "hyprlock is NOT running"     sh -c '! pgrep -x hyprlock >/dev/null'

# The boundary itself (D3): one target controls the whole layer. This is the
# assertion that makes the swap claim real rather than aspirational.
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
    pgrep -x waybar >/dev/null && pgrep -x mako >/dev/null \
      && pgrep -x swaybg >/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}
check "stopping the target stops the layer"  boundary_stops
check "starting the target restores it"      boundary_starts

# Notifications actually work end to end.
notify_works() {
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" \
    notify-send "archwright test" "hello" || return 1
  sleep 1
  runuser -u "$AW_USER" -- env XDG_RUNTIME_DIR="$AW_XDG" \
    makoctl list | grep -q "archwright test"
}
check "notifications reach mako"    notify_works

check "waybar config seeded"        test -f "/home/$AW_USER/.config/waybar/config.jsonc"
check "mako config seeded"          test -f "/home/$AW_USER/.config/mako/config"
check "shell.conf seeded"           test -f "/home/$AW_USER/.config/hypr/shell.conf"
```

- [ ] **Step 2: Run the full gate**

Run: `bash test/vm-install.sh --phase all`

**Likely failures, in order:** the target not starting because `exec-once` ran
before the user's systemd was ready; waybar exiting on a config error (check
`journalctl --user -u waybar`); mako not registering as the notification daemon;
`makoctl list` needing the session bus.

- [ ] **Step 3: Tag and commit**

```bash
bash test/lint.sh && bash test/run-unit.sh
git add test/vm/assertions.sh
git commit -m "Assert a live shell layer and a working swap boundary"
git tag -a m3-verified -m "Milestone 3: shell layer verified in QEMU"
```

---

## Task 7: Documentation

**Files:** `README.md`, `docs/decisions.md`

- [ ] **Step 1: README** — status block moves to milestone 3, listing the bar,
notifications, launcher (`Super + Space`), lock (`Super + Ctrl + L`) and
wallpaper. Remove "no lock screen" from the limitations.

- [ ] **Step 2: decisions.md** — add:

- **L30** — fuzzel over walker, because walker is AUR-only (ties to D2).
- **L31** — upstream units are symlinked into our target's `.wants` rather than
  edited, because they are package-owned.
- **L32** — shell keybinds live in `hypr/shell.conf` so the compositor config
  names no shell component, making D3's boundary real.
- Remove **"No lock screen"** from the milestone 2 real-hardware gaps table.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/decisions.md
git commit -m "Document milestone 3"
```

---

## Self-review notes

**Spec coverage.** D3's shell layer is Tasks 2–5; its swap boundary is tested
directly by Task 6's stop/start assertions rather than merely asserted in prose.
Spec §3's `Super + C/X/V` unified clipboard lands in `shell.conf`. The lock
screen closes a gap recorded in milestone 2.

**Deliberately out of scope:** theming (the palette fan-out is milestone 6 —
these configs carry hardcoded colours for now, which is what the theming
milestone will replace), the `archwright` CLI, and any application beyond the
terminal already present.

**Known risk.** Task 6's stop/start assertion genuinely restarts the user's
desktop mid-test. If it leaves the session wedged, later assertions fail for an
unrelated reason — so it is placed after everything that does not depend on it.
