#!/usr/bin/env bash
# The ownership split, in code.
#
#   /usr/share/archwright/default-config/  ours, package-owned, replaced on update
#   ~/.config/                             the user's, NEVER overwritten
#
# Retrofitting this contract is painful, so it is established the first time any
# configuration is installed. See section 5 of the spec.

# Copy the repo's config/ tree into the target as package-owned defaults.
aw_install_defaults() {
  local src="$1" target_root="$2"
  local dest="$target_root/usr/share/archwright/default-config"

  if [ ! -d "$src" ]; then
    aw_log error "no config tree to install from: $src"
    return 1
  fi

  install -d -m 0755 "$dest" || return 1
  ( cd "$src" && find . -type d -exec install -d -m 0755 "$dest/{}" \; ) || return 1
  ( cd "$src" && find . -type f -exec install -m 0644 "{}" "$dest/{}" \; ) || return 1
  return 0
}

# Seed ONE user config file from the defaults, only when it is absent.
#
#   0 = copied    1 = left an existing file alone    2 = error
#
# Never overwrites and never writes a .bak: this is first-install seeding, not
# a restore. A user who has edited their config keeps it, full stop. The
# distinct return codes exist so a caller can tell "did nothing" from "failed"
# - collapsing them is how a silent no-op becomes a mystery later.
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
