#!/usr/bin/env bash
# Dependency-free assertion harness. Sourced by every test_*.sh.
set -uo pipefail

TESTS_RUN=0
# Failures are recorded in a FILE, not a variable. A variable incremented
# inside a pipeline or subshell is lost when it exits, which would let a
# failing assertion report as a pass. The file survives.
TESTS_FAILDB="$(mktemp)"

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '%s\n' "$1" >> "$TESTS_FAILDB"
  printf 'FAIL  %s\n      %s\n' "$1" "$2" >&2
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-assert_eq}"
  if [ "$actual" = "$expected" ]; then _pass
  else _fail "$label" "expected [$expected], got [$actual]"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-assert_contains}"
  case "$haystack" in
    *"$needle"*) _pass ;;
    *) _fail "$label" "expected to contain [$needle], got [$haystack]" ;;
  esac
}

# Assert that a command fails.
#
# Two traps this avoids:
#   * The command runs in a SUBSHELL, so a function that calls exit (aw_die)
#     is caught rather than terminating the whole test run.
#   * "Non-zero" is not enough. A misspelled or deleted function exits 127,
#     which would make this assertion pass while testing nothing at all -
#     verified by mutation: deleting aw_die entirely left the suite green.
#     So the command must exist, and 126/127 are treated as failures.
assert_fails() {
  local label="${!#}"
  set -- "${@:1:$#-1}"
  if ! command -v "$1" >/dev/null 2>&1; then
    _fail "$label" "command or function does not exist: $1"
    return
  fi
  local out status
  out="$( ( "$@" ) 2>&1 )"
  status=$?
  case "$status" in
    0)       _fail "$label" "expected non-zero exit, got 0" ;;
    126|127) _fail "$label" "not executable / not found (status $status): $out" ;;
    *)       _pass ;;
  esac
}

finish_tests() {
  local failed
  failed="$(wc -l < "$TESTS_FAILDB" | tr -d '[:space:]')"
  printf '%s: %d run, %s failed\n' "${0##*/}" "$TESTS_RUN" "$failed"
  rm -f "$TESTS_FAILDB"
  [ "$failed" -eq 0 ]
}
