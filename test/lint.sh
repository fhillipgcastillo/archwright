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

# '*.sh' alone missed bin/ entirely. Commands installed onto the finished
# system have no extension by design, so the most security-sensitive file in
# the repo - the one that writes to /etc/sudoers.d - sat outside the lint gate
# from the day it was added. Take bin/ by path instead of by extension.
mapfile -t files < <(git ls-files -co --exclude-standard '*.sh' 'bin/*' | sort -u)
[ "${#files[@]}" -gt 0 ] || { echo "no shell scripts tracked yet" >&2; exit 0; }

# No -s here, deliberately. It was added on the belief that shellcheck infers
# the dialect from the extension and so could not read the extensionless bin/
# files; it infers from the SHEBANG, which those files have. What -s actually
# does is OVERRIDE every in-file `# shellcheck shell=` directive - which would
# switch off all POSIX checking on config/profile.d/archwright-agents.sh, a
# file sourced by /etc/profile in whatever shell the user logs in with. A
# `[[ ]]` or a `local` added there would then pass lint and break the login.
"$SHELLCHECK" -x -P .:lib:test:test/unit "${files[@]}"
status=$?
[ "$status" -eq 0 ] && echo "lint clean (${#files[@]} files)"
exit "$status"
