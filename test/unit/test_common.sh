#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

# aw_log respects AW_LOG_LEVEL
AW_LOG_LEVEL=warn
out="$(aw_log info "quiet please" 2>&1)"
assert_eq "$out" "" "info suppressed at warn level"

out="$(aw_log error "loud" 2>&1)"
assert_contains "$out" "loud" "error emitted at warn level"

AW_LOG_LEVEL=info
out="$(aw_log info "hello" 2>&1)"
assert_contains "$out" "hello" "info emitted at info level"
assert_contains "$out" "INFO" "log line carries its level"

# aw_die exits non-zero
assert_fails aw_die "boom" "aw_die exits non-zero"

# aw_require_cmd
assert_fails aw_require_cmd "definitely-not-a-real-command-xyz" "missing command fails"
if aw_require_cmd sh; then _pass; else _fail "require_cmd sh" "sh should exist"; fi

# rollback tracking round-trips
AW_TRACK_DIR="$(mktemp -d)"
aw_track partition "/dev/vda1"
aw_track partition "/dev/vda2"
aw_track luks "cryptroot"
assert_eq "$(aw_tracked partition | tr '\n' ',')" "/dev/vda1,/dev/vda2," "tracked partitions in order"
assert_eq "$(aw_tracked luks)" "cryptroot" "tracked luks name"
assert_eq "$(aw_tracked nothing)" "" "unknown kind is empty, not an error"

# cross-phase state round-trips (each install.sh --phase is its own process)
aw_state_set esp_dev "/dev/vda1"
assert_eq "$(aw_state_get esp_dev)" "/dev/vda1" "state value round-trips"
assert_fails aw_state_get no_such_key "a missing state key fails rather than returning empty"
rm -rf "$AW_TRACK_DIR"

# ---------------------------------------------------------------------------
# Secure Boot detection
#
# The most likely real-hardware blocker, and invisible in QEMU because OVMF
# ships with Secure Boot off. Tested against fixtures shaped like the real
# efivars file: four attribute bytes, then the value byte.
#
# The four header bytes are deliberately printable ASCII - aw_secureboot_state
# skips them without inspecting them, so their content is irrelevant, and this
# keeps the test file out of binary territory.
# ---------------------------------------------------------------------------
sbdir="$(mktemp -d)"
sbvar="$sbdir/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

printf 'HDR1' > "$sbvar"
printf '\001' >> "$sbvar"
aw_secureboot_state "$sbdir"
assert_eq "$?" "0" "secure boot ON is detected"

printf 'HDR1' > "$sbvar"
printf '\000' >> "$sbvar"
aw_secureboot_state "$sbdir"
assert_eq "$?" "1" "secure boot OFF is detected"

rm -f "$sbvar"
aw_secureboot_state "$sbdir"
assert_eq "$?" "2" "a missing EFI variable is 'unknown', never 'off'"

aw_secureboot_state "$sbdir/does-not-exist"
assert_eq "$?" "2" "a missing efivars directory is 'unknown'"

rm -rf "$sbdir"

finish_tests
