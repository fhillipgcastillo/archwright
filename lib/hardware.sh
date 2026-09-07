#!/usr/bin/env bash
# Hardware enablement (spec section 10).
#
# THE SHAPE
#
# One script per concern in hardware/, numbered because order matters, and each
# one is detect-then-apply. A script that finds nothing says so and returns; it
# does not fail, and it does not install anything "just in case". So the same
# set runs unchanged on a laptop, a desktop and a virtual machine, and the VM
# case - where all of them no-op - is a real test of that contract rather than
# a gap in it.
#
# Each hardware/NN-<name>.sh defines exactly two functions:
#
#   hw_<name>_detect   returns 0 when the hardware is present
#   hw_<name>_apply    configures it; only ever called after a positive detect
#
# and may use aw_hw_log, aw_hw_install and aw_hw_write, below. Nothing else.
#
# ONE SET OF SCRIPTS, TWO CONTEXTS
#
# These run during installation, against a target mounted at /mnt, and again
# afterwards via `archwright hardware`, against the running system. The
# difference is entirely in AW_HW_ROOT and in how packages get installed, so the
# scripts themselves never know which context they are in - which is what stops
# the two paths drifting apart.

AW_HW_ROOT="${AW_HW_ROOT:-}"

aw_hw_log() { aw_log info "    $*"; }

# Install packages into whichever root is in play.
aw_hw_install() {
  [ "$#" -gt 0 ] || return 0
  aw_hw_log "installing: $*"
  if [ -n "$AW_HW_ROOT" ]; then
    aw_run_in_chroot "pacman -S --needed --noconfirm $*" \
      || aw_die "could not install: $*"
  else
    pacman -S --needed --noconfirm "$@" || aw_die "could not install: $*"
  fi
}

# Write a file relative to the active root, from stdin.
aw_hw_write() {
  # Three separate `local`s: `local a=$1 b=$a` reads a value that has not been
  # assigned yet in POSIX terms, and shellcheck is right to call it out even
  # where bash happens to do the friendly thing.
  local rel="$1"
  local mode="${2:-0644}"
  local dest="$AW_HW_ROOT$rel"
  install -d -m 0755 "$(dirname "$dest")" || aw_die "could not create $(dirname "$rel")"
  cat > "$dest" || aw_die "could not write $rel"
  chmod "$mode" "$dest" || aw_die "could not set the mode on $rel"
  aw_hw_log "wrote $rel"
}

# --- detection ----------------------------------------------------------------
#
# Read from sysfs rather than shelling out to lspci. pciutils is not in the
# package set, sysfs is present in the live ISO and on the installed system
# alike, and taking a directory as a parameter is what makes this testable
# against a fixture instead of against whatever card the developer happens to
# own.
#
# PCI class 0x0300 is a VGA controller and 0x0302 a 3D controller - the second
# is how a discrete GPU in a laptop usually presents itself, so looking only for
# 0x0300 misses exactly the machines that need a driver most.
aw_hw_gpu_vendors() {
  local sysfs="${1:-/sys/bus/pci/devices}" dev class vendor
  [ -d "$sysfs" ] || return 0
  for dev in "$sysfs"/*; do
    # sysfs is not uniform across kernels and a device node can be missing
    # either file. Skip it rather than crash the install over it.
    if [ ! -r "$dev/class" ] || [ ! -r "$dev/vendor" ]; then continue; fi
    class="$(tr -d '[:space:]' < "$dev/class")"
    case "$class" in 0x0300*|0x0302*) ;; *) continue ;; esac
    vendor="$(tr -d '[:space:]' < "$dev/vendor")"
    case "$vendor" in
      0x8086) printf 'intel\n' ;;
      0x1002|0x1022) printf 'amd\n' ;;
      0x10de) printf 'nvidia\n' ;;
      *) printf 'other\n' ;;
    esac
  done | LC_ALL=C sort -u
}

# A battery is the only reliable "this is a portable machine" signal that does
# not involve trusting a DMI string.
aw_hw_is_laptop() {
  local sysfs="${1:-/sys/class/power_supply}" d
  [ -d "$sysfs" ] || return 1
  for d in "$sysfs"/*; do
    [ -r "$d/type" ] || continue
    grep -qx Battery "$d/type" 2>/dev/null && return 0
  done
  return 1
}

# --- the mkinitcpio guard -----------------------------------------------------
#
# Every firmware and DKMS package triggers a full initramfs rebuild, for every
# installed kernel, through pacman's hooks. Installing four of them in a row
# means four rebuilds, three of which are thrown away by the fourth. On the VM
# that is a minute; on a slow disk with several kernels it is much worse.
#
# Masking a pacman hook is a symlink to /dev/null in /etc/pacman.d/hooks with
# the same filename - the documented mechanism, not a trick.
AW_HW_HOOKS="90-mkinitcpio-install.hook 60-mkinitcpio-remove.hook"

aw_hw_mask_mkinitcpio() {
  local h
  install -d -m 0755 "$AW_HW_ROOT/etc/pacman.d/hooks"
  for h in $AW_HW_HOOKS; do
    ln -sfn /dev/null "$AW_HW_ROOT/etc/pacman.d/hooks/$h" \
      || aw_die "could not mask the $h pacman hook"
  done
  aw_log info "  initramfs rebuilds masked for the duration of this phase"
}

aw_hw_unmask_mkinitcpio() {
  local h
  for h in $AW_HW_HOOKS; do
    # Only ever remove OUR symlink. A real file with that name is somebody
    # else's deliberate override and is not ours to delete.
    if [ -L "$AW_HW_ROOT/etc/pacman.d/hooks/$h" ]; then
      rm -f "$AW_HW_ROOT/etc/pacman.d/hooks/$h"
    fi
  done
}

# --- the runner ---------------------------------------------------------------

# Names of the scripts in a hardware directory, in the order they will run.
aw_hw_scripts() {
  local dir="$1" f
  [ -d "$dir" ] || aw_die "no hardware directory: $dir"
  for f in "$dir"/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort
}

# Derive the function-name stem from a filename: 10-gpu.sh -> gpu.
aw_hw_stem() {
  local n="${1##*/}"
  n="${n%.sh}"
  printf '%s' "${n#*-}"
}

# Run every script. Returns the number that applied, on stdout.
aw_hw_run() {
  local dir="$1" script stem applied=0
  while read -r script; do
    [ -n "$script" ] || continue
    stem="$(aw_hw_stem "$script")"
    # shellcheck source=/dev/null
    . "$dir/$script"
    command -v "hw_${stem}_detect" >/dev/null 2>&1 \
      || aw_die "$script defines no hw_${stem}_detect"
    command -v "hw_${stem}_apply" >/dev/null 2>&1 \
      || aw_die "$script defines no hw_${stem}_apply"

    if "hw_${stem}_detect"; then
      aw_log info "  $stem: present"
      "hw_${stem}_apply"
      applied=$((applied + 1))
    else
      aw_log info "  $stem: nothing to do"
    fi
  done < <(aw_hw_scripts "$dir")
  printf '%s\n' "$applied"
}
