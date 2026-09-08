#!/usr/bin/env bash
# The serial reader's escape handling.
#
# Everything the VM tooling knows about a guest arrives through Serial._feed,
# and what it fails to strip lands in the middle of a probe's output or a gate
# transcript. The case that actually bit: sudo on systemd 257 emits an OSC over
# a hundred characters long, so it routinely straddles two recv() calls, and a
# half-seen OSC was stripped by neither pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  # Loud, not silent. The rest of the suite is pure bash; this one file needs
  # an interpreter, and a machine without one should say so rather than report
  # a pass it did not earn.
  printf 'test_serial.sh: SKIPPED - no python3 on PATH\n' >&2
  exit 0
fi

out="$("$PY" - "$ROOT" <<'PY'
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "test" / "vm"))
import drive_vm as D

OSC = ("\x1b]3008;start=960e2fb6;user=test;hostname=archwright-vm;"
       "machineid=500307df;bootid=2e7aba1d;pid=931;comm=sudo;"
       "targetuser=root;type=session\x1b\\")


def feed(chunks):
    ser = D.Serial.__new__(D.Serial)
    ser.buf = ""
    ser._pending = ""
    for chunk in chunks:
        ser._feed(chunk)
    return ser.buf


results = []
# Whole, in one read.
results.append(("whole", feed(["before" + OSC + "after"])))
# Split inside the body - the case that leaked.
half = len(OSC) // 2
results.append(("split", feed(["before" + OSC[:half], OSC[half:] + "after"])))
# Split immediately after the introducer.
results.append(("introducer", feed(["before" + OSC[:2], OSC[2:] + "after"])))
# A CSI colour code, which was already handled and must stay handled.
results.append(("csi", feed(["be\x1b[32mfore", "after"])))
# Plain text must survive untouched.
results.append(("plain", feed(["before", "after"])))

for name, value in results:
    print(f"{name}={value}")
PY
)"

for case in whole split introducer csi plain; do
  line="$(printf '%s\n' "$out" | grep "^$case=" | cut -d= -f2-)"
  assert_eq "$line" "beforeafter" "_feed strips it: $case"
done

finish_tests
