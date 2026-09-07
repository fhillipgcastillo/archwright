#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$ROOT/lib/manifest.sh"

tmp="$(mktemp -d)"

# Fixture written with printf so the trailing whitespace on 'beta' and the
# tabs in the tsv are explicit rather than invisible.
printf '%s\n' \
  '# a comment' \
  '## Group: one' \
  'alpha' \
  '' \
  'beta   ' \
  '## Group: two' \
  'gamma' > "$tmp/p.packages"

got="$(aw_manifest_packages "$tmp/p.packages" | tr '\n' ',')"
assert_eq "$got" "alpha,beta,gamma," "packages: comments, blanks and group headers stripped"

printf '# header comment\n@\t/\tcompress=zstd:1,noatime\n@home\t/home\tcompress=zstd:1,noatime\n' \
  > "$tmp/s.tsv"

got="$(aw_manifest_subvolumes "$tmp/s.tsv" | wc -l | tr -d ' ')"
assert_eq "$got" "2" "subvolumes: two data rows"

first="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f1)"
assert_eq "$first" "@" "subvolumes: first field is the subvolume name"

third="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f3)"
assert_eq "$third" "compress=zstd:1,noatime" "subvolumes: third field is mount options"

assert_fails aw_manifest_packages "$tmp/does-not-exist" "missing manifest fails loudly"

# ---------------------------------------------------------------------------
# The real shipped manifests: assert STRUCTURE and CONTENT, never row counts.
#
# Adversarial review demonstrated that a row-count assertion is worthless in
# both directions: it breaks when someone legitimately adds a subvolume, and
# it stays green when the file is corrupted (tabs replaced by spaces, or every
# package name replaced with junk).
# ---------------------------------------------------------------------------

pkgs="$(aw_manifest_packages "$ROOT/manifest/core.packages")"
for required in base linux linux-firmware btrfs-progs snapper limine efibootmgr                 mkinitcpio networkmanager sudo; do
  if printf '%s
' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "required package missing: $required"; fi
done

# No entry may contain whitespace - that would mean a comment or header leaked
# through and pacstrap would be handed a bogus argument.
if printf '%s
' "$pkgs" | grep -q '[[:space:]]'; then
  _fail "core.packages" "an entry contains whitespace; parsing leaked a comment or header"
else _pass; fi

# No entry may start with '#'.
if printf '%s
' "$pkgs" | grep -q '^#'; then
  _fail "core.packages" "a comment leaked through as a package"
else _pass; fi

subs="$(aw_manifest_subvolumes "$ROOT/manifest/subvolumes.tsv")"

# Every row must be exactly three TAB-separated fields. Spaces instead of tabs
# is the corruption that silently breaks the mount tree.
if printf '%s
' "$subs" | awk -F'	' 'NF != 3 { exit 1 }'; then _pass
else _fail "subvolumes.tsv" "a row does not have exactly 3 tab-separated fields"; fi

# The root subvolume must exist and must be named '@' - lib/10-disk.sh mounts
# the row whose mountpoint is '/' first, and everything else nests under it.
root_subvol="$(printf '%s
' "$subs" | awk -F'	' '$2 == "/" { print $1 }')"
assert_eq "$root_subvol" "@" "subvolumes.tsv defines exactly one root subvolume named @"

# Snapshots need their own subvolume or snapper rollback cannot work.
snap="$(printf '%s
' "$subs" | awk -F'	' '$2 == "/.snapshots" { print $1 }')"
assert_eq "$snap" "@snapshots" "subvolumes.tsv mounts @snapshots at /.snapshots"

# Every mountpoint must be absolute and unique.
if printf '%s
' "$subs" | awk -F'	' '$2 !~ /^\// { exit 1 }'; then _pass
else _fail "subvolumes.tsv" "a mountpoint is not absolute"; fi

dupes="$(printf '%s
' "$subs" | cut -f2 | sort | uniq -d)"
assert_eq "$dupes" "" "subvolumes.tsv has no duplicate mountpoints"

rm -rf "$tmp"

# Milestone 2: the session stack must be present in core, because the base
# phase pacstraps core and nothing else installs packages.
for required in hyprland uwsm greetd greetd-tuigreet xdg-desktop-portal-hyprland                 pipewire wireplumber polkit mesa foot; do
  if printf '%s
' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "session package missing: $required"; fi
done

# Milestone 3: the shell layer.
for required in waybar mako fuzzel swaybg hypridle hyprlock hyprpolkitagent                 wl-clipboard libnotify; do
  if printf '%s
' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "shell package missing: $required"; fi
done

# Nothing should be installed that nothing configures. plymouth was shipped
# unused for three milestones; the branded boot splash belongs to the theming
# milestone, where it can be done properly and tested.
if printf '%s
' "$pkgs" | grep -qx "plymouth"; then
  _fail "core.packages" "plymouth is installed but nothing configures it"
else _pass; fi

# walker is AUR-only and must never appear here: building AUR packages at
# install time is what D2 removed.
if printf '%s
' "$pkgs" | grep -qx "walker"; then
  _fail "core.packages" "walker is AUR-only and cannot be pacstrapped"
else _pass; fi

# --- group parsing (milestone 4) --------------------------------------------
gtmp="$(mktemp -d)"
printf '%s
'   '# a comment'   '## Group: office'   'libreoffice-fresh'   ''   '## Group: gaming'   '## Requires: multilib'   'steam'   'lutris' > "$gtmp/e.packages"

assert_eq "$(aw_manifest_groups "$gtmp/e.packages" | tr '
' ',')" "office,gaming,"   "groups are listed in file order"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" office | tr '
' ',')" "libreoffice-fresh,"   "a group yields only its own packages"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" gaming | tr '
' ',')" "steam,lutris,"   "a later group is bounded by the next header"
assert_eq "$(aw_manifest_group_requires "$gtmp/e.packages" gaming)" "multilib"   "a group's requirements are read"
assert_eq "$(aw_manifest_group_requires "$gtmp/e.packages" office)" ""   "a group with no requirements yields nothing"
assert_eq "$(aw_manifest_group "$gtmp/e.packages" nosuch)" ""   "an unknown group yields nothing"
# A Requires: directive must never be mistaken for a package name.
if aw_manifest_group "$gtmp/e.packages" gaming | grep -q 'Requires'; then
  _fail "group parsing" "a Requires directive leaked in as a package"
else _pass; fi
rm -rf "$gtmp"

# --- the shipped extras manifest (milestone 4) ------------------------------
extras="$ROOT/manifest/extras.packages"
got="$(aw_manifest_groups "$extras" | tr '
' ',')"
assert_eq "$got" "office,media,containers,browsers,ai-local,gaming,desktop-tools,theming-gui,printing,"   "extras groups are the documented set"
assert_eq "$(aw_manifest_group_requires "$extras" gaming)" "multilib"   "gaming declares its multilib requirement"
for g in office media containers browsers ai-local; do
  if [ -n "$(aw_manifest_group_requires "$extras" "$g")" ]; then
    _fail "extras" "group $g should need no extra repository"
  else _pass; fi
done
# Every group must actually contain packages - an empty group would install
# nothing while appearing to succeed.
for g in $(aw_manifest_groups "$extras"); do
  if [ -n "$(aw_manifest_group "$extras" "$g")" ]; then _pass
  else _fail "extras" "group $g is empty"; fi
done

# Core gains the applications, and vim is gone in favour of neovim.
for required in firefox neovim nautilus imv mpv evince xdg-utils                 eza bat fd fzf lazygit btop; do
  if printf '%s
' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "application missing: $required"; fi
done
if printf '%s
' "$pkgs" | grep -qx "vim"; then
  _fail "core.packages" "vim ships alongside neovim - pick one (spec section 3)"
else _pass; fi

# --- the agent manifest (milestone 5) ----------------------------------------
atmp="$(mktemp -d)"
printf '%s\n' \
  '# lazy agent launchers' \
  '' \
  'claude	npm:@anthropic-ai/claude-code	claude' \
  'codex	npm:@openai/codex	codex' > "$atmp/a.tsv"

assert_eq "$(aw_manifest_agents "$atmp/a.tsv" | wc -l | tr -d ' ')" "2" \
  "agents: two data rows"
assert_eq "$(aw_manifest_agents "$atmp/a.tsv" | head -1 | cut -f1)" "claude" \
  "agents: first field is the command name"
assert_eq "$(aw_manifest_agents "$atmp/a.tsv" | head -1 | cut -f2)" "npm:@anthropic-ai/claude-code" \
  "agents: second field is the mise spec, scope and all"
assert_eq "$(aw_manifest_agents "$atmp/a.tsv" | head -1 | cut -f3)" "claude" \
  "agents: third field is the executable inside the package"
if aw_manifest_agents "$atmp/a.tsv" | grep -q 'lazy agent launchers'; then
  _fail "agents" "a comment line leaked into the data"
else _pass; fi
assert_fails aw_manifest_agents "$atmp/does-not-exist" "missing agent manifest fails loudly"
rm -rf "$atmp"

# The shipped manifest. Structural assertions only - a row count would pass on
# corrupted data.
agents="$ROOT/manifest/agents.tsv"
while IFS=$'\t' read -r a_name a_spec a_bin a_extra; do
  if [ -n "${a_extra:-}" ]; then
    _fail "agents.tsv" "row [$a_name] has more than three fields"
  else _pass; fi
  if printf '%s' "$a_name" | grep -qxE '[a-z][a-z0-9-]*'; then _pass
  else _fail "agents.tsv" "bad command name: [$a_name]"; fi
  # The spec must name a backend explicitly. A bare package name makes mise
  # guess which registry to use, and the guess is not stable.
  if printf '%s' "$a_spec" | grep -q '^[a-z][a-z0-9]*:'; then _pass
  else _fail "agents.tsv" "spec [$a_spec] has no backend prefix"; fi
  if [ -n "$a_bin" ]; then _pass
  else _fail "agents.tsv" "row [$a_name] names no executable"; fi
done < <(aw_manifest_agents "$agents")

assert_eq "$(aw_manifest_agents "$agents" | cut -f1 | sort | uniq -d)" "" \
  "agents.tsv: no duplicate command names"

# Each shipped agent, by name. Written out rather than counted: a row silently
# dropped from the manifest is the failure this catches.
for required in claude codex opencode crush pi; do
  if aw_manifest_agents "$agents" | cut -f1 | grep -qx "$required"; then _pass
  else _fail "agents.tsv" "agent missing: $required"; fi
done

# D17 (revised): pi ships from @earendil-works/pi-coding-agent. The first
# search for it found @mariozechner/pi-agent, which publishes no bin at all,
# and concluded no pi CLI existed. Pin the package so that mistake cannot
# quietly return.
assert_eq "$(aw_manifest_agents "$agents" | awk -F'\t' '$1 == "pi" { print $2 }')" \
  "npm:@earendil-works/pi-coding-agent" \
  "pi resolves to the package that actually ships the pi command"

# D18: gh is packaged by Arch. Stubs exist only for what Arch does not package.
if aw_manifest_agents "$agents" | cut -f1 | grep -qx 'gh'; then
  _fail "agents.tsv" "gh belongs in core.packages as github-cli - see D18"
else _pass; fi

# Milestone 5 adds mise and the GitHub CLI to core.
for required in mise github-cli; do
  if printf '%s\n' "$pkgs" | grep -qx "$required"; then _pass
  else _fail "core.packages" "AI layer package missing: $required"; fi
done

finish_tests
