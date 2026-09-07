#!/usr/bin/env bash
# Audio firmware.
#
# PipeWire and wireplumber are installed and configured by the session layer,
# and sof-firmware is already in core because the machines that need it cannot
# be identified before they are booted. So on almost every machine there is
# genuinely nothing to do here, and this script exists to say that clearly
# rather than to leave a gap where a future fix will go.

hw_audio_detect() {
  # A Sound Open Firmware card needs the firmware package. It is already in
  # core, so this reports rather than installs - the check is here so that a
  # machine WITHOUT sof-firmware, some day, is a visible condition instead of
  # silence.
  [ -d /sys/bus/pci/drivers/sof-audio-pci-intel-tgl ] \
    || [ -d /sys/bus/pci/drivers/snd_sof_pci_intel_tgl ]
}

hw_audio_apply() {
  aw_hw_log "Sound Open Firmware audio detected; sof-firmware is already in core"
}
