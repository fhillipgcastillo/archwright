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
rm -rf "$AW_TRACK_DIR"

finish_tests
