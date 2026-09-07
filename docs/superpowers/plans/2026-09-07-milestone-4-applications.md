# Archwright Milestone 4 — Applications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the machine becomes usable for real work — a browser, editor, file manager, image/video/PDF viewers and the CLI staples, all with sensible default handlers — plus an **opt-in extras** list the installer offers.

**Architecture:** decision D7's two tiers. `manifest/core.packages` gains what everyone gets; a new `manifest/extras.packages` is grouped by job, and an `EXTRAS=` answer key selects groups by name. A new phase installs the selected groups and writes system-wide XDG default handlers so double-clicking a file opens the right thing.

**Tech Stack:** all Arch official repositories. One group (`gaming`) requires the `multilib` repository, which the installer enables **only if that group is selected**.

## Global Constraints

- **Installer code never runs on the development host.** Only inside the QEMU VM.
- **No hardcoded package lists in `lib/`.** Packages come from `manifest/`, including which groups need multilib.
- **Ownership split is absolute.** `/usr/share/archwright/` ours, `~/.config/` the user's, state in `~/.local/state/archwright/`.
- **`install.sh` runs under `set -e`** — capture non-zero returns with `|| rc=$?` (L18).
- **Never generate shell code through Python heredocs** (L19).
- **Assertions needing shell state must be functions, not `sh -c` strings** (L25).
- **Do not assert a D-Bus-activated service is running** (L27).
- **Do not ship a package nothing configures or uses** (L36).
- Every script `set -euo pipefail`, clean under `bash test/lint.sh`.

## Milestone 4 gate

`bash test/vm-install.sh --phase all` passes, plus on the rebooted system:

1. Firefox, Neovim, Nautilus, imv, mpv and Evince are installed.
2. The CLI staples are installed.
3. XDG default handlers resolve: `xdg-mime query default` returns the expected `.desktop` for html, png, mp4, pdf and directories.
4. The extras groups **selected in the answer file** are installed.
5. The extras groups **not** selected are **absent** — proving the selection is real rather than "install everything".
6. `multilib` is **not** enabled when no selected group needs it.

## Decisions taken before planning

**Every package verified present in official repositories**, and every `.desktop`
filename verified against the package file lists rather than guessed — the two
checks that would have caught the Limine problem a milestone earlier.

**`gaming` requires `multilib`, and that stays opt-in.** Steam is the only
package here outside `extra`. Enabling `multilib` pulls in a whole 32-bit
package set, so it happens only when a selected group declares it needs it. The
requirement is declared **in the manifest**, not hardcoded in `lib/`, so the
rule stays where the package data is.

**`vim` is dropped from core.** Neovim is the decided editor (spec §3); shipping
both is exactly the "installed but superseded" pattern L36 removed plymouth for.
`nano` stays as the fallback for anyone who cannot drive a modal editor when
something is broken.

---

## File structure

| File | Responsibility |
|---|---|
| `manifest/extras.packages` | Opt-in groups, with a `## Requires:` directive where a group needs a non-default repository |
| `manifest/core.packages` | Gains the application and CLI-staple groups |
| `lib/manifest.sh` | Gains group parsing: list groups, list a group's packages, list a group's requirements |
| `lib/60-apps.sh` | Phase 7. Installs selected extras, enables multilib only if needed, writes XDG defaults |
| `config/xdg/mimeapps.list` | System-wide default handlers |
| `lib/answers.sh` | `EXTRAS` key |
| `test/unit/test_manifest.sh` | Group parsing tests |

---

## Task 1: Group parsing in the manifest reader

**Files:** `lib/manifest.sh`, `manifest/extras.packages`, `test/unit/test_manifest.sh`

**Interfaces:**
- Produces `aw_manifest_groups(file)` → group names, one per line.
- Produces `aw_manifest_group(file, name)` → that group's packages.
- Produces `aw_manifest_group_requires(file, name)` → that group's requirements, one per line (empty when none).

- [ ] **Step 1: Write the failing test**

Append to `test/unit/test_manifest.sh` before `finish_tests`:

```bash
# --- group parsing (milestone 4) --------------------------------------------
gtmp="$(mktemp -d)"
printf '%s\n' \
  '# a comment' \
  '## Group: office' \
  'libreoffice-fresh' \
  '' \
  '## Group: gaming' \
  '## Requires: multilib' \
  'steam' \
  'lutris' > "$gtmp/e.packages"

assert_eq "$(aw_manifest_groups "$gtmp/e.packages" | tr '\n' ',')" "office,gaming," \
  "groups are listed in file order"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" office | tr '\n' ',')" "libreoffice-fresh," \
  "a group yields only its own packages"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" gaming | tr '\n' ',')" "steam,lutris," \
  "a later group is bounded by the next header"
assert_eq "$(aw_manifest_group_requires "$gtmp/e.packages" gaming)" "multilib" \
  "a group's requirements are read"
assert_eq "$(aw_manifest_group_requires "$gtmp/e.packages" office)" "" \
  "a group with no requirements yields nothing"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" nosuch)" "" \
  "an unknown group yields nothing"
# A Requires: directive must never be mistaken for a package name.
if aw_manifest_group "$gtmp/e.packages" gaming | grep -q 'Requires'; then
  _fail "group parsing" "a Requires directive leaked in as a package"
else _pass; fi
rm -rf "$gtmp"
```

- [ ] **Step 2: Run it, watch it fail**

Run: `bash test/unit/test_manifest.sh`
Expected: `aw_manifest_groups: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/manifest.sh`:

```bash
# Group-aware readers for manifest/extras.packages.
#
# The file is grouped by job:
#
#   ## Group: gaming
#   ## Requires: multilib
#   steam
#
# A '## Requires:' directive states that the group needs something beyond the
# default repositories. It lives in the manifest rather than in lib/ so package
# facts stay with the package data - the same rule that keeps package names out
# of lib/.

aw_manifest_groups() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  sed -n 's/^##[[:space:]]*Group:[[:space:]]*//p' "$file"
}

aw_manifest_group() {
  local file="$1" want="$2"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  awk -v want="$want" '
    /^##[[:space:]]*Group:/ {
      sub(/^##[[:space:]]*Group:[[:space:]]*/, "")
      current = $0
      next
    }
    /^##[[:space:]]*Requires:/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    current == want { print }
  ' "$file"
}

aw_manifest_group_requires() {
  local file="$1" want="$2"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  awk -v want="$want" '
    /^##[[:space:]]*Group:/ {
      sub(/^##[[:space:]]*Group:[[:space:]]*/, "")
      current = $0
      next
    }
    current == want && /^##[[:space:]]*Requires:/ {
      sub(/^##[[:space:]]*Requires:[[:space:]]*/, "")
      print
    }
  ' "$file"
}
```

- [ ] **Step 4: Verify and commit**

```bash
bash test/run-unit.sh
git add lib/manifest.sh test/unit/test_manifest.sh
git commit -m "Add group-aware manifest parsing for the extras tier"
```

---

## Task 2: The manifests

**Files:** `manifest/extras.packages`, `manifest/core.packages`, `test/unit/test_manifest.sh`

- [ ] **Step 1: Write `manifest/extras.packages`**

```
# Opt-in application groups. Selected by name in the answer file:
#
#   EXTRAS=office,containers
#
# Nothing here is installed unless asked for. A '## Requires:' line states that
# a group needs something beyond Arch's default repositories, and the installer
# enables it only when that group is chosen.

## Group: office
libreoffice-fresh

## Group: media
obs-studio
kdenlive
gimp

## Group: containers
docker
docker-compose
lazydocker

## Group: browsers
chromium

## Group: ai-local
ollama

## Group: gaming
## Requires: multilib
steam
lutris
```

- [ ] **Step 2: Extend `manifest/core.packages`**

Append:

```
## Group: applications
firefox
neovim
nautilus
gvfs
imv
mpv
evince
xdg-utils

## Group: cli-tools
eza
bat
fd
fzf
zoxide
lazygit
btop
fastfetch
tldr
jq
unzip
```

And remove `vim` from the `cli-staples` group — Neovim is the decided editor,
and shipping both is the pattern L36 removed plymouth for.

- [ ] **Step 3: Assert the shipped manifests**

Append to `test/unit/test_manifest.sh` before `finish_tests`:

```bash
# The shipped extras manifest.
extras="$ROOT/manifest/extras.packages"
got="$(aw_manifest_groups "$extras" | tr '\n' ',')"
assert_eq "$got" "office,media,containers,browsers,ai-local,gaming," \
  "extras groups are the documented set"
assert_eq "$(aw_manifest_group_requires "$extras" gaming)" "multilib" \
  "gaming declares its multilib requirement"
for g in office media containers browsers ai-local; do
  if [ -n "$(aw_manifest_group_requires "$extras" "$g")" ]; then
    _fail "extras" "group $g should need no extra repository"
  else _pass; fi
done

# Core gains the applications, and vim is gone in favour of neovim.
for required in firefox neovim nautilus imv mpv evince xdg-utils \
                eza bat fd fzf lazygit btop; do
  if printf '%s\n' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "application missing: $required"; fi
done
if printf '%s\n' "$pkgs" | grep -qx "vim"; then
  _fail "core.packages" "vim ships alongside neovim - pick one (spec section 3)"
else _pass; fi
```

- [ ] **Step 4: Verify and commit**

```bash
bash test/run-unit.sh
git add manifest test/unit/test_manifest.sh
git commit -m "Add the applications core and the opt-in extras manifest"
```

---

## Task 3: The `EXTRAS` answer key

**Files:** `lib/answers.sh`, `test/unit/test_answers.sh`, `test/vm/answers.example.conf`

**Interfaces:** produces `AW_EXTRAS`, a comma-separated list, default empty.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/test_answers.sh` before `rm -rf "$tmp"`:

```bash
# EXTRAS selects opt-in application groups by name.
mkbase 'EXTRAS=office,containers'
assert_eq "$AW_EXTRAS" "office,containers" "extras list parsed"
if aw_answers_validate 2>/dev/null; then _pass
else _fail "extras" "a valid extras list should validate"; fi

mkbase 'EXTRAS='
assert_eq "$AW_EXTRAS" "" "extras defaults to empty"
if aw_answers_validate 2>/dev/null; then _pass
else _fail "extras" "an empty extras list is valid"; fi

# A group name is used to build a filesystem-free lookup, but it still must not
# carry anything that could reach a shell.
mkbase 'EXTRAS=office; rm -rf /'
assert_fails aw_answers_validate "extras with a shell metacharacter is rejected"
mkbase 'EXTRAS=Office'
assert_fails aw_answers_validate "extras group names are lowercase"
```

- [ ] **Step 2: Implement**

In `lib/answers.sh`: add `AW_EXTRAS=""` to `aw_answers_reset`, add
`EXTRAS)          AW_EXTRAS="$value" ;;` to the key `case`, and add to
`aw_answers_validate`:

```bash
  # Empty is valid - most installs want no extras at all - so this is checked
  # only when set.
  if [ -n "$AW_EXTRAS" ]; then
    _aw_check EXTRAS "$AW_EXTRAS" '^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$' \
      'a comma-separated list of lowercase group names' || ok=1
  fi
```

In `test/vm/answers.example.conf`, add:

```
# Opt-in application groups, comma separated. See manifest/extras.packages.
# The test selects a small group so the gate proves selection works without
# downloading an office suite.
EXTRAS=containers
```

- [ ] **Step 3: Verify and commit**

```bash
bash test/run-unit.sh
git add lib/answers.sh test/unit/test_answers.sh test/vm/answers.example.conf
git commit -m "Add the EXTRAS answer key for opt-in application groups"
```

---

## Task 4: XDG default handlers

**Files:** `config/xdg/mimeapps.list`

- [ ] **Step 1: Write it**

Every `.desktop` name below was verified against the Arch package file lists.

```
# Archwright default application handlers, system-wide.
#
# A user's own ~/.config/mimeapps.list takes precedence over this, so changing
# a default never means editing this file - which is the ownership split
# applied to MIME handling.
[Default Applications]
text/html=firefox.desktop
application/xhtml+xml=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
x-scheme-handler/about=firefox.desktop

inode/directory=org.gnome.Nautilus.desktop

image/png=imv.desktop
image/jpeg=imv.desktop
image/gif=imv.desktop
image/webp=imv.desktop

video/mp4=mpv.desktop
video/x-matroska=mpv.desktop
video/webm=mpv.desktop
audio/mpeg=mpv.desktop
audio/flac=mpv.desktop

application/pdf=org.gnome.Evince.desktop

text/plain=nvim.desktop
```

- [ ] **Step 2: Commit**

```bash
git add config/xdg
git commit -m "Add system-wide XDG default handlers"
```

---

## Task 5: The applications phase

**Files:** `lib/60-apps.sh`, `install.sh`, `test/vm/drive_vm.py`

**Interfaces:** `aw_apps()`. After it: selected extras installed, `multilib`
enabled only if a selected group required it, `/etc/xdg/mimeapps.list` in place.

- [ ] **Step 1: Write `lib/60-apps.sh`**

```bash
#!/usr/bin/env bash
# Phase 7: applications.
#
# The core applications arrive with pacstrap in the base phase. This phase
# handles the opt-in half: the extras groups named in the answer file, and the
# default handlers that decide what opens when you double-click a file.

AW_EXTRAS_MANIFEST_REL="manifest/extras.packages"

# Enable a pacman repository that is not on by default. Only ever called
# because a SELECTED group declared it needs one.
_aw_enable_repo() {
  local repo="$1"
  if grep -qE "^\[$repo\]" /mnt/etc/pacman.conf; then
    aw_log info "  [$repo] already enabled"
    return 0
  fi
  aw_log warn "  enabling the [$repo] repository - a selected group requires it"
  printf '\n[%s]\nInclude = /etc/pacman.d/mirrorlist\n' "$repo" >> /mnt/etc/pacman.conf
  aw_run_in_chroot "pacman -Sy" >/dev/null \
    || aw_die "could not sync after enabling [$repo]"
}

aw_apps() {
  local manifest="$AW_ROOT/$AW_EXTRAS_MANIFEST_REL"
  [ -f "$manifest" ] || aw_die "missing $AW_EXTRAS_MANIFEST_REL"

  aw_log info "installing default application handlers"
  install -d -m 0755 /mnt/etc/xdg
  install -m 0644 "$AW_ROOT/config/xdg/mimeapps.list" /mnt/etc/xdg/mimeapps.list \
    || aw_die "could not install the default handler list"

  if [ -z "${AW_EXTRAS:-}" ]; then
    aw_log info "no extras selected"
    aw_log info "applications phase complete"
    return 0
  fi

  # Validate every requested group BEFORE installing anything, so a typo fails
  # immediately rather than half-way through a download.
  local group known packages requires req all_packages=""
  known="$(aw_manifest_groups "$manifest")"
  local IFS_SAVE="$IFS"
  IFS=','
  for group in $AW_EXTRAS; do
    IFS="$IFS_SAVE"
    printf '%s\n' "$known" | grep -qx "$group" \
      || aw_die "unknown extras group '$group'. Available: $(printf '%s' "$known" | tr '\n' ' ')"
    IFS=','
  done
  IFS="$IFS_SAVE"

  IFS=','
  for group in $AW_EXTRAS; do
    IFS="$IFS_SAVE"
    aw_log info "extras group: $group"
    while read -r req; do
      [ -n "$req" ] || continue
      _aw_enable_repo "$req"
    done < <(aw_manifest_group_requires "$manifest" "$group")
    packages="$(aw_manifest_group "$manifest" "$group")"
    [ -n "$packages" ] || aw_die "extras group '$group' contains no packages"
    all_packages="$all_packages $(printf '%s' "$packages" | tr '\n' ' ')"
    IFS=','
  done
  IFS="$IFS_SAVE"

  aw_log info "installing extras:$all_packages"
  # shellcheck disable=SC2086
  # Intentional word splitting: each package is its own argument.
  aw_run_in_chroot "pacman -S --noconfirm --needed $all_packages" \
    || aw_die "could not install the selected extras"

  aw_log info "applications phase complete"
}
```

- [ ] **Step 2: Register the phase**

`install.sh`: add `apps` to the phase `case` and its message, and after
`run_phase shell     50-shell.sh` add `run_phase apps      60-apps.sh`.

- [ ] **Step 3: Driver**

Both phase tuples gain `("apps", 1800)` after `("shell", 900)`.

Append to the boot-phase `check_guest` list:

```python
            # --- apps phase ---
            ("test -f /mnt/etc/xdg/mimeapps.list && echo MIME-OK", "MIME-OK"),
            ("arch-chroot /mnt pacman -Q firefox >/dev/null && echo FF-OK", "FF-OK"),
            ("arch-chroot /mnt pacman -Q docker >/dev/null && echo DOCKER-OK",
             "DOCKER-OK"),
            # Not selected, so it must be absent - this is what proves the
            # selection is real rather than 'install everything'.
            ("arch-chroot /mnt pacman -Q libreoffice-fresh >/dev/null 2>&1"
             " && echo PRESENT || echo ABSENT", "ABSENT"),
            ("grep -c '^\\[multilib\\]' /mnt/etc/pacman.conf || true", "0"),
```

- [ ] **Step 4: Run the phase**

Run: `bash test/vm-install.sh --phase boot`
Expected: PASS with the five new checks `ok`.

- [ ] **Step 5: Lint and commit**

```bash
bash test/lint.sh
git add lib/60-apps.sh install.sh test/vm/drive_vm.py
git commit -m "Add the applications phase: opt-in extras and default handlers"
```

---

## Task 6: The gate

**Files:** `test/vm/assertions.sh`

- [ ] **Step 1: Add the assertions**

Before the snapshot block:

```bash
# --- Milestone 4: applications ----------------------------------------------
check "firefox installed"           test -x /usr/bin/firefox
check "neovim installed"            test -x /usr/bin/nvim
check "nautilus installed"          test -x /usr/bin/nautilus
check "image viewer installed"      test -x /usr/bin/imv
check "video player installed"      test -x /usr/bin/mpv
check "pdf viewer installed"        test -x /usr/bin/evince
check "cli staples installed"       sh -c 'command -v eza bat fd fzf lazygit btop >/dev/null'

# Default handlers actually resolve, rather than the file merely existing.
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
```

- [ ] **Step 2: Run the full gate**

Run: `bash test/vm-install.sh --phase all`

**Likely failures:** `xdg-mime query` needs `xdg-utils` and a desktop database
— if it returns empty, `update-desktop-database` may need running in the apps
phase; Evince's desktop id may differ if the package renames to `papers`.

- [ ] **Step 3: Commit and tag**

```bash
bash test/lint.sh && bash test/run-unit.sh
git add test/vm/assertions.sh
git commit -m "Assert the applications and their default handlers"
git tag -a m4-verified -m "Milestone 4: applications verified in QEMU"
```

---

## Task 7: Documentation

- [ ] **Step 1: README** — status to milestone 4; document `EXTRAS=` in the
answer-file example with the available group names; note that `gaming` enables
`multilib`.

- [ ] **Step 2: `docs/decisions.md`** — add:

- **L38** — extras groups are data in the manifest, including their repository
  requirements, so `lib/` still contains no package facts.
- **L39** — `vim` dropped in favour of `neovim`, per L36's rule.
- **L40** — `multilib` is enabled only when a selected group declares it, and
  the gate asserts it stays off otherwise.

- [ ] **Step 3: Commit**

---

## Self-review notes

**Spec coverage.** D7's two tiers are Tasks 2, 3 and 5. Spec §3's browser,
editor and file-manager choices land in core with matching default handlers.

**Out of scope:** theming (milestone 6), the AI layer (milestone 5), and the
`archwright` CLI.

**Known risk.** The gate installs a real extras group over the network, so a
mirror outage fails the run for reasons unrelated to the code. `containers` was
chosen as the test group because it is small; the package cache makes repeat
runs cheap.
