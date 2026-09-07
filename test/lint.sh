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

# --- `cmd | grep -q` under pipefail ------------------------------------------
#
# Not something static analysis catches, and it has cost two debugging rounds -
# recorded as L46 in milestone 5 and again as L70 in milestone 6, where it came
# back in new code two milestones after being written down. A lesson in a log
# does not prevent a mistake; a check that fails does.
#
# The bug: under `set -o pipefail`, a pipeline reports the FIRST non-zero exit,
# not the last command's verdict. So
#
#     if archwright theme list | grep -q mocha; then
#
# is false whenever archwright exits non-zero, regardless of what grep found -
# and true only when both succeed. Used as a condition, it silently inverts.
#
# Deliberately narrow. `printf | grep -q` is fine because printf does not fail,
# and flagging it would produce noise nobody reads. What is flagged is a
# pipeline STARTING with a command whose non-zero exit is a normal outcome.
# Capture the output first and match against the variable.
#
# Escape hatch for a case where the exit status genuinely is part of the test:
# put `# lint-ok: pipefail` on the same line.
RISKY='archwright|aw_cli|aw_user_run|hyprctl_user|runuser|pacman|systemctl|journalctl|snapper|foot|fuzzel|hyprctl'
pipefail_problems=0
for f in "${files[@]}"; do
  grep -q 'set .*pipefail' "$f" 2>/dev/null || continue
  while IFS= read -r hit; do
    case "$hit" in *"lint-ok: pipefail"*) continue ;; esac
    # A comment is not code. The first version of this rule flagged its own
    # worked example, three lines above.
    case "${hit#*:*:}" in [[:space:]]*'#'*|'#'*) continue ;; esac
    printf '%s\n' "$hit"
    pipefail_problems=$((pipefail_problems + 1))
  done < <(grep -HnE "(^|[;&|]|\bif |\bwhile |\`|\\\$\()[[:space:]]*($RISKY)\b[^|]*\| *grep -q" "$f" 2>/dev/null)
done

if [ "$pipefail_problems" -ne 0 ]; then
  cat >&2 <<'EOF'

Above: a command whose exit status matters is piped into `grep -q` in a file
using `set -o pipefail`. The pipeline reports the command's exit status, not
grep's verdict, so the condition inverts silently.

Capture first, then match:

    out="$(the_command 2>&1)"
    printf '%s' "$out" | grep -q 'what you want'

If the exit status really is part of what you are testing, add
`# lint-ok: pipefail` to the line.
EOF
  status=1
fi

[ "$status" -eq 0 ] && echo "lint clean (${#files[@]} files)"
exit "$status"
