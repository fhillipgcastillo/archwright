#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$ROOT/lib/manifest.sh"
# shellcheck source=lib/agents.sh
. "$ROOT/lib/agents.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- the generated stub text -------------------------------------------------
stub="$(aw_agent_stub_text claude npm:@anthropic-ai/claude-code claude)"

assert_eq "$(printf '%s\n' "$stub" | head -1)" "#!/usr/bin/env bash" \
  "a stub is a bash script"
assert_contains "$stub" "npm:@anthropic-ai/claude-code" "the stub names its mise spec"
assert_contains "$stub" "exec mise exec" "the stub execs mise rather than forking it"

# Arguments MUST reach the agent. A stub that silently drops them looks like it
# works right up until someone passes a prompt or a flag.
assert_contains "$stub" '"$@"' "the stub forwards its arguments"

# The literal string must survive generation unexpanded. If the generator ever
# interpolates it, every stub launches its agent with no arguments at all and
# nothing else in the suite would notice.
if printf '%s\n' "$stub" | grep -q 'exec mise exec .* -- claude "\$@"$'; then _pass
else _fail "stub" "the exec line is malformed: $(printf '%s\n' "$stub" | tail -1)"; fi

# The spec is quoted: an npm scope contains '@' and '/', and an unquoted word
# split would hand mise two arguments instead of one.
if printf '%s\n' "$stub" | grep -q 'mise exec "npm:@anthropic-ai/claude-code"'; then _pass
else _fail "stub" "the mise spec is not quoted"; fi

# A generated stub must be valid bash. This catches a whole class of quoting
# mistakes that reading the text does not.
printf '%s\n' "$stub" > "$tmp/claude"
if bash -n "$tmp/claude" 2>/dev/null; then _pass
else _fail "stub" "the generated stub is not syntactically valid bash"; fi

# The executable can differ from the command name: mise-install wraps CLIs
# whose package and binary are named differently.
other="$(aw_agent_stub_text ai npm:some-package other-bin)"
assert_contains "$other" "-- other-bin" "the executable name is used, not the command name"

# --- writing the stub tree ---------------------------------------------------
printf '%s\n' \
  '# fixture' \
  'claude	npm:@anthropic-ai/claude-code	claude' \
  'codex	npm:@openai/codex	codex' > "$tmp/a.tsv"

aw_agent_write_stubs "$tmp/a.tsv" "$tmp/stubs"

stub_names() { find "$1" -maxdepth 1 -type f -exec basename {} \; | sort | tr '\n' ','; }
stub_count() { find "$1" -maxdepth 1 -type f | wc -l | tr -d ' '; }

assert_eq "$(stub_names "$tmp/stubs")" "claude,codex," \
  "one stub per manifest row, named for the command"
if [ -x "$tmp/stubs/claude" ]; then _pass
else _fail "stubs" "the generated stub is not executable"; fi
assert_contains "$(cat "$tmp/stubs/codex")" "npm:@openai/codex" \
  "each stub gets its own spec"

# Regenerating must be idempotent - the phase runs on every install and on
# every update, and the tree it owns is refreshed, not appended to.
aw_agent_write_stubs "$tmp/a.tsv" "$tmp/stubs"
assert_eq "$(stub_count "$tmp/stubs")" "2" "regenerating does not duplicate"

# A name that is not a plain command name would let a manifest write outside
# the destination directory.
printf '%s\n' '../../etc/evil	npm:x	x' > "$tmp/bad.tsv"
assert_fails aw_agent_write_stubs "$tmp/bad.tsv" "$tmp/stubs2" \
  "a path-like agent name is refused"
if [ -e "$tmp/stubs2/../../etc/evil" ]; then
  _fail "stubs" "a path-like name escaped the destination directory"
else _pass; fi

printf '%s\n' 'ok	np m:x	x' > "$tmp/bad2.tsv"
assert_fails aw_agent_write_stubs "$tmp/bad2.tsv" "$tmp/stubs3" \
  "a spec containing whitespace is refused"

# --- the third field is a command-injection sink -----------------------------
#
# name and spec had charset gates from the start; bin had only an empty/space
# check, and bin is the field interpolated UNQUOTED into the generated script.
# The most dangerous field had the weakest validation. This is the proof:
#
#   exec mise exec "npm:x" -- $(id>/tmp/pwned)x "$@"
#
# passes `bash -n`, so "the generated stub is valid bash" did not catch it
# either. The stub is then chmod 0755, seeded onto the login PATH and wired to
# a compositor keybind.
i=0
# These are injection payloads and must reach the code as literal text.
# Expanding them here is precisely what the assertion is testing does not
# happen, so the single quotes are the point rather than an oversight.
# shellcheck disable=SC2016,SC1003
for evil in '$(id)x' '`id`' 'a;id' 'a|id' 'a&id' 'a>x' '*' 'a"b' "a'b" 'a$b' 'a\b'; do
  i=$((i + 1))
  printf 'ok\tnpm:x\t%s\n' "$evil" > "$tmp/inj$i.tsv"
  assert_fails aw_agent_write_stubs "$tmp/inj$i.tsv" "$tmp/inj$i" \
    "an executable name containing [$evil] is refused"
done

# A backslash survives the unquoted heredoc and is then re-read as an escape
# inside the generated double-quoted string, producing a stub that is not valid
# bash - reported as success.
printf '%s\n' 'ok	npm:x\	x' > "$tmp/bs.tsv"
assert_fails aw_agent_write_stubs "$tmp/bs.tsv" "$tmp/bsout" \
  "a spec containing a backslash is refused"

# Belt and braces: whatever the filters allow, the result must parse. If a new
# character is ever added to the allowed set, this fails before the stub ships.
printf '%s\n' 'ok	npm:@scope/pkg.name-1_2	some.bin-1_2' > "$tmp/edge.tsv"
aw_agent_write_stubs "$tmp/edge.tsv" "$tmp/edgeout"
if bash -n "$tmp/edgeout/ok" 2>/dev/null; then _pass
else _fail "stubs" "a stub built from legal punctuation is not valid bash"; fi

# --- the stub tree is OURS, so a removed row must disappear from it ----------
printf '%s\n' 'one	npm:a	a' 'two	npm:b	b' > "$tmp/two.tsv"
printf '%s\n' 'one	npm:a	a' > "$tmp/one.tsv"
aw_agent_write_stubs "$tmp/two.tsv" "$tmp/own"
assert_eq "$(stub_names "$tmp/own")" "one,two," "both rows generate"
aw_agent_write_stubs "$tmp/one.tsv" "$tmp/own"
assert_eq "$(stub_names "$tmp/own")" "one," \
  "a row removed from the manifest is removed from the stub tree"

# --- the shipped manifest generates valid stubs ------------------------------
aw_agent_write_stubs "$ROOT/manifest/agents.tsv" "$tmp/real"
for f in "$tmp/real"/*; do
  if bash -n "$f" 2>/dev/null; then _pass
  else _fail "stubs" "shipped manifest generated invalid bash: $f"; fi
done

finish_tests
