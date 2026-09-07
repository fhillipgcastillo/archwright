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

# walker is AUR-only and must never appear here: building AUR packages at
# install time is what D2 removed.
if printf '%s
' "$pkgs" | grep -qx "walker"; then
  _fail "core.packages" "walker is AUR-only and cannot be pacstrapped"
else _pass; fi

finish_tests
