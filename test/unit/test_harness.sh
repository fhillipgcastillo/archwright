#!/usr/bin/env bash
# Tests for the test harness itself.
#
# A harness that reports a pass when it should report a failure makes every
# other test in the suite worthless, so it gets its own coverage. Adversarial
# review found exactly that: assert_fails accepted status 127, so deleting the
# function under test left the suite green.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"

# Run a harness assertion in an isolated subshell with its own fresh harness,
# and report whether that inner suite passed or failed.
outcome() {
  # shellcheck source=test/unit/harness.sh
  if ( . "$HERE/harness.sh"; "$@"; finish_tests ) >/dev/null 2>&1; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

really_fails() { return 3; }
really_succeeds() { return 0; }
exits_nonzero() { exit 7; }

assert_eq "$(outcome assert_eq a a lbl)" "pass" "assert_eq passes on equal values"
assert_eq "$(outcome assert_eq a b lbl)" "fail" "assert_eq fails on different values"

assert_eq "$(outcome assert_contains abcdef cde lbl)" "pass" "assert_contains finds a substring"
assert_eq "$(outcome assert_contains abcdef xyz lbl)" "fail" "assert_contains rejects a missing substring"

assert_eq "$(outcome assert_fails really_fails lbl)" "pass" "assert_fails accepts a genuine failure"
assert_eq "$(outcome assert_fails really_succeeds lbl)" "fail" "assert_fails rejects success"
assert_eq "$(outcome assert_fails exits_nonzero lbl)" "pass" "assert_fails catches exit without killing the run"

# The regression: a deleted or misspelled function exits 127, which must NOT
# be read as 'the code correctly rejected bad input'.
assert_eq "$(outcome assert_fails no_such_function_xyz lbl)" "fail" \
  "assert_fails rejects a nonexistent command instead of passing"

# A failure recorded inside a subshell or pipeline must still fail the suite.
sub_fail() { printf 'x\n' | while read -r _; do assert_eq 1 2 inner; done; }
assert_eq "$(outcome sub_fail)" "fail" "a failure inside a pipeline still fails the suite"

finish_tests
