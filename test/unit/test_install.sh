#!/usr/bin/env bash
# install.sh's phase wiring.
#
# The phase list exists in three places that must agree: the validator for
# --phase, the run_phase calls, and the files in lib/. Milestone 5 shipped a
# phase that ran fine but was rejected by the validator, and the only thing
# that caught it was a five-minute VM run. These assertions catch it in a
# second.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"

INSTALL="$ROOT/install.sh"

# The declared list, read out of the script rather than duplicated here.
declared="$(sed -n 's/^AW_PHASES="\(.*\)"$/\1/p' "$INSTALL")"
if [ -n "$declared" ]; then _pass
else _fail "install.sh" "AW_PHASES is not declared as a single quoted line"; fi

# What the script actually runs, in order.
invoked="$(sed -n 's/^run_phase[[:space:]]\{1,\}\([a-z-]\{1,\}\).*/\1/p' "$INSTALL")"
if [ -n "$invoked" ]; then _pass
else _fail "install.sh" "no run_phase calls found - has the runner been renamed?"; fi

assert_eq "$(printf '%s' "$declared" | tr ' ' '\n' | tr -d '\r')" \
          "$(printf '%s' "$invoked")" \
  "the --phase whitelist matches the phases actually run, in order"

# Every phase must have a file, and that file must define the function the
# runner calls. run_phase composes the name as aw_<phase>, so a phase whose
# file defines something else fails only when that phase runs.
for phase in $declared; do
  file="$(sed -n "s/^run_phase[[:space:]]\{1,\}$phase[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p" "$INSTALL")"
  if [ -n "$file" ] && [ -f "$ROOT/lib/$file" ]; then _pass
  else _fail "install.sh" "phase $phase names no readable file in lib/ (got [$file])"; fi
  if grep -qE "^aw_$phase\(\)" "$ROOT/lib/$file" 2>/dev/null; then _pass
  else _fail "lib/$file" "does not define aw_$phase, which run_phase will call"; fi
done

# Every lib file that looks like a phase must be wired in. An orphan phase file
# is dead code that reads as shipped behaviour.
for f in "$ROOT"/lib/[0-9][0-9]-*.sh; do
  base="$(basename "$f")"
  if grep -q "run_phase .*$base" "$INSTALL"; then _pass
  else _fail "install.sh" "lib/$base exists but no run_phase call uses it"; fi
done

# The usage text has to list them too, or --help lies about what is available.
usage_block="$(sed -n '/^usage()/,/^}/p' "$INSTALL")"
for phase in $declared; do
  assert_contains "$usage_block" "$phase" "usage text mentions the $phase phase"
done

finish_tests
