# Archwright Milestone 2 — Session Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the installed system boots to a **greetd login**, and logging in starts a real **Hyprland** session on the DRM backend, with audio, portals and a terminal that opens.

**Architecture:** milestone 1's four phases gain a fifth, `lib/40-session.sh`, which configures greetd, uwsm and Hyprland after `pacstrap` has already installed the packages from `manifest/`. Configuration is installed under the ownership split — package-owned defaults in `/usr/share/archwright/default-config/`, seeded into `~/.config/` only when absent. The VM gets a single virtio GPU so Hyprland runs on the genuine DRM backend rather than a headless shim.

**Tech Stack:** Arch packages only (all 17 verified present in `extra` — no AUR). hyprland, uwsm, greetd + greetd-tuigreet, xdg-desktop-portal{,-hyprland,-gtk}, pipewire + wireplumber, polkit, mesa, xorg-xwayland, foot, JetBrainsMono Nerd Font.

## Global Constraints

Carried from milestone 1. Every task's requirements implicitly include these.

- **Installer code never runs on the development host.** Only inside the QEMU VM.
- **No hardcoded package lists in `lib/`.** Packages come from `manifest/`, read at runtime.
- **Ownership split is absolute.** `/usr/share/archwright/` is ours and never hand-edited; `~/.config/` is the user's and is never overwritten; generated state goes in `~/.local/state/archwright/`.
- **Every script:** `#!/usr/bin/env bash` + `set -euo pipefail`, clean under `bash test/lint.sh`. No `# shellcheck disable` without an inline reason.
- **`install.sh` runs under `set -e`.** A bare call to a function that returns non-zero aborts the phase — capture with `|| rc=$?` (this bit us in milestone 1, L18).
- **Never generate shell code through Python heredocs** (L19). Use the editor tools for anything with escapes or non-ASCII.
- **Each `--phase` is a separate process.** Cross-phase facts go through `aw_state_set` / `aw_state_get`.
- **Anything the harness supplies for free is a gap** until documented or handled — networking, firmware behaviour, predictable device names.

## Milestone 2 gate

`bash test/vm-install.sh --phase all` must pass, with these added to the existing 25 assertions on the **rebooted** system:

1. `greetd.service` is enabled and active.
2. A Hyprland process is running.
3. `hyprctl version` succeeds against the running instance.
4. `hyprctl monitors` reports at least one monitor with a non-zero resolution.
5. The Wayland socket exists in the user's runtime directory.
6. `pipewire` and `wireplumber` user services are running.
7. `xdg-desktop-portal-hyprland` is running.
8. The user's `~/.config/hypr/hyprland.conf` exists and was seeded from our defaults.

## Two findings that shape this plan

**The harness already has a usable GPU — but the wrong one.** Probing (commit
`652103e`) found the default QEMU display is bochs: it gives `/dev/dri/card0`
with a connected connector, but **no render node**, which is what EGL/GBM needs.
Adding `-vga none -device virtio-gpu-pci` yields exactly one card, one connected
connector, and `renderD128` — the shape of a real single-GPU machine. Milestone 2
makes that the harness default, so Hyprland runs the same DRM code path it would
on hardware.

**The gate cannot log in through tuigreet.** greetd's tuigreet runs on VT1; the
test harness only has the serial console, and cannot type into VT1. So the
automated gate needs the session to start without a human. Rather than a
test-only hack, this plan adds **`AUTOLOGIN`** as a real supported option — a
reasonable thing to want on a single-user laptop — which the test happens to
enable. The gate additionally asserts that the *interactive* tuigreet path is
configured, so the shipped default is not left untested by inspection.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/config.sh` | The ownership split in code: install package-owned defaults, seed user config only when absent |
| `lib/40-session.sh` | Phase 5. greetd, uwsm, Hyprland config, session services |
| `config/hypr/hyprland.conf` | Default Hyprland config: monitors, environment, autostart, look-and-feel, keybinds |
| `config/foot/foot.ini` | Terminal defaults (font, minimal) |
| `manifest/core.packages` | Gains `## Group: session`, `## Group: audio`, `## Group: fonts` |
| `test/unit/test_config.sh` | Unit tests for the seeding logic |
| `test/vm/drive_vm.py` | Single virtio GPU by default; new `session` phase |
| `test/vm/assertions.sh` | The eight new gate assertions |
| `test/vm/answers.example.conf` | `AUTOLOGIN=1` for the test build |
| `lib/answers.sh` | `AUTOLOGIN` key, validated as `0` or `1` |

---

## Task 1: Give the VM a real GPU

**Files:**
- Modify: `test/vm/drive_vm.py` (`start_qemu`)

**Interfaces:**
- Consumes: nothing.
- Produces: every VM launched by the harness has exactly one virtio GPU with a render node. `AW_EXTRA_QEMU_ARGS` still appends after the defaults.

- [ ] **Step 1: Add the GPU to `start_qemu`**

In `test/vm/drive_vm.py`, in the `args` list inside `start_qemu`, replace the
`"-display", "none",` entry with:

```python
        # A real single-GPU machine: one virtio GPU, one connected connector,
        # and a render node. Probing (commit 652103e) showed QEMU's default
        # bochs display gives a card and a connector but NO render node, which
        # is what EGL/GBM needs - so Hyprland would fall back to a software
        # path the harness would then be silently testing instead of the real
        # one. -vga none removes the default VGA so there is exactly one card.
        "-vga", "none",
        "-device", "virtio-gpu-pci",
        "-display", "none",
```

- [ ] **Step 2: Verify the guest sees one card with a render node**

Run:

```
wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash test/vm-install.sh --phase probe-gpu'
```

Expected, in the probe output: exactly one `Display controller: Red Hat, Inc.
Virtio 1.0 GPU`, `card0` and `renderD128` under `/dev/dri`, `virtio_gpu` in
the loaded modules, and exactly one connector reporting `=connected`.

- [ ] **Step 3: Confirm milestone 1 still passes on the new hardware**

Run:

```
wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash test/vm-install.sh --phase all'
```

Expected: `PASS: milestone 1 gate met`, 25 assertions. Changing the emulated
graphics must not disturb the base install; if it does, that is a real finding
about device enumeration and must be understood before continuing.

- [ ] **Step 4: Commit**

```bash
git add test/vm/drive_vm.py
git commit -m "Give the test VM a single virtio GPU with a render node"
```

---

## Task 2: Session packages in the manifest

**Files:**
- Modify: `manifest/core.packages`
- Modify: `test/unit/test_manifest.sh`

**Interfaces:**
- Consumes: `aw_manifest_packages`.
- Produces: `manifest/core.packages` contains the session stack. No new file — the base phase already pacstraps everything in it.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/test_manifest.sh`, immediately before the final
`finish_tests` line:

```bash
# Milestone 2: the session stack must be present in core, because the base
# phase pacstraps core and nothing else installs packages.
for required in hyprland uwsm greetd greetd-tuigreet xdg-desktop-portal-hyprland \
                pipewire wireplumber polkit mesa foot; do
  if printf '%s\n' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "session package missing: $required"; fi
done
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash test/unit/test_manifest.sh`
Expected: ten `FAIL core.packages session package missing: ...` lines.

- [ ] **Step 3: Add the packages**

In `manifest/core.packages`, after the `## Group: hardware` block, append:

```
## Group: session
hyprland
uwsm
xorg-xwayland
greetd
greetd-tuigreet
polkit
mesa

## Group: portals
xdg-desktop-portal
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk

## Group: audio
pipewire
pipewire-alsa
pipewire-pulse
wireplumber

## Group: terminal
foot

## Group: fonts
ttf-jetbrains-mono-nerd
```

- [ ] **Step 4: Run the tests**

Run: `bash test/run-unit.sh`
Expected: all suites pass; `test_manifest.sh` gains ten assertions.

- [ ] **Step 5: Commit**

```bash
git add manifest/core.packages test/unit/test_manifest.sh
git commit -m "Add the session stack to the core package manifest

All 17 packages verified present in Arch's official repos - unlike the Limine
snapshot tooling, no AUR path is needed here."
```

---

## Task 3: `AUTOLOGIN` answer key

**Files:**
- Modify: `lib/answers.sh`
- Modify: `test/unit/test_answers.sh`
- Modify: `test/vm/answers.example.conf`

**Interfaces:**
- Consumes: `_aw_check`, `aw_answers_reset`.
- Produces: `AW_AUTOLOGIN`, `"0"` or `"1"`, default `"0"`. Validated.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/test_answers.sh`, immediately before `rm -rf "$tmp"`:

```bash
# AUTOLOGIN: a real supported option (single-user laptops), which the test
# harness also relies on because it cannot type into tuigreet on VT1.
aw_answers_load "$ROOT/test/vm/answers.example.conf"
assert_eq "$AW_AUTOLOGIN" "1" "autologin parsed from the example answers"

printf 'DISK=/dev/vda\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD=p\nLUKS_PASSPHRASE=l\n' > "$tmp/noauto.conf"
aw_answers_load "$tmp/noauto.conf"
assert_eq "$AW_AUTOLOGIN" "0" "autologin defaults to off"

mkbase 'AUTOLOGIN=yes'
assert_fails aw_answers_validate "autologin must be 0 or 1"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash test/unit/test_answers.sh`
Expected: `FAIL autologin parsed from the example answers` — `AW_AUTOLOGIN` is
unbound or empty.

- [ ] **Step 3: Implement**

In `lib/answers.sh`, add to `aw_answers_reset`:

```bash
  AW_AUTOLOGIN="0"
```

Add to the `case "$key" in` block in `aw_answers_load`:

```bash
      AUTOLOGIN)       AW_AUTOLOGIN="$value" ;;
```

Add to `aw_answers_validate`, beside the `SERIAL_CONSOLE` check:

```bash
  _aw_check AUTOLOGIN "$AW_AUTOLOGIN" '^[01]$' \
    '0 or 1' || ok=1
```

In `test/vm/answers.example.conf`, add before the `SERIAL_CONSOLE` line:

```
# Skip the login prompt and start the session directly. A supported option for
# single-user machines; the test harness needs it because it drives the guest
# over a serial console and cannot type into tuigreet on VT1.
AUTOLOGIN=1
```

- [ ] **Step 4: Run the tests**

Run: `bash test/run-unit.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/answers.sh test/unit/test_answers.sh test/vm/answers.example.conf
git commit -m "Add an AUTOLOGIN answer key, defaulting to off"
```

---

## Task 4: The ownership split in code

**Files:**
- Create: `lib/config.sh`
- Create: `test/unit/test_config.sh`
- Modify: `install.sh` (source the new library)

**Interfaces:**
- Consumes: `aw_log`, `aw_die`.
- Produces:
  - `aw_install_defaults <repo_config_dir> <target_root>` — copies the repo's `config/` tree to `<target_root>/usr/share/archwright/default-config/`, mode 0644 files / 0755 dirs.
  - `aw_seed_config <src_root> <dst_root> <relpath> <owner_uid> <owner_gid>` — copies one file only if the destination is absent; returns 0 when it copied, 1 when it left an existing file alone, 2 on error. Never overwrites.

- [ ] **Step 1: Write the failing test**

Create `test/unit/test_config.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/config.sh
. "$ROOT/lib/config.sh"

AW_LOG_LEVEL=error
tmp="$(mktemp -d)"
src="$tmp/src"; dst="$tmp/dst"
mkdir -p "$src/hypr" "$dst"
printf 'default content\n' > "$src/hypr/hyprland.conf"

# Seeds when absent.
aw_seed_config "$src" "$dst" "hypr/hyprland.conf"
assert_eq "$?" "0" "seeding an absent file reports that it copied"
assert_eq "$(cat "$dst/hypr/hyprland.conf")" "default content" "content was copied"

# NEVER overwrites. This is the ownership split: ~/.config belongs to the user.
printf 'the user edited this\n' > "$dst/hypr/hyprland.conf"
aw_seed_config "$src" "$dst" "hypr/hyprland.conf"
assert_eq "$?" "1" "seeding an existing file reports that it left it alone"
assert_eq "$(cat "$dst/hypr/hyprland.conf")" "the user edited this" \
  "an existing user config is never overwritten"

# A missing source is an error, not a silent no-op.
aw_seed_config "$src" "$dst" "nope/missing.conf"
assert_eq "$?" "2" "a missing source file is an error"

# Parent directories are created.
aw_seed_config "$src" "$dst/deep/er" "hypr/hyprland.conf"
assert_eq "$?" "0" "seeds into a directory that does not exist yet"
if [ -f "$dst/deep/er/hypr/hyprland.conf" ]; then _pass
else _fail "nested seed" "file was not created"; fi

# Installing defaults mirrors the tree.
troot="$tmp/target"
mkdir -p "$troot"
aw_install_defaults "$src" "$troot"
if [ -f "$troot/usr/share/archwright/default-config/hypr/hyprland.conf" ]; then _pass
else _fail "install_defaults" "default-config tree was not created"; fi

rm -rf "$tmp"
finish_tests
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash test/run-unit.sh`
Expected: `lib/config.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/config.sh`**

```bash
#!/usr/bin/env bash
# The ownership split, in code.
#
#   /usr/share/archwright/default-config/  ours, package-owned, replaced on update
#   ~/.config/                             the user's, NEVER overwritten
#
# Retrofitting this contract is painful, so it is established the first time
# any configuration is installed. See section 5 of the spec.

# Copy the repo's config/ tree into the target as package-owned defaults.
aw_install_defaults() {
  local src="$1" target_root="$2"
  local dest="$target_root/usr/share/archwright/default-config"
  [ -d "$src" ] || { aw_log error "no config tree at $src"; return 1; }
  install -d -m 0755 "$dest"
  ( cd "$src" && find . -type d -exec install -d -m 0755 "$dest/{}" \; )
  ( cd "$src" && find . -type f -exec install -m 0644 "{}" "$dest/{}" \; )
}

# Seed ONE user config file from the defaults, only when it is absent.
#
#   0 = copied    1 = left an existing file alone    2 = error
#
# Never overwrites and never writes a .bak: this is first-install seeding, not
# a restore. A user who has edited their config keeps it, full stop.
aw_seed_config() {
  local src_root="$1" dst_root="$2" rel="$3"
  local src="$src_root/$rel" dst="$dst_root/$rel"

  if [ ! -f "$src" ]; then
    aw_log error "no default config to seed from: $src"
    return 2
  fi
  if [ -e "$dst" ]; then
    aw_log info "  keeping existing $rel"
    return 1
  fi
  install -d -m 0755 "$(dirname "$dst")" || return 2
  install -m 0644 "$src" "$dst" || return 2
  aw_log info "  seeded $rel"
  return 0
}
```

- [ ] **Step 4: Source it from `install.sh`**

In `install.sh`, after the `lib/partition.sh` source line, add:

```bash
# shellcheck source=lib/config.sh
. "$AW_ROOT/lib/config.sh"
```

- [ ] **Step 5: Run the tests and lint**

Run: `bash test/run-unit.sh && bash test/lint.sh`
Expected: all suites pass; lint clean.

- [ ] **Step 6: Commit**

```bash
git add lib/config.sh test/unit/test_config.sh install.sh
git commit -m "Add the ownership split in code: install defaults, seed only when absent

~/.config belongs to the user and is never overwritten. Tested explicitly,
because this is the contract everything else in the config layer rests on."
```

---

## Task 5: Default configuration files

**Files:**
- Create: `config/hypr/hyprland.conf`
- Create: `config/foot/foot.ini`

**Interfaces:**
- Consumes: nothing.
- Produces: the tree `aw_install_defaults` copies. Relative paths `hypr/hyprland.conf` and `foot/foot.ini` are what Task 6 seeds.

- [ ] **Step 1: Write `config/hypr/hyprland.conf`**

```
# Archwright default Hyprland configuration.
#
# This file is seeded into ~/.config/hypr/ on first install and is then YOURS -
# updates never overwrite it. The package-owned original lives at
# /usr/share/archwright/default-config/hypr/hyprland.conf if you want to
# compare or start over.

# Take whatever the display offers. Real hardware and VMs both work.
monitor = , preferred, auto, 1

# --- Session environment -----------------------------------------------------
# Reproduced from docs/research-extract.md section 1. These are the small facts
# that otherwise take weeks to rediscover.
#
# XDG_CURRENT_DESKTOP is what makes screen sharing work in Meet and Discord.
# MOZ_ENABLE_WAYLAND matters here because Archwright defaults to Firefox.
env = GDK_BACKEND,wayland,x11,*
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_QPA_PLATFORMTHEME,gtk3
env = MOZ_ENABLE_WAYLAND,1
env = ELECTRON_OZONE_PLATFORM_HINT,wayland
env = OZONE_PLATFORM,wayland
env = XDG_SESSION_TYPE,wayland
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_DESKTOP,Hyprland
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

xwayland {
    # Without this, X11 clients are blurry on scaled displays.
    force_zero_scaling = true
}

# --- Autostart ---------------------------------------------------------------
# The import-environment / dbus-update-activation-environment pair MUST run
# before any session service. It is the documented fix for slow application
# launches: systemd user services and D-Bus activation do not inherit the
# session environment on their own. See research-extract section 2.
exec-once = systemctl --user import-environment $(env | cut -d'=' -f 1)
exec-once = dbus-update-activation-environment --systemd --all

# --- Look and feel -----------------------------------------------------------
# Square corners, no blur, no shadows. Decided, not configured.
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    layout = dwindle
}

decoration {
    rounding = 0
    shadow {
        enabled = false
    }
    blur {
        enabled = false
    }
}

dwindle {
    preserve_split = true
    force_split = 2
}

animations {
    enabled = true
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    # Focus follows the window, and the cursor follows the focus.
    focus_on_activate = true
}

# --- Input -------------------------------------------------------------------
input {
    kb_layout = us
    follow_mouse = 1
}

# --- Keybinds ----------------------------------------------------------------
# Super is the centre of everything.
$mod = SUPER

bind = $mod, Return, exec, foot
bind = $mod, Q, killactive,
bind = $mod, W, killactive,
bind = $mod SHIFT, E, exit,
bind = $mod, F, fullscreen, 0
bind = $mod, T, togglefloating,

bind = $mod, left,  movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up,    movefocus, u
bind = $mod, down,  movefocus, d

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4

bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
```

- [ ] **Step 2: Write `config/foot/foot.ini`**

```
# Archwright default terminal configuration.
# Seeded into ~/.config/foot/ on first install; yours thereafter.

font=JetBrainsMono Nerd Font:size=11
pad=8x8

[cursor]
style=beam

[scrollback]
lines=10000
```

- [ ] **Step 3: Commit**

```bash
git add config/
git commit -m "Add default Hyprland and foot configuration

The environment block and the import-environment autostart pair are taken from
the research extract verbatim - they are the accumulated small facts, not
preferences."
```

---

## Task 6: The session phase

**Files:**
- Create: `lib/40-session.sh`
- Modify: `install.sh` (register the phase)
- Modify: `test/vm/drive_vm.py` (accept `session` as a phase name)

**Interfaces:**
- Consumes: `aw_install_defaults`, `aw_seed_config`, `aw_run_in_chroot`, `AW_USERNAME`, `AW_AUTOLOGIN`.
- Produces: `aw_session()`. After it, greetd is enabled and configured, the user's `~/.config/hypr/hyprland.conf` and `~/.config/foot/foot.ini` exist, and pipewire/wireplumber user services are enabled.

- [ ] **Step 1: Write `lib/40-session.sh`**

```bash
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

  aw_log info "enabling session services"
  aw_run_in_chroot "systemctl enable greetd.service" \
    || aw_die "could not enable greetd"

  # PipeWire and WirePlumber are user services: enable them for the user, not
  # system-wide. `systemctl --user --global` sets the default for every user
  # without needing a live session to talk to.
  aw_run_in_chroot "systemctl --global enable pipewire.service pipewire-pulse.service wireplumber.service" \
    || aw_die "could not enable the audio user services"

  # Graphical target for the user session: uwsm wires Hyprland into it.
  aw_log info "session phase complete"
}
```

- [ ] **Step 2: Register the phase in `install.sh`**

Add to the phase validation `case`:

```bash
  ''|preflight|disk|base|boot|session) ;;
```

And after the `run_phase boot` line:

```bash
run_phase session   40-session.sh
```

- [ ] **Step 3: Allow `session` as a driver phase name**

In `test/vm/drive_vm.py`, in `phase_boot`, extend the phase tuple:

```python
        for phase, timeout in (("preflight", 300), ("disk", 900),
                               ("base", 2400), ("boot", 2400),
                               ("session", 1200)):
```

and in `phase_all`, the same:

```python
        for phase, timeout in (("preflight", 300), ("disk", 900),
                               ("base", 2400), ("boot", 2400),
                               ("session", 1200)):
```

- [ ] **Step 4: Add in-target checks to `phase_boot`**

In `test/vm/drive_vm.py`, append to the `check_guest(ser, [...], "boot")` list:

```python
            ("arch-chroot /mnt systemctl is-enabled greetd.service", "enabled"),
            ("grep -c 'tuigreet' /mnt/etc/greetd/config.toml", "1"),
            ("grep -c 'initial_session' /mnt/etc/greetd/config.toml", "1"),
            ("test -f /mnt/home/test/.config/hypr/hyprland.conf && echo HYPRCFG-OK",
             "HYPRCFG-OK"),
            ("test -f /mnt/usr/share/archwright/default-config/hypr/hyprland.conf"
             " && echo DEFAULTS-OK", "DEFAULTS-OK"),
            ("stat -c %U /mnt/home/test/.config/hypr/hyprland.conf", "test"),
```

- [ ] **Step 5: Run the phase**

Run:

```
wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash test/vm-install.sh --phase boot'
```

Expected: `PASS: bootloader, initramfs and snapper are configured in the target`
with the six new checks reported `ok`. This run installs ~17 extra packages, so
allow 5–10 minutes.

- [ ] **Step 6: Lint and commit**

```bash
bash test/lint.sh
git add lib/40-session.sh install.sh test/vm/drive_vm.py
git commit -m "Add the session phase: greetd, uwsm, Hyprland config

Configuration only - packages come from the manifest via pacstrap. User config
is seeded under the ownership split and is never overwritten afterwards."
```

---

## Task 7: The gate — a real Hyprland session after reboot

**Files:**
- Modify: `test/vm/assertions.sh`

**Interfaces:**
- Consumes: the installed system.
- Produces: the eight milestone 2 gate assertions.

- [ ] **Step 1: Add the assertions**

In `test/vm/assertions.sh`, immediately before the snapshot-entry block at the
end, add:

```bash
# --- Milestone 2: the session stack -----------------------------------------
#
# Hyprland runs in the user's session, not this one, so these look at it from
# the outside: the process, its socket, and hyprctl pointed at the right
# runtime directory.
AW_UID="$(id -u "${SUDO_USER:-$USER}" 2>/dev/null || echo 1000)"
AW_XDG="/run/user/$AW_UID"
hyprctl_user() {
  runuser -u "${SUDO_USER:-$USER}" -- \
    env XDG_RUNTIME_DIR="$AW_XDG" hyprctl "$@"
}

check "greetd is enabled"           sh -c 'systemctl is-enabled greetd.service | grep -qx enabled'
check "greetd is active"            systemctl is-active --quiet greetd.service
check "greetd uses tuigreet"        sh -c 'grep -q tuigreet /etc/greetd/config.toml'
check "Hyprland is running"         pgrep -x Hyprland
check "the wayland socket exists"   sh -c 'ls '"$AW_XDG"'/wayland-* >/dev/null 2>&1'
check "hyprctl answers"             sh -c 'hyprctl_user version | grep -qi hyprland'
check "a monitor is present"        sh -c 'hyprctl_user monitors | grep -qE "^Monitor "'
check "the monitor has a mode"      sh -c 'hyprctl_user monitors | grep -qE "[0-9]+x[0-9]+@"'
check "pipewire is running"         sh -c 'pgrep -x pipewire >/dev/null'
check "wireplumber is running"      sh -c 'pgrep -x wireplumber >/dev/null'
check "the hyprland portal runs"    sh -c 'pgrep -f xdg-desktop-portal-hyprland >/dev/null'
check "user hyprland.conf seeded"   sh -c 'test -f /home/"${SUDO_USER:-$USER}"/.config/hypr/hyprland.conf'
```

- [ ] **Step 2: Run the full gate**

Run:

```
wsl -d Ubuntu -e bash -c 'cd /mnt/e/data/dev/archwright && bash test/vm-install.sh --phase all'
```

Expected: `ASSERTIONS-PASSED` then `PASS: milestone 1 gate met`.

**Expect this to fail the first time.** Likely failure points, in order:

1. **The session never starts.** Check `journalctl -u greetd` in the guest. The
   most common cause is `uwsm start -- hyprland.desktop` not finding the desktop
   file — verify `/usr/share/wayland-sessions/hyprland.desktop` exists.
2. **Hyprland starts and immediately exits.** Almost always the DRM device.
   Confirm `/dev/dri/renderD128` exists in the *installed* system (Task 1 proved
   it in the live ISO, which has different modules loaded).
3. **`hyprctl` cannot find the instance.** `XDG_RUNTIME_DIR` is wrong, or the
   assertion is running before the session has come up — add a bounded wait
   rather than a bare `sleep`.
4. **Audio services not running.** `systemctl --global enable` only takes effect
   for sessions started *after* it ran; confirm with
   `systemctl --user --machine=test@ status pipewire`.

- [ ] **Step 3: Update the gate description**

In `test/vm/drive_vm.py`, change the final log line of `phase_all` from
`"PASS: milestone 1 gate met"` to:

```python
        log("PASS: milestone 2 gate met - encrypted base plus a live Hyprland session")
```

- [ ] **Step 4: Commit and tag**

```bash
bash test/lint.sh && bash test/run-unit.sh
git add test/vm/assertions.sh test/vm/drive_vm.py
git commit -m "Assert a real Hyprland session on the rebooted system"
git tag -a m2-verified -m "Milestone 2: greetd + uwsm + Hyprland session verified in QEMU"
```

---

## Task 8: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/decisions.md`

- [ ] **Step 1: Update the README status block**

Replace the "Status: milestone 1 of 7" block with:

```markdown
## ⚠️ Status: milestone 2 of 7

**What works today:** a bootable, fully encrypted, snapshot-capable Arch system
that starts a **Hyprland desktop**. UEFI, LUKS2, btrfs subvolumes, Limine with
per-snapshot boot entries, snapper, a deny-all firewall — and a graphical
session with a terminal, audio and desktop portals.

**What does not exist yet:** a status bar, notifications, an app launcher or a
lock screen (milestone 3); applications beyond a terminal (milestone 4); the AI
tooling (milestone 5). `Super + Return` opens a terminal, `Super + Q` closes a
window, `Super + Shift + E` exits the session.
```

Add to the answer-file example in step 6:

```
AUTOLOGIN=0                # 1 skips the login prompt entirely
```

- [ ] **Step 2: Append to the implementation log**

Add to `docs/decisions.md`:

```markdown
### L22 — The test VM gets one virtio GPU with a render node
Milestone 2 gates on a real Hyprland session, and Hyprland needs DRM with EGL.
Probing found QEMU's default bochs display provides a card and a connected
connector but **no render node**, so Hyprland would have silently fallen back to
software rendering and the harness would have been testing a path no real
machine takes. `-vga none -device virtio-gpu-pci` gives exactly one card, one
connector and `renderD128` — the shape of a real single-GPU machine.
**Trigger:** deliberate probe before planning, after the UKI lesson.

### L23 — `AUTOLOGIN` is a real option, not a test hack
greetd's tuigreet runs on VT1 and the harness only has a serial console, so the
automated gate cannot type a password. Rather than a test-only branch, autologin
is a supported answer-file option — reasonable on a single-user laptop — which
the test enables. The gate also asserts the interactive tuigreet path is
configured, so the shipped default is not left unverified.
**Trigger:** the harness could not exercise the shipped login path.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/decisions.md
git commit -m "Document milestone 2: Hyprland session, AUTOLOGIN, GPU decision"
```

---

## Self-review notes

**Spec coverage.** Spec §3's session rows — greetd + tuigreet, uwsm → Hyprland,
pipewire/wireplumber, foot, JetBrainsMono Nerd Font — are Task 2 and Task 6.
§3's session environment and autostart pair are Task 5's `hyprland.conf`, taken
from research-extract §1 and §2. §5's ownership split is Task 4, tested
explicitly. §4's `lib/40-desktop.sh` is named `lib/40-session.sh` here, because
this milestone delivers the *session*, not the desktop furniture — the shell
layer (waybar, mako, walker) is milestone 3 and will land behind
`archwright-shell.target` per D3.

**Deliberately out of milestone 2:** the shell swap boundary and its systemd
target (nothing to put in it yet), theming, the `archwright` CLI, hardware
scripts, and Plymouth.

**Known risk.** Task 7's gate is the first assertion that depends on a *live
graphical session* rather than files on disk, so it is timing-sensitive in a way
nothing before it has been. If it proves flaky, the fix is a bounded wait for
the Hyprland socket to appear, not a fixed `sleep`.
