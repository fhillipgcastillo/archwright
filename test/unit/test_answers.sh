#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/answers.sh
. "$ROOT/lib/answers.sh"

aw_answers_load "$ROOT/test/vm/answers.example.conf"
assert_eq "$AW_DISK" "/dev/vda" "disk parsed"
assert_eq "$AW_HOSTNAME" "archwright-vm" "hostname parsed"
assert_eq "$AW_SERIAL_CONSOLE" "1" "serial console flag parsed"
assert_eq "$AW_TIMEZONE" "UTC" "timezone parsed"
if aw_answers_validate 2>/dev/null; then _pass; else _fail "example answers" "example file should validate"; fi

tmp="$(mktemp -d)"
printf 'HOSTNAME=nodisk\n' > "$tmp/bad.conf"
aw_answers_load "$tmp/bad.conf"
assert_fails aw_answers_validate "missing DISK fails validation"

# Injection guard: a value must never be executed.
pwned="$tmp/aw-pwned"
{
  # shellcheck disable=SC2016
  # Deliberately literal: this is the payload the loader must NOT execute.
  printf 'HOSTNAME=$(touch %s)\n' "$pwned"
  printf 'DISK=/dev/vda\n'
  printf 'USERNAME=u\n'
  printf 'USER_PASSWORD=p\n'
  printf 'LUKS_PASSPHRASE=l\n'
} > "$tmp/evil.conf"
rm -f "$pwned"
aw_answers_load "$tmp/evil.conf"
if [ ! -e "$pwned" ]; then _pass; else _fail "injection" "answer value was executed"; fi
assert_eq "$AW_HOSTNAME" "\$(touch $pwned)" "value kept literal"


# ---------------------------------------------------------------------------
# Regressions found by adversarial review (2026-09-06)
# ---------------------------------------------------------------------------

# BLOCKER: an answer file authored on Windows (or checked out with
# core.autocrlf=true) carries CR. Without stripping it, AW_DISK becomes
# "/dev/vda\r", validation PASSES, and the installer fails much later with an
# error that never names the real cause.
printf 'DISK=/dev/vda\r\nHOSTNAME=box\r\nUSERNAME=u\r\nUSER_PASSWORD=p\r\nLUKS_PASSPHRASE=l\r\nSERIAL_CONSOLE=1\r\n' > "$tmp/crlf.conf"
aw_answers_load "$tmp/crlf.conf"
assert_eq "$AW_DISK" "/dev/vda" "CRLF stripped from values"
assert_eq "$AW_SERIAL_CONSOLE" "1" "CRLF stripped from the serial flag"
if aw_answers_validate 2>/dev/null; then _pass; else _fail "crlf validates" "should validate after CR stripping"; fi

# Trailing whitespace must not reach /etc/hostname.
printf 'DISK=/dev/vda\nHOSTNAME=box   \nUSERNAME=u\nUSER_PASSWORD=p\nLUKS_PASSPHRASE=l\n' > "$tmp/ws.conf"
aw_answers_load "$tmp/ws.conf"
assert_eq "$AW_HOSTNAME" "box" "trailing whitespace trimmed"

# An inline comment is a natural thing to write given the shipped example uses
# comment lines.
printf 'DISK=/dev/vda   # the target disk\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD=p\nLUKS_PASSPHRASE=l\n' > "$tmp/inline.conf"
aw_answers_load "$tmp/inline.conf"
assert_eq "$AW_DISK" "/dev/vda" "inline comment stripped"

# ... but a '#' inside a quoted value is data, not a comment. Passwords
# routinely contain '#', and eating it would lock the user out of the machine.
printf 'DISK=/dev/vda\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD="p#ss word "\nLUKS_PASSPHRASE=l\n' > "$tmp/quoted.conf"
aw_answers_load "$tmp/quoted.conf"
assert_eq "$AW_USER_PASSWORD" "p#ss word " "quoted value kept verbatim, including # and spaces"

# An unquoted value keeps a bare '#' that is not preceded by whitespace.
printf 'DISK=/dev/vda\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD=p#ss\nLUKS_PASSPHRASE=l\n' > "$tmp/hash.conf"
aw_answers_load "$tmp/hash.conf"
assert_eq "$AW_USER_PASSWORD" "p#ss" "bare # without preceding space is data"

# An indented comment line is a comment.
printf 'DISK=/dev/vda\n   # HOSTNAME=wrong\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD=p\nLUKS_PASSPHRASE=l\n' > "$tmp/indent.conf"
aw_answers_load "$tmp/indent.conf" 2>"$tmp/warn.txt"
assert_eq "$AW_HOSTNAME" "box" "indented comment ignored"
if grep -q "unknown answer key" "$tmp/warn.txt"; then
  _fail "indented comment" "warned about a commented-out line"
else _pass; fi

# Values are interpolated into shell commands downstream (aw_run_in_chroot),
# so validation - not just 'we do not source the file' - is what keeps a
# metacharacter out of a root shell.
mkbase() {
  printf 'DISK=/dev/vda\nHOSTNAME=box\nUSERNAME=u\nUSER_PASSWORD=p\nLUKS_PASSPHRASE=l\n%s\n' "$1" > "$tmp/v.conf"
  aw_answers_load "$tmp/v.conf"
}
mkbase 'USERNAME=u; touch /tmp/PWNED'
assert_fails aw_answers_validate "username with a shell metacharacter is rejected"
# shellcheck disable=SC2016
# Literal on purpose: this is the payload validation must reject.
mkbase 'HOSTNAME=$(id)'
assert_fails aw_answers_validate "hostname with command substitution is rejected"
mkbase 'DISK=/dev/vda; rm -rf /'
assert_fails aw_answers_validate "disk with a shell metacharacter is rejected"
mkbase 'TIMEZONE=../../etc/shadow'
assert_fails aw_answers_validate "timezone with path traversal is rejected"
mkbase 'USERNAME=Bad_Upper'
assert_fails aw_answers_validate "username must be lowercase"
mkbase 'SERIAL_CONSOLE=yes'
assert_fails aw_answers_validate "serial console must be 0 or 1"

# Valid values still pass.
mkbase 'TIMEZONE=America/New_York'
if aw_answers_validate 2>/dev/null; then _pass; else _fail "valid tz" "America/New_York should validate"; fi


# AUTOLOGIN: a real supported option (single-user laptops), which the test
# harness also relies on because it cannot type into tuigreet on VT1.
aw_answers_load "$ROOT/test/vm/answers.example.conf"
assert_eq "$AW_AUTOLOGIN" "1" "autologin parsed from the example answers"

printf 'DISK=/dev/vda
HOSTNAME=box
USERNAME=u
USER_PASSWORD=p
LUKS_PASSPHRASE=l
' > "$tmp/noauto.conf"
aw_answers_load "$tmp/noauto.conf"
assert_eq "$AW_AUTOLOGIN" "0" "autologin defaults to off"

mkbase 'AUTOLOGIN=yes'
assert_fails aw_answers_validate "autologin must be 0 or 1"

rm -rf "$tmp"
finish_tests
