#!/usr/bin/env bash
# GPU drivers.
#
# mesa is already in core and covers the OpenGL and VA-API side for both Intel
# and AMD - it `provides` libva-mesa-driver, which stopped being a package of
# its own. What is added here is the Vulkan driver for the card that is
# actually present, plus, for NVIDIA, the parts a Wayland compositor needs
# before it will start at all.
#
# No vendor matrix and no lists of model numbers. Three vendors, read out of
# sysfs, and anything else gets mesa and nothing more - which is the correct
# outcome for the virtio GPU the test VM has.

hw_gpu_detect() {
  [ -n "$(aw_hw_gpu_vendors)" ]
}

hw_gpu_apply() {
  local vendors packages="" v
  vendors="$(aw_hw_gpu_vendors)"
  aw_hw_log "GPU vendors: $(printf '%s' "$vendors" | tr '\n' ' ')"

  for v in $vendors; do
    case "$v" in
      intel)  packages="$packages vulkan-intel intel-media-driver" ;;
      amd)    packages="$packages vulkan-radeon" ;;
      nvidia) packages="$packages nvidia-open-dkms nvidia-utils egl-wayland" ;;
      other)
        # virtio, VMware, Hyper-V, an old card with no Vulkan driver. mesa is
        # already installed and is the right answer; saying so is better than
        # silence, because "nothing happened" and "nothing needed to happen"
        # look identical in a log otherwise.
        aw_hw_log "unrecognised GPU vendor - mesa covers it, nothing to add"
        ;;
    esac
  done

  # shellcheck disable=SC2086  # deliberate word splitting: a package list
  [ -z "$packages" ] || aw_hw_install $packages

  case "$vendors" in
    *nvidia*)
      # Without modeset the compositor starts and renders nothing. This is the
      # single most common cause of "Hyprland does not work on my NVIDIA
      # machine", and it is one kernel parameter.
      aw_hw_write /etc/modprobe.d/archwright-nvidia.conf <<'CONF'
# Added by Archwright. NVIDIA needs kernel modesetting before any Wayland
# compositor will produce an image; without it Hyprland starts, reports no
# errors, and shows a black screen.
options nvidia_drm modeset=1
CONF
      # The modules have to be in the initramfs too, or modesetting happens too
      # late to matter.
      aw_hw_write /etc/mkinitcpio.conf.d/archwright-nvidia.conf <<'CONF'
# Added by Archwright.
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
CONF
      aw_hw_log "NVIDIA: modesetting configured (untested on real hardware - see the gaps table)"
      ;;
  esac
}
