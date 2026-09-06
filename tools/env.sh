#!/usr/bin/env bash
# Shared path resolution for the VM tooling. Sourced, not executed.
#
# The repo may live on a Windows drive mounted under /mnt (WSL2), where I/O is
# slow enough that a 1.3GB ISO and a qcow2 disk image are painful to use. So
# large, regenerable artifacts live in a cache on the native filesystem and
# only the repo itself is read across the mount boundary.

# Exported because they are consumed by the scripts that source this file
# and by the Python driver, not used within env.sh itself.
export AW_REPO="${AW_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export AW_CACHE="${ARCHWRIGHT_CACHE:-$HOME/.cache/archwright}"
export AW_ISO="$AW_CACHE/archlinux.iso"
export AW_BOOT="$AW_CACHE/boot"
export AW_VMRUN="$AW_CACHE/vmrun"

aw_env_qemu() {
  if [ -n "${ARCHWRIGHT_QEMU:-}" ]; then printf '%s\n' "$ARCHWRIGHT_QEMU"; return 0; fi
  command -v qemu-system-x86_64 2>/dev/null && return 0
  echo "qemu-system-x86_64 not found. On Debian/Ubuntu: apt install qemu-system-x86" >&2
  return 1
}

aw_env_qemu_img() {
  if [ -n "${ARCHWRIGHT_QEMU_IMG:-}" ]; then printf '%s\n' "$ARCHWRIGHT_QEMU_IMG"; return 0; fi
  command -v qemu-img 2>/dev/null && return 0
  echo "qemu-img not found. On Debian/Ubuntu: apt install qemu-utils" >&2
  return 1
}

# Distributions disagree on OVMF filenames. Ubuntu 24.04 ships
# OVMF_CODE_4M.fd; Arch and older Debian ship OVMF_CODE.fd. Probe rather
# than assume, and never pick a Secure Boot or "ms" variant - those refuse
# to boot an unsigned kernel and produce a baffling blank screen.
aw_env_ovmf_code() {
  if [ -n "${ARCHWRIGHT_OVMF_CODE:-}" ]; then printf '%s\n' "$ARCHWRIGHT_OVMF_CODE"; return 0; fi
  local c
  for c in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/qemu/edk2-x86_64-code.fd
  do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  echo "no OVMF firmware found. On Debian/Ubuntu: apt install ovmf" >&2
  return 1
}

aw_env_ovmf_vars() {
  if [ -n "${ARCHWRIGHT_OVMF_VARS:-}" ]; then printf '%s\n' "$ARCHWRIGHT_OVMF_VARS"; return 0; fi
  local c
  for c in \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/qemu/edk2-i386-vars.fd
  do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  echo "no OVMF vars template found. On Debian/Ubuntu: apt install ovmf" >&2
  return 1
}

aw_env_accel() {
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then printf 'kvm\n'; else printf 'tcg\n'; fi
}

aw_env_report() {
  printf 'repo   %s\n' "$AW_REPO"
  printf 'cache  %s\n' "$AW_CACHE"
  printf 'qemu   %s\n' "$(aw_env_qemu || echo MISSING)"
  printf 'img    %s\n' "$(aw_env_qemu_img || echo MISSING)"
  printf 'code   %s\n' "$(aw_env_ovmf_code || echo MISSING)"
  printf 'vars   %s\n' "$(aw_env_ovmf_vars || echo MISSING)"
  printf 'accel  %s\n' "$(aw_env_accel)"
}
