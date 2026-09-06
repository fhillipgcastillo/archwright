#!/usr/bin/env bash
# Dependency-free assertion harness. Sourced by every test_*.sh.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
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

# The command under test runs in a SUBSHELL. Functions like aw_die call exit,
# which would otherwise terminate the test runner rather than being caught.
assert_fails() {
  local label="${!#}"
  set -- "${@:1:$#-1}"
  if ( "$@" ) >/dev/null 2>&1; then
    _fail "$label" "expected non-zero exit, got 0"
  else
    _pass
  fi
}

finish_tests() {
  printf '%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
