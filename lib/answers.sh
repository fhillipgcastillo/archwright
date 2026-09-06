#!/usr/bin/env bash
# Parse the unattended answer file.
#
# The file is NEVER sourced. Values are read literally, because an answer file
# may arrive from somewhere less trusted than the person running the installer,
# and a value must not be able to execute.

# shellcheck disable=SC2034
# These are cross-file globals: they are set here and consumed by
# lib/00-preflight.sh, lib/10-disk.sh, lib/20-base.sh and lib/30-boot.sh,
# which shellcheck analyses separately and so cannot see.
aw_answers_reset() {
  AW_DISK=""
  AW_HOSTNAME=""
  AW_USERNAME=""
  AW_USER_PASSWORD=""
  AW_LUKS_PASSPHRASE=""
  AW_LOCALE="en_US.UTF-8"
  AW_TIMEZONE="UTC"
  AW_KEYMAP="us"
  AW_SERIAL_CONSOLE="0"
}
aw_answers_reset

aw_answers_load() {
  local file="$1" line key value
  [ -f "$file" ] || aw_die "answer file not found: $file"
  # Start from defaults every time. Without this, loading a second answer
  # file silently inherits values from the first, and validation passes on
  # a field the new file never set.
  aw_answers_reset
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
      DISK)            AW_DISK="$value" ;;
      HOSTNAME)        AW_HOSTNAME="$value" ;;
      USERNAME)        AW_USERNAME="$value" ;;
      USER_PASSWORD)   AW_USER_PASSWORD="$value" ;;
      LUKS_PASSPHRASE) AW_LUKS_PASSPHRASE="$value" ;;
      LOCALE)          AW_LOCALE="$value" ;;
      TIMEZONE)        AW_TIMEZONE="$value" ;;
      KEYMAP)          AW_KEYMAP="$value" ;;
      SERIAL_CONSOLE)  AW_SERIAL_CONSOLE="$value" ;;
      *) aw_log warn "unknown answer key ignored: $key" ;;
    esac
  done < "$file"
}

aw_answers_validate() {
  local ok=0
  [ -n "$AW_DISK" ]            || { aw_log error "answer file: DISK is required"; ok=1; }
  [ -n "$AW_HOSTNAME" ]        || { aw_log error "answer file: HOSTNAME is required"; ok=1; }
  [ -n "$AW_USERNAME" ]        || { aw_log error "answer file: USERNAME is required"; ok=1; }
  [ -n "$AW_USER_PASSWORD" ]   || { aw_log error "answer file: USER_PASSWORD is required"; ok=1; }
  [ -n "$AW_LUKS_PASSPHRASE" ] || { aw_log error "answer file: LUKS_PASSPHRASE is required"; ok=1; }
  return "$ok"
}
