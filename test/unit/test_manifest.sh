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

tmp="$(mktemp -d)"

# Fixture written with printf so the trailing whitespace on 'beta' and the
# tabs in the tsv are explicit rather than invisible.
printf '%s\n' \
  '# a comment' \
  '## Group: one' \
  'alpha' \
  '' \
  'beta   ' \
  '## Group: two' \
  'gamma' > "$tmp/p.packages"

got="$(aw_manifest_packages "$tmp/p.packages" | tr '\n' ',')"
assert_eq "$got" "alpha,beta,gamma," "packages: comments, blanks and group headers stripped"

printf '# header comment\n@\t/\tcompress=zstd:1,noatime\n@home\t/home\tcompress=zstd:1,noatime\n' \
  > "$tmp/s.tsv"

got="$(aw_manifest_subvolumes "$tmp/s.tsv" | wc -l | tr -d ' ')"
assert_eq "$got" "2" "subvolumes: two data rows"

first="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f1)"
assert_eq "$first" "@" "subvolumes: first field is the subvolume name"

third="$(aw_manifest_subvolumes "$tmp/s.tsv" | head -1 | cut -f3)"
assert_eq "$third" "compress=zstd:1,noatime" "subvolumes: third field is mount options"

assert_fails aw_manifest_packages "$tmp/does-not-exist" "missing manifest fails loudly"

# The real shipped manifests must parse and be non-empty.
n="$(aw_manifest_packages "$ROOT/manifest/core.packages" | wc -l | tr -d ' ')"
if [ "$n" -gt 10 ]; then _pass; else _fail "core.packages" "expected >10 packages, got $n"; fi

n="$(aw_manifest_subvolumes "$ROOT/manifest/subvolumes.tsv" | wc -l | tr -d ' ')"
assert_eq "$n" "5" "shipped subvolumes.tsv has 5 rows"

rm -rf "$tmp"
finish_tests
