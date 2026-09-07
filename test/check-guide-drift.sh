#!/usr/bin/env bash
# Does the Guide still describe what the installer actually does?
#
# THE PROBLEM THIS SOLVES
#
# The Guide is prose in a vault; the installer is code in this repository. They
# describe the same system, and nothing except this script stops them drifting.
# A guide that was accurate once and is wrong now is worse than no guide: it
# reads as authoritative and sends someone down a path that no longer exists.
#
# WHAT IT CHECKS
#
# The facts that are duplicated between the two and would silently rot:
#
#   * every package in manifest/core.packages appears in the Guide
#   * the Guide names no package the manifest does not have
#   * every palette in manifest/palettes/ is in the Installer Guide's theme table
#   * every extras group is in the Installer Guide's table
#   * every phase the installer runs is named in the Installer Guide
#
# WHAT IT DELIBERATELY DOES NOT CHECK
#
# Prose. Whether an explanation is still true is a judgement, and a script that
# pretended to make it would give false confidence. This checks the tables,
# which are facts, and says so.
#
# WHERE THE GUIDE IS
#
# It lives in a vault outside this repository, so the path is a parameter. With
# no guide reachable the script reports what it would have compared and exits
# 0 - a contributor without the vault should not have a red check they cannot
# fix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$HERE/lib/manifest.sh"
# shellcheck source=lib/theme.sh
. "$HERE/lib/theme.sh"

DEFAULT_VAULT="/c/Users/Owner/Documents/MainVault/Main Vault/Operating system/Custom OS Builder"
GUIDE="${ARCHWRIGHT_GUIDE:-$DEFAULT_VAULT/Archwright — Build Guide.md}"
INSTALLER_GUIDE="${ARCHWRIGHT_INSTALLER_GUIDE:-$DEFAULT_VAULT/Archwright — Installer Guide.md}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --guide)           GUIDE="$2"; shift 2 ;;
    --installer-guide) INSTALLER_GUIDE="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--guide <path>] [--installer-guide <path>]\n' "$0"
      printf '\nDefaults come from ARCHWRIGHT_GUIDE / ARCHWRIGHT_INSTALLER_GUIDE,\n'
      printf 'then from the vault path this project uses.\n'
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

problems=0
note() { printf '  %s\n' "$*"; }
fail() { printf 'DRIFT  %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f "$GUIDE" ] && [ ! -f "$INSTALLER_GUIDE" ]; then
  printf 'No guide found. Looked for:\n'
  note "$GUIDE"
  note "$INSTALLER_GUIDE"
  printf '\nThe Guide lives in a vault outside this repository. Set\n'
  printf 'ARCHWRIGHT_GUIDE, or pass --guide, to check it.\n'
  exit 0
fi

# --- packages ----------------------------------------------------------------
if [ -f "$GUIDE" ]; then
  printf 'Checking %s\n' "$(basename "$GUIDE")"
  missing=0
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    # Anywhere in the document: a package may be named in a pacstrap block, in
    # the manifest table, or in prose. Any of those counts as documented.
    grep -qF "$pkg" "$GUIDE" || { fail "package not in the Guide: $pkg"; missing=$((missing+1)); }
  done < <(aw_manifest_packages manifest/core.packages)
  [ "$missing" -eq 0 ] && note "all $(aw_manifest_packages manifest/core.packages | wc -l | tr -d ' ') core packages are documented"

  # And the reverse: a package the Guide tells someone to install that this
  # project no longer ships. This is the direction that rots quietly, because
  # nothing breaks until a reader runs the command.
  stale=0
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    case "$pkg" in
      # Named in the Guide for good reason without being in core.
      vulkan-intel|intel-media-driver|vulkan-radeon|nvidia-open-dkms|nvidia-utils|egl-wayland) continue ;;
      qemu-full|edk2-ovmf|qemu-system-x86|ovmf) continue ;;
    esac
    aw_manifest_packages manifest/core.packages | grep -qx "$pkg" \
      || { fail "the Guide names a package that is not in core.packages: $pkg"; stale=$((stale+1)); }
  done < <(sed -n 's/.*^ *\(sudo \)\?pacman -S --needed.*//p' "$GUIDE" | tr ' ' '\n' | grep -E '^[a-z][a-z0-9.+-]+$' | LC_ALL=C sort -u)
  [ "$stale" -eq 0 ] && note "the Guide names no package this project has dropped"
fi

# --- themes, extras and phases ----------------------------------------------
if [ -f "$INSTALLER_GUIDE" ]; then
  printf 'Checking %s\n' "$(basename "$INSTALLER_GUIDE")"

  for pid in $(aw_theme_list manifest/palettes); do
    grep -qF "\`$pid\`" "$INSTALLER_GUIDE" \
      || fail "palette not in the theme table: $pid"
  done
  note "$(aw_theme_list manifest/palettes | wc -l | tr -d ' ') palettes checked"

  for g in $(aw_manifest_groups manifest/extras.packages); do
    grep -qF "\`$g\`" "$INSTALLER_GUIDE" \
      || fail "extras group not in the table: $g"
  done
  note "$(aw_manifest_groups manifest/extras.packages | wc -l | tr -d ' ') extras groups checked"

  # The phase list the installer prints as it runs.
  phases="$(sed -n 's/^AW_PHASES="\(.*\)"$/\1/p' install.sh)"
  for p in $phases; do
    grep -qF "\`$p\`" "$INSTALLER_GUIDE" \
      || fail "phase not named in the Installer Guide: $p"
  done
  note "$(printf '%s' "$phases" | wc -w | tr -d ' ') phases checked"
fi

printf '\n'
if [ "$problems" -ne 0 ]; then
  printf 'The Guide has drifted from the installer: %d problem(s).\n' "$problems"
  printf 'Either the Guide is out of date, or something was added without documenting it.\n'
  exit 1
fi
printf 'No drift: the Guide and the installer agree on packages, themes, groups and phases.\n'
