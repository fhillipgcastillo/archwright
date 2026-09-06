#!/usr/bin/env bash
# Parse and validate the unattended answer file.
#
# The file is never sourced, so parsing it cannot execute anything. That alone
# is NOT sufficient: values are later interpolated into shell commands run in
# the target (see aw_run_in_chroot), so a value containing shell metacharacters
# would execute at THAT point. Validation below - not the choice to avoid
# `source` - is what actually keeps a metacharacter out of a root shell.
#
# Secrets are the exception to interpolation: USER_PASSWORD and
# LUKS_PASSPHRASE are only ever passed on stdin (chpasswd, cryptsetup), never
# on a command line, so they may contain anything.

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
  AW_AUTOLOGIN="0"
}
aw_answers_reset

_aw_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Turn the right-hand side of KEY=VALUE into the value.
#
# A quoted value is taken verbatim: passwords routinely contain '#' and may
# end in a space, and eating either would lock the user out of the machine
# they just installed. An unquoted value gets an inline comment stripped
# (whitespace followed by '#') and is trimmed, because the shipped example
# file uses comment lines and a trailing comment is a natural thing to write.
_aw_value() {
  local v
  v="$(_aw_trim "${1%$'\r'}")"
  case "$v" in
    '"'*'"') printf '%s' "${v:1:${#v}-2}"; return ;;
    "'"*"'") printf '%s' "${v:1:${#v}-2}"; return ;;
  esac
  case "$v" in
    *[[:space:]]'#'*) v="${v%%[[:space:]]'#'*}" ;;
  esac
  _aw_trim "$v"
}

aw_answers_load() {
  local file="$1" line trimmed key value
  [ -f "$file" ] || aw_die "answer file not found: $file"
  # Start from defaults every time. Without this, loading a second answer file
  # silently inherits values from the first, and validation passes on a field
  # the new file never set.
  aw_answers_reset
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(_aw_trim "${line%$'\r'}")"
    case "$trimmed" in ''|'#'*) continue ;; esac
    case "$trimmed" in *=*) ;; *) continue ;; esac
    key="$(_aw_trim "${trimmed%%=*}")"
    value="$(_aw_value "${trimmed#*=}")"
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
      AUTOLOGIN)       AW_AUTOLOGIN="$value" ;;
      *) aw_log warn "unknown answer key ignored: $key" ;;
    esac
  done < "$file"
}

_aw_check() {
  local name="$1" value="$2" pattern="$3" hint="$4"
  if [ -z "$value" ]; then
    aw_log error "answer file: $name is required"
    return 1
  fi
  if ! printf '%s' "$value" | grep -qE "$pattern"; then
    aw_log error "answer file: $name is invalid ($hint), got [$value]"
    return 1
  fi
  return 0
}

aw_answers_validate() {
  local ok=0

  _aw_check DISK "$AW_DISK" '^/dev/[A-Za-z0-9._/-]+$' \
    'must be an absolute /dev path with no shell metacharacters' || ok=1
  case "$AW_DISK" in
    *..*) aw_log error "answer file: DISK must not contain '..', got [$AW_DISK]"; ok=1 ;;
  esac

  _aw_check HOSTNAME "$AW_HOSTNAME" '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' \
    'letters, digits and hyphens; must start and end alphanumeric' || ok=1

  _aw_check USERNAME "$AW_USERNAME" '^[a-z_][a-z0-9_-]{0,31}$' \
    'lowercase, starting with a letter or underscore' || ok=1

  _aw_check TIMEZONE "$AW_TIMEZONE" '^[A-Za-z0-9+_-]+(/[A-Za-z0-9+_-]+)*$' \
    'a zoneinfo name such as America/New_York' || ok=1

  _aw_check LOCALE "$AW_LOCALE" '^[A-Za-z0-9@._-]+$' \
    'a locale name such as en_US.UTF-8' || ok=1

  _aw_check KEYMAP "$AW_KEYMAP" '^[A-Za-z0-9._-]+$' \
    'a console keymap name such as us' || ok=1

  _aw_check SERIAL_CONSOLE "$AW_SERIAL_CONSOLE" '^[01]$' \
    '0 or 1' || ok=1

  _aw_check AUTOLOGIN "$AW_AUTOLOGIN" '^[01]$' \
    '0 or 1' || ok=1

  # Secrets reach the target on stdin only, so their content is unconstrained.
  # They still have to be present.
  [ -n "$AW_USER_PASSWORD" ]   || { aw_log error "answer file: USER_PASSWORD is required"; ok=1; }
  [ -n "$AW_LUKS_PASSPHRASE" ] || { aw_log error "answer file: LUKS_PASSPHRASE is required"; ok=1; }

  return "$ok"
}
