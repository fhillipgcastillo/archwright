#!/usr/bin/env bash
# Phase 9: hardware enablement.
#
# Runs last, after everything else is installed and configured, because it is
# the only phase whose work depends on the machine rather than on the answer
# file - and because the initramfs rebuild it triggers should happen once, at
# the end, over the final set of modules.
#
# On the test VM every script here finds nothing and says so. That is the
# feature being tested: the same set has to run unchanged on a laptop with an
# NVIDIA card and in a virtual machine with a virtio GPU, and "no-ops cleanly"
# is a property worth a gate rather than an assumption.

AW_HW_DIR_REL="hardware"

aw_hardware() {
  local dir="$AW_ROOT/$AW_HW_DIR_REL"
  [ -d "$dir" ] || aw_die "missing $AW_HW_DIR_REL"

  # These scripts write to the target, not to the live ISO. Read by the
  # helpers in lib/hardware.sh, which install.sh sources.
  # shellcheck disable=SC2034
  AW_HW_ROOT="/mnt"

  aw_log info "hardware scripts: $(aw_hw_scripts "$dir" | tr '\n' ' ')"

  # Mask before, rebuild once after. See lib/hardware.sh for why.
  aw_hw_mask_mkinitcpio

  local applied=0 rc=0
  applied="$(aw_hw_run "$dir")" || rc=$?
  aw_hw_unmask_mkinitcpio
  [ "$rc" -eq 0 ] || aw_die "a hardware script failed"

  aw_log info "  $applied of $(aw_hw_scripts "$dir" | wc -l | tr -d ' ') script(s) applied"

  # One rebuild, over the final set of modules. Unconditional: a script may
  # have changed MODULES without installing anything, and getting this wrong
  # produces a machine that boots to a black screen.
  aw_log info "rebuilding the initramfs"
  aw_run_in_chroot "mkinitcpio -P" >/dev/null 2>&1 \
    || aw_die "the initramfs rebuild failed"

  # Everything the installed system needs to re-run this later without the
  # repository being present.
  aw_log info "installing the hardware scripts"
  install -d -m 0755 /mnt/usr/share/archwright/hardware
  install -m 0644 "$dir"/[0-9][0-9]-*.sh /mnt/usr/share/archwright/hardware/ \
    || aw_die "could not install the hardware scripts"
  install -m 0644 "$AW_ROOT/lib/hardware.sh" /mnt/usr/share/archwright/lib/ \
    || aw_die "could not install the hardware library"

  aw_log info "hardware phase complete"
}
