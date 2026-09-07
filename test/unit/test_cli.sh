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

# update takes no arguments, and must say so rather than silently ignoring
# them - it is a command that changes every package on the machine.
assert_eq "$(status_of update nonsense)" "2" "update rejects arguments"
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

# A newline defeats `grep -qx`, which anchors each LINE rather than the whole
# string, so a two-line value passes if either line is a legal command name.
# The name is used to build a path and is then executed.
assert_eq "$(status_of default agent "$(printf 'codex\n../../etc/evil')")" "2" \
  "an embedded newline does not slip past the name check"
assert_eq "$(cat "$state" 2>/dev/null)" "codex" \
  "the multi-line name did not reach the state file"

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

# The CLI carries its own copy of the stub generator, so it needs its own copy
# of the validation - and its own proof. lib/agents.sh is tested separately;
# these assertions exist because the two can drift apart.
# Injection payloads: they must stay literal. See test_agents.sh.
# shellcheck disable=SC2016,SC1003
for bad in 'npm:x\' 'npm:x"y' 'npm:x$y' 'npm:x`y' 'npm:x;y' 'npm:x|y' 'npm:x&y'; do
  assert_eq "$(status_of mise-install "$bad" tool)" "2" \
    "mise-install rejects the spec [$bad]"
done
# shellcheck disable=SC2016,SC1003
for bad in '$(id)x' '`id`' 'a;id' 'a|id' '*' 'a b' 'a\b' 'a"b'; do
  assert_eq "$(status_of mise-install npm:x "$bad")" "2" \
    "mise-install rejects the command name [$bad]"
done

# Pinning a version is the main reason to run mise-install by hand rather than
# add a manifest row, so the specs mise actually documents have to be accepted.
# Tightening the filter to close the injection hole rejected all of these.
i=0
for good in 'npm:@openai/codex@0.20.0' 'npm:typescript@5.4.5' 'node@22' \
            'go:github.com/owner/tool@latest' 'npm:opencode-ai'; do
  i=$((i + 1))
  assert_eq "$(status_of mise-install "$good" "pinned$i")" "0" \
    "mise-install accepts the spec [$good]"
done

# WITHOUT an explicit name, which is the half that was broken. The validator
# accepted every pinned spec above and the name inference then rejected it as
# "not a usable command name" - and the loop above hid that by always passing a
# name. A test that steps around the broken half of a feature is not a test.
assert_eq "$(status_of mise-install 'npm:@openai/codex@0.20.0')" "0" \
  "a pinned scoped spec infers its command name"
if [ -x "$tmp/home/.local/bin/codex" ]; then _pass
else _fail "cli" "the inferred name kept the version pin"; fi
assert_eq "$(status_of mise-install 'node@22')" "0" \
  "a backendless pinned spec infers its command name"
if [ -x "$tmp/home/.local/bin/node" ]; then _pass
else _fail "cli" "node@22 did not infer the name 'node'"; fi

# A traversal in a spec is inert - it only ever reaches mise inside quotes -
# but a field the source calls a security boundary should not accept one. The
# first version of this check needed a slash beside the dots, so a bare '..'
# and 'npm:../x' both walked through it.
for bad in 'npm:@scope/a/../../../etc' '..' 'npm:..' 'npm:../x' '../x' 'a/../b'; do
  assert_eq "$(status_of mise-install "$bad" tool)" "2" \
    "mise-install rejects the traversal [$bad]"
done

# Whatever survives validation must PARSE. Greping the generated stub for a
# substring would pass on a file that is not valid bash - which is exactly how
# the backslash case shipped.
aw_cli mise-install npm:@scope/pkg.name-1_2 parsecheck >/dev/null 2>&1
if bash -n "$tmp/home/.local/bin/parsecheck" 2>/dev/null; then _pass
else _fail "cli" "mise-install generated a stub that is not valid bash"; fi

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

# There is deliberately NO assertion here that the sudoers directory stayed
# empty. Two attempts at one were both worthless: the first searched $HOME,
# which the CLI never writes to; the second created its own empty directory and
# then checked it was empty. Making it real would need an override of the
# sudoers path inside the script - and sudo strips that under env_reset, so the
# sandboxed path is unreachable from a non-root test anyway.
#
# What these tests can honestly prove is that a bad argument exits 2 before the
# root re-exec, which is what the loop above does. The write path is gated in
# the VM, against a real root and a real sudoers file.

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
