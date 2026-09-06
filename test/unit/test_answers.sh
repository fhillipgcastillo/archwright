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

rm -rf "$tmp"
finish_tests
