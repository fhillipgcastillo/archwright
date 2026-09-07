#!/usr/bin/env bash
# Phase 7: applications.
#
# The core applications arrive with pacstrap in the base phase. This phase
# handles the opt-in half: the extras groups named in the answer file, and the
# default handlers that decide what opens when you double-click a file.

AW_EXTRAS_MANIFEST_REL="manifest/extras.packages"

# Enable a pacman repository that is not on by default. Only ever called
# because a SELECTED group declared it needs one - nobody gets 32-bit packages
# they did not ask for.
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
  # xdg-mime resolves against the desktop database; without this the handlers
  # are configured but every query comes back empty.
  aw_run_in_chroot "update-desktop-database /usr/share/applications" >/dev/null 2>&1 \
    || aw_log warn "could not update the desktop database"

  if [ -z "${AW_EXTRAS:-}" ]; then
    aw_log info "no extras selected"
    aw_log info "applications phase complete"
    return 0
  fi

  # Validate EVERY requested group before installing anything, so a typo fails
  # immediately rather than half-way through a download.
  local group known packages requires_line all_packages=""
  known="$(aw_manifest_groups "$manifest")"
  local saved_ifs="$IFS"
  IFS=','
  for group in $AW_EXTRAS; do
    IFS="$saved_ifs"
    printf '%s\n' "$known" | grep -qx "$group" \
      || aw_die "unknown extras group '$group'. Available: $(printf '%s' "$known" | tr '\n' ' ')"
    IFS=','
  done
  IFS="$saved_ifs"

  IFS=','
  for group in $AW_EXTRAS; do
    IFS="$saved_ifs"
    aw_log info "extras group: $group"
    while read -r requires_line; do
      [ -n "$requires_line" ] || continue
      _aw_enable_repo "$requires_line"
    done < <(aw_manifest_group_requires "$manifest" "$group")
    packages="$(aw_manifest_group "$manifest" "$group")"
    [ -n "$packages" ] || aw_die "extras group '$group' contains no packages"
    all_packages="$all_packages $(printf '%s' "$packages" | tr '\n' ' ')"
    IFS=','
  done
  IFS="$saved_ifs"

  aw_log info "installing extras:$all_packages"
  aw_run_in_chroot "pacman -S --noconfirm --needed $all_packages" \
    || aw_die "could not install the selected extras"

  aw_log info "applications phase complete"
}
