#!/usr/bin/env bash
# The archwright CLI (spec sections 9.2 and 9.4).
#
# Everything here runs the real script in a subprocess with HOME pointed at a
# temp directory, so the CLI is exercised as a user would run it rather than by
# sourcing its internals. Nothing in this file may reach /etc or call sudo: the
# grant path is gated in the VM, where there is a real root and a real sudoers
# file to break.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"

CLI="$ROOT/bin/archwright"

# A function rather than a bare invocation so assert_fails can find it, and so
# every call gets the sandboxed HOME.
#
# PATH is sandboxed too, and that is not paranoia: the developer running this
# suite very likely has a real `claude` on their PATH, in which case the
# "launching a missing agent fails" case quietly LAUNCHED CLAUDE instead of
# testing anything. The CLI looks in ~/.local/bin first and falls back to PATH,
# so both halves need a PATH we control.
aw_cli() { HOME="$tmp/home" PATH="/usr/bin:/bin" bash "$CLI" "$@"; }

status_of() { aw_cli "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# Capture stderr on its own. Not through a pipe: this file runs under
# `set -o pipefail`, so `cli ... | grep` reports the CLI's non-zero exit rather
# than grep's verdict, and every such check silently inverts.
stderr_of() { { aw_cli "$@" >/dev/null; } 2>&1; }

# --- help and version --------------------------------------------------------
assert_eq "$(status_of help)" "0" "help exits 0"
assert_eq "$(status_of --help)" "0" "--help is the same as help"
assert_eq "$(status_of)" "0" "a bare invocation prints help rather than failing"

help_text="$(aw_cli help 2>&1)"
for sub in agent default mise-install sudo-window version help; do
  assert_contains "$help_text" "$sub" "help documents the $sub subcommand"
done

assert_eq "$(status_of version)" "0" "version exits 0"

# An unknown subcommand must fail loudly rather than doing nothing quietly.
assert_eq "$(status_of no-such-subcommand)" "2" "an unknown subcommand exits 2"
if [ -n "$(stderr_of no-such-subcommand)" ]; then _pass
else _fail "cli" "an unknown subcommand said nothing on stderr"; fi

# --- default agent -----------------------------------------------------------
state="$tmp/home/.local/state/archwright/default-agent"

# Reading before anything is set must yield the documented fallback, not empty.
assert_eq "$(aw_cli default agent)" "claude" "the default agent falls back to claude"

assert_eq "$(status_of default agent codex)" "0" "setting the default agent succeeds"
assert_eq "$(cat "$state" 2>/dev/null)" "codex" "the choice is written to state"
assert_eq "$(aw_cli default agent)" "codex" "the choice is read back"

# The name is used to build a path and is later executed, so it is validated
# with the same charset rule the answer file uses.
for bad in "../../etc/passwd" "a b" "rm -rf /" "" "Codex"; do
  assert_eq "$(status_of default agent "$bad")" "2" "default agent rejects [$bad]"
done
assert_eq "$(cat "$state" 2>/dev/null)" "codex" "a rejected name does not overwrite the state"

assert_eq "$(status_of default nosuch value)" "2" "an unknown default key exits 2"

# --- mise-install ------------------------------------------------------------
assert_eq "$(status_of mise-install npm:some-tool some-tool)" "0" \
  "mise-install writes a stub"
newstub="$tmp/home/.local/bin/some-tool"
if [ -x "$newstub" ]; then _pass
else _fail "cli" "mise-install did not produce an executable stub"; fi
assert_contains "$(cat "$newstub" 2>/dev/null)" "npm:some-tool" \
  "the stub names the requested spec"

# The command name defaults to the tail of the spec when one is not given.
assert_eq "$(status_of mise-install npm:@scope/other)" "0" \
  "mise-install infers the command name from the spec"
if [ -x "$tmp/home/.local/bin/other" ]; then _pass
else _fail "cli" "mise-install did not infer the command name"; fi

assert_eq "$(status_of mise-install)" "2" "mise-install with no spec exits 2"
assert_eq "$(status_of mise-install "npm:a b")" "2" \
  "mise-install rejects a spec containing whitespace"

# An existing file is never clobbered: the user may have installed the real
# thing there, and losing it to a stub would be silent.
printf 'MINE\n' > "$tmp/home/.local/bin/precious"
aw_cli mise-install npm:precious precious >/dev/null 2>&1
assert_eq "$(cat "$tmp/home/.local/bin/precious")" "MINE" \
  "an existing command is never overwritten"

# --- sudo-window: validation only -------------------------------------------
#
# The minutes argument is checked BEFORE anything re-execs under sudo, so these
# cases never need root and never touch /etc.
for bad in "abc" "0" "-5" "1.5" "241" "15m" "" "1 2"; do
  assert_eq "$(status_of sudo-window "$bad")" "2" "sudo-window rejects [$bad]"
done

# It must not have created anything anywhere in the sandbox while refusing.
if find "$tmp/home" -name '*sudo*' | grep -q .; then
  _fail "cli" "a rejected sudo-window left a file behind"
else _pass; fi

# --- agent -------------------------------------------------------------------
# With no stub and no such command installed, launching must fail with a
# message rather than exiting 0 having done nothing.
assert_eq "$(status_of default agent claude)" "0" "reset the default for the launch test"
assert_eq "$(status_of agent)" "1" "launching a missing agent fails"
assert_contains "$(stderr_of agent)" "claude" \
  "the launch failure names the agent it could not find"

# The launcher must run the agent, forward arguments, and move out of $HOME:
# agents refuse to trust the home directory as a workspace.
mkdir -p "$tmp/home/.local/bin"
printf '%s\n' '#!/usr/bin/env bash' 'pwd' 'printf "args:%s\n" "$*"' \
  > "$tmp/home/.local/bin/claude"
chmod 0755 "$tmp/home/.local/bin/claude"
mkdir -p "$tmp/home/Work"

out="$(cd "$tmp/home" && HOME="$tmp/home" PATH="/usr/bin:/bin" bash "$CLI" agent --flag value 2>&1)"
assert_contains "$out" "args:--flag value" "the launcher forwards its arguments"
assert_contains "$out" "Work" "a launch from HOME is redirected to ~/Work"

mkdir -p "$tmp/elsewhere"
out2="$(cd "$tmp/elsewhere" && HOME="$tmp/home" PATH="/usr/bin:/bin" bash "$CLI" agent 2>&1)"
if printf '%s' "$out2" | grep -q "elsewhere"; then _pass
else _fail "cli" "a launch outside HOME must stay where it is, got [$out2]"; fi

finish_tests
