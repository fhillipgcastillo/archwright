#!/usr/bin/env bash
# Hardware detection.
#
# This is where the real coverage for the hardware layer lives. The VM has a
# virtio GPU and no battery, so the gate can only ever prove that every script
# no-ops cleanly - which matters, but says nothing about what happens on the
# machines the scripts exist for. Detection reads sysfs and takes the directory
# as a parameter precisely so it can be pointed at a fixture instead of at
# whatever card the developer happens to own.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/hardware.sh
. "$ROOT/lib/hardware.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a fake PCI device. class and vendor are exactly the two files the
# detector reads.
pci_device() {
  local dir="$1/$2"
  mkdir -p "$dir"
  printf '%s\n' "$3" > "$dir/class"
  printf '%s\n' "$4" > "$dir/vendor"
}

# --- GPU vendor detection ----------------------------------------------------
mkdir -p "$tmp/empty"
assert_eq "$(aw_hw_gpu_vendors "$tmp/empty")" "" "no devices means no vendors"
assert_eq "$(aw_hw_gpu_vendors "$tmp/does-not-exist")" "" \
  "a missing sysfs tree yields nothing rather than failing"

mkdir -p "$tmp/intel"
pci_device "$tmp/intel" 0000:00:02.0 0x030000 0x8086
assert_eq "$(aw_hw_gpu_vendors "$tmp/intel")" "intel" "an Intel VGA controller is detected"

mkdir -p "$tmp/amd"
pci_device "$tmp/amd" 0000:03:00.0 0x030000 0x1002
assert_eq "$(aw_hw_gpu_vendors "$tmp/amd")" "amd" "an AMD VGA controller is detected"

mkdir -p "$tmp/nvidia"
pci_device "$tmp/nvidia" 0000:01:00.0 0x030000 0x10de
assert_eq "$(aw_hw_gpu_vendors "$tmp/nvidia")" "nvidia" "an NVIDIA VGA controller is detected"

# A discrete GPU in a laptop usually presents as class 0x0302 (3D controller)
# rather than 0x0300. Looking only for 0x0300 misses exactly the machines that
# most need a driver.
mkdir -p "$tmp/optimus"
pci_device "$tmp/optimus" 0000:00:02.0 0x030000 0x8086
pci_device "$tmp/optimus" 0000:01:00.0 0x030200 0x10de
assert_eq "$(aw_hw_gpu_vendors "$tmp/optimus" | tr '\n' ',')" "intel,nvidia," \
  "a hybrid laptop reports both, including the 3D-controller class"

# Anything else is 'other', which means mesa and nothing added. This is the
# case the test VM is in, so it has to be a first-class answer rather than an
# error.
mkdir -p "$tmp/virtio"
pci_device "$tmp/virtio" 0000:00:01.0 0x030000 0x1af4
assert_eq "$(aw_hw_gpu_vendors "$tmp/virtio")" "other" "a virtio GPU is 'other', not a failure"

# Non-graphics devices must not be picked up: a network card sharing a vendor
# id with a GPU maker is normal.
mkdir -p "$tmp/mixed"
pci_device "$tmp/mixed" 0000:00:1f.6 0x020000 0x8086   # ethernet
pci_device "$tmp/mixed" 0000:00:14.0 0x0c0330 0x8086   # usb controller
assert_eq "$(aw_hw_gpu_vendors "$tmp/mixed")" "" \
  "non-graphics devices are ignored even from a GPU vendor"

# A device directory missing either file is skipped rather than fatal - sysfs
# is not uniform across kernels and a crash here would fail the whole install.
mkdir -p "$tmp/partial/0000:00:02.0"
printf '0x030000\n' > "$tmp/partial/0000:00:02.0/class"
assert_eq "$(aw_hw_gpu_vendors "$tmp/partial")" "" "a device with no vendor file is skipped"

# --- laptop detection --------------------------------------------------------
mkdir -p "$tmp/ps-desktop/AC"
printf 'Mains\n' > "$tmp/ps-desktop/AC/type"
if aw_hw_is_laptop "$tmp/ps-desktop"; then
  _fail "hardware" "a machine with only a mains supply was called a laptop"
else _pass; fi

mkdir -p "$tmp/ps-laptop/AC" "$tmp/ps-laptop/BAT0"
printf 'Mains\n' > "$tmp/ps-laptop/AC/type"
printf 'Battery\n' > "$tmp/ps-laptop/BAT0/type"
if aw_hw_is_laptop "$tmp/ps-laptop"; then _pass
else _fail "hardware" "a machine with a battery was not called a laptop"; fi

if aw_hw_is_laptop "$tmp/no-such-dir"; then
  _fail "hardware" "a missing power_supply tree was called a laptop"
else _pass; fi

# --- the script contract -----------------------------------------------------
assert_eq "$(aw_hw_stem 10-gpu.sh)" "gpu" "the stem is the name without number or suffix"
assert_eq "$(aw_hw_stem /a/b/20-suspend.sh)" "suspend" "including from a full path"

hw_dir="$ROOT/hardware"
scripts="$(aw_hw_scripts "$hw_dir")"
if [ -n "$scripts" ]; then _pass
else _fail "hardware" "no hardware scripts are shipped"; fi

# Numbered, so the order is explicit rather than whatever the filesystem
# returns.
assert_eq "$(printf '%s\n' "$scripts" | head -1)" "10-gpu.sh" \
  "the GPU script runs first"

# Every shipped script must define both halves of the contract. A script that
# defines only one fails at the point of use, mid-install, on somebody's
# machine.
for s in $scripts; do
  stem="$(aw_hw_stem "$s")"
  # shellcheck source=/dev/null
  . "$hw_dir/$s"
  if command -v "hw_${stem}_detect" >/dev/null 2>&1; then _pass
  else _fail "hardware" "$s defines no hw_${stem}_detect"; fi
  if command -v "hw_${stem}_apply" >/dev/null 2>&1; then _pass
  else _fail "hardware" "$s defines no hw_${stem}_apply"; fi
done

# Detection must be side-effect free: the runner calls it on every machine,
# including ones where apply must never run. Nothing may be written and no
# package may be touched by a detect.
for s in $scripts; do
  if grep -qE '^[^#]*(aw_hw_install|aw_hw_write|pacman)' \
       <(sed -n "/^hw_$(aw_hw_stem "$s")_detect()/,/^}/p" "$hw_dir/$s"); then
    _fail "hardware" "$s has a side effect inside its detect function"
  else _pass; fi
done

# --- the mkinitcpio guard ----------------------------------------------------
AW_HW_ROOT="$tmp/root"
mkdir -p "$AW_HW_ROOT/etc/pacman.d/hooks"
aw_hw_mask_mkinitcpio
if [ -L "$AW_HW_ROOT/etc/pacman.d/hooks/90-mkinitcpio-install.hook" ]; then _pass
else _fail "hardware" "the install hook was not masked"; fi
assert_eq "$(readlink "$AW_HW_ROOT/etc/pacman.d/hooks/90-mkinitcpio-install.hook")" \
  "/dev/null" "masking is a symlink to /dev/null, the documented mechanism"

aw_hw_unmask_mkinitcpio
if [ -e "$AW_HW_ROOT/etc/pacman.d/hooks/90-mkinitcpio-install.hook" ]; then
  _fail "hardware" "the mask was not removed"
else _pass; fi

# A REAL file with that name is somebody's deliberate override. Unmasking must
# not delete it.
printf '# mine\n' > "$AW_HW_ROOT/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
aw_hw_unmask_mkinitcpio
if [ -f "$AW_HW_ROOT/etc/pacman.d/hooks/90-mkinitcpio-install.hook" ]; then _pass
else _fail "hardware" "unmasking deleted a real hook file that was not ours"; fi

finish_tests
