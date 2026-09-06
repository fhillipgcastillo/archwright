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

# NEVER overwrites. This is the ownership split: ~/.config belongs to the user,
# and an update that clobbers their edits is the failure this guards against.
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
mkdir -p "$src/foot"
printf 'font=x\n' > "$src/foot/foot.ini"
aw_install_defaults "$src" "$troot"
assert_eq "$?" "0" "installing defaults succeeds"
if [ -f "$troot/usr/share/archwright/default-config/hypr/hyprland.conf" ]; then _pass
else _fail "install_defaults" "hypr default was not installed"; fi
if [ -f "$troot/usr/share/archwright/default-config/foot/foot.ini" ]; then _pass
else _fail "install_defaults" "foot default was not installed"; fi

# Defaults are package-owned and world-readable, not user-writable.
assert_eq "$(stat -c %a "$troot/usr/share/archwright/default-config/hypr/hyprland.conf")" \
  "644" "installed defaults are mode 0644"

# A missing source tree is an error rather than an empty success.
aw_install_defaults "$tmp/no-such-tree" "$troot"
assert_eq "$?" "1" "installing from a missing tree is an error"

rm -rf "$tmp"
finish_tests
