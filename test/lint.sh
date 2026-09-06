#!/usr/bin/env bash
# Single source of truth for the lint command, so it cannot drift between
# CLAUDE.md, the plan and CI. -x makes shellcheck follow sourced files.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

SHELLCHECK="${SHELLCHECK:-}"
if [ -z "$SHELLCHECK" ]; then
  if [ -x .tools/shellcheck/shellcheck.exe ]; then SHELLCHECK=.tools/shellcheck/shellcheck.exe
  elif command -v shellcheck >/dev/null 2>&1; then SHELLCHECK=shellcheck
  else
    echo "shellcheck not found: run tools/fetch-shellcheck.ps1 or install it" >&2
    exit 1
  fi
fi

mapfile -t files < <(git ls-files -co --exclude-standard '*.sh')
[ "${#files[@]}" -gt 0 ] || { echo "no shell scripts tracked yet" >&2; exit 0; }

"$SHELLCHECK" -x -P .:lib:test:test/unit "${files[@]}"
status=$?
[ "$status" -eq 0 ] && echo "lint clean (${#files[@]} files)"
exit "$status"
