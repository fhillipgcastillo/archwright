#!/usr/bin/env bash
# Phase 5: theming.
#
# WHY THIS RUNS BEFORE THE SESSION PHASE
#
# Everything downstream seeds user configuration out of
# /usr/share/archwright/default-config. Two of those files - foot.ini and
# fuzzel.ini - are rendered rather than copied, because foot and fuzzel both
# document `include` as taking an absolute path and so the include line has to
# carry the real home directory. If this phase ran after the seeding, the user
# would already have the unrendered copies and would never see the themed ones:
# seeding is one-way by design.
#
# WHAT IT OWNS
#
#   /usr/share/archwright/palettes/     every palette, so a theme can be
#   /usr/share/archwright/theme/        changed after install without the
#   /usr/share/archwright/wallpapers/   repository being present
#   ~/.config/{hypr,waybar,foot,mako,fuzzel,gtk-*}/  the colour files only
#
# The colour files are OURS and are rewritten on every theme change. Everything
# else in ~/.config is the user's and is seeded once. That split is the whole
# reason seven palettes can ship rather than one.

AW_PALETTE_DIR_REL="manifest/palettes"
AW_THEME_TPL_REL="config/theme"
AW_THEME_FILES_REL="manifest/theme-files.tsv"

aw_theme() {
  local home="/mnt/home/$AW_USERNAME"
  local pal_dir="$AW_ROOT/$AW_PALETTE_DIR_REL"
  local tpl_dir="$AW_ROOT/$AW_THEME_TPL_REL"
  local files="$AW_ROOT/$AW_THEME_FILES_REL"

  [ -d "$home" ] || aw_die "user home $home does not exist - did the base phase run?"
  [ -d "$pal_dir" ] || aw_die "missing $AW_PALETTE_DIR_REL"
  [ -f "$files" ] || aw_die "missing $AW_THEME_FILES_REL"

  # Validate the requested palette before anything is written. The answer file
  # only checked that the value is shaped like an id; whether it names a real
  # palette can only be answered here.
  local available
  available="$(aw_theme_list "$pal_dir" | tr '\n' ' ')"
  [ -f "$pal_dir/$AW_THEME.palette" ] \
    || aw_die "unknown theme '$AW_THEME'. Available: $available"

  aw_log info "theme: $AW_THEME"
  aw_theme_load "$pal_dir/$AW_THEME.palette"
  # AW_PAL_* are set by lib/theme.sh, which install.sh sources; they are read
  # back by aw_theme_render in that same file rather than used here.
  # shellcheck disable=SC2034
  AW_PAL_home="/home/$AW_USERNAME"
  aw_log info "  ${AW_PAL_name:-$AW_THEME}"

  # Everything needed to change theme later, on a machine with no checkout.
  aw_log info "installing palettes, templates and wallpapers"
  install -d -m 0755 /mnt/usr/share/archwright/palettes \
                     /mnt/usr/share/archwright/theme \
                     /mnt/usr/share/archwright/wallpapers
  install -m 0644 "$pal_dir"/*.palette /mnt/usr/share/archwright/palettes/ \
    || aw_die "could not install the palettes"
  install -m 0644 "$tpl_dir"/*.in /mnt/usr/share/archwright/theme/ \
    || aw_die "could not install the theme templates"
  install -m 0644 "$files" /mnt/usr/share/archwright/theme/theme-files.tsv \
    || aw_die "could not install the theme file manifest"
  install -m 0644 "$AW_ROOT/config/wallpapers"/*.png \
    /mnt/usr/share/archwright/wallpapers/ \
    || aw_die "could not install the wallpapers"

  # Every palette must have a wallpaper, or selecting it later gives a dead
  # symlink and a black screen instead of a background.
  local pid
  for pid in $available; do
    [ -f "/mnt/usr/share/archwright/wallpapers/$pid.png" ] \
      || aw_die "palette $pid has no wallpaper - run tools/make-wallpaper.py"
  done

  # The CLI sources these rather than carrying its own copy of the renderer.
  aw_log info "installing the theme library"
  install -d -m 0755 /mnt/usr/share/archwright/lib
  install -m 0644 "$AW_ROOT/lib/common.sh" "$AW_ROOT/lib/theme.sh" \
    /mnt/usr/share/archwright/lib/ \
    || aw_die "could not install the theme library"

  aw_log info "installing the GTK theme applier"
  install -d -m 0755 /mnt/usr/share/archwright/bin
  install -m 0755 "$AW_ROOT/bin/archwright-apply-gtk-theme" \
    /mnt/usr/share/archwright/bin/archwright-apply-gtk-theme \
    || aw_die "could not install the GTK theme applier"
  ln -sf /usr/share/archwright/bin/archwright-apply-gtk-theme \
    /mnt/usr/bin/archwright-apply-gtk-theme \
    || aw_die "could not link the GTK theme applier"

  # The user-owned templates go into the defaults tree, so the seeding phases
  # downstream pick them up like any other default.
  aw_log info "rendering the seeded configuration"
  local n
  n="$(aw_theme_generate "$files" "$tpl_dir" \
        /mnt/usr/share/archwright/default-config user)"
  [ "$n" -gt 0 ] || aw_die "no user-owned templates were rendered"
  aw_log info "  $n file(s)"

  # The colour files are written straight into the user's home: they are ours,
  # not seeded, and are replaced wholesale whenever the theme changes.
  aw_log info "writing the colour files"
  n="$(aw_theme_generate "$files" "$tpl_dir" "$home/.config" theme)"
  [ "$n" -gt 0 ] || aw_die "no colour files were written"
  aw_log info "  $n file(s)"

  # The wallpaper pointer lives in the user's own state directory so that
  # changing theme later needs no root.
  install -d -m 0755 "$home/.local/state/archwright"
  local wp_target="/usr/share/archwright/wallpapers/$AW_THEME.png"
  ln -sfn "$wp_target" "$home/.local/state/archwright/wallpaper.png" \
    || aw_die "could not point the wallpaper at $AW_THEME"

  # Check the link's TARGET, not whether it resolves. The link is absolute and
  # correct for the installed system, but we are outside that system's root:
  # from here /usr/share/archwright is the live ISO's, so `[ -f ]` on the link
  # is asking the wrong filesystem and fails on a perfectly good install. The
  # file it points at was already asserted present under /mnt above, and the
  # VM gate checks that it resolves from inside the booted system, which is
  # where that question can actually be answered.
  [ "$(readlink "$home/.local/state/archwright/wallpaper.png")" = "$wp_target" ] \
    || aw_die "the wallpaper link does not point at $wp_target"

  printf '%s\n' "$AW_THEME" > "$home/.local/state/archwright/theme" \
    || aw_die "could not record the selected theme"

  aw_run_in_chroot "chown -R '$AW_USERNAME:$AW_USERNAME' '/home/$AW_USERNAME'" \
    || aw_die "could not chown the user's home directory"

  aw_log info "theme phase complete"
}
