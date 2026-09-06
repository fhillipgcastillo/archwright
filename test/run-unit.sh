#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$HERE"/unit/test_*.sh; do
  bash "$t" || failed=1
done
if [ "$failed" -ne 0 ]; then
  echo "UNIT TESTS FAILED" >&2
  exit 1
fi
echo "all unit tests passed"
