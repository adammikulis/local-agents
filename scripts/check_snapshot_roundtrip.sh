#!/usr/bin/env bash

# Capture the field, wipe every cell to nothing, put the capture back: bit-for-bit, and again through the
# bytes a save file holds. The wipe is the positive control. Asserts every declared channel is covered,
# the CPU mirrors came back, the totals read the same, and another world's snapshot is refused.
# Usage:  scripts/check_snapshot_roundtrip.sh [--path DIR] [--frames N]
# EXIT 0 the round trip is exact - 1 it is not - 2 the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib_require.sh
. "$ROOT/scripts/lib_require.sh"
require_tool python3

PROJ="$ROOT"
FRAMES=8   # the layout, not the elapsed time; `lost` and `nonzero` are the positive controls
while [ $# -gt 0 ]; do
  case "$1" in
    --path) PROJ="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    *) echo "check_snapshot_roundtrip: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

OUT="$("$SCRIPT_DIR/sim_run.sh" --path "$PROJ" --frames "$FRAMES" --keep -- --snapshot-roundtrip 2>&1)"
RC=$?
LOG="$(printf '%s\n' "$OUT" | sed -n 's/^sim_run: log kept at //p' | tail -1)"
if [ -z "$LOG" ] || [ ! -s "$LOG" ]; then
  echo "check_snapshot_roundtrip: the arm left no log (sim_run exit $RC), so nothing was measured." >&2
  printf '%s\n' "$OUT" | tail -20 >&2
  exit 2
fi
LINE="$(grep -m1 '^SNAPSHOT_ROUNDTRIP=' "$LOG")"
REFUSAL="$(grep -c '^SNAPSHOT_REFUSED=' "$LOG")"
rm -f "$LOG"
if [ -z "$LINE" ]; then
  echo "check_snapshot_roundtrip: the run published no SNAPSHOT_ROUNDTRIP line (sim_run exit $RC)." >&2
  printf '%s\n' "$OUT" | tail -20 >&2
  exit 2
fi

REFUSAL="$REFUSAL" python3 - "$LINE" <<'PY'
import os, re, sys

line = sys.argv[1]
got = dict(re.findall(r'(\w+):([^,}]+)', line[len("SNAPSHOT_ROUNDTRIP={"):]))
print(line)

def num(k):
    try:
        return float(got[k])
    except (KeyError, ValueError):
        print("check_snapshot_roundtrip: the line carries no readable '%s'." % k, file=sys.stderr)
        sys.exit(2)

fail = []
if num("cells") <= 0:
    fail.append("the snapshot holds no cells, so it asserts nothing")
# EVERY CHANNEL THE WORLD DECLARES. A snapshot short of one leaves that channel holding the world the
# restore was supposed to undo.
if num("channels") != num("declared"):
    fail.append("the snapshot covers %d channels against the %d the world declares"
                % (num("channels"), num("declared")))
if num("mirrors") <= 0:
    fail.append("no CPU mirror came back with the device buffers")
# POSITIVE CONTROL: the wipe reached the device and it was not already empty.
if num("took") != 0:
    fail.append("the wipe did not reach the device (%d cell readings still differ from empty), so a "
                "restore that did nothing would read as exact" % num("took"))
if num("lost") <= 0:
    fail.append("the captured world was already empty, so this gate could not have failed")
if num("nonzero") <= 0:
    fail.append("no channel carries a total, so the conserved-books check is vacuous")
if num("same") != 0:
    fail.append("%d cell readings differ from the capture after restoring it" % num("same"))
if num("save_same") != 0:
    fail.append("%d cell readings differ after a round trip through the save bytes" % num("save_same"))
if num("totals_differ") != 0:
    fail.append("%d channel totals read differently after the restore than at the capture"
                % num("totals_differ"))
if num("refused") != 1 or int(os.environ.get("REFUSAL", "0")) < 1:
    fail.append("a snapshot of another world was not refused with a printed marker")

if fail:
    print("check_snapshot_roundtrip: FAILED", file=sys.stderr)
    for f in fail:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("check_snapshot_roundtrip: OK (layout %d; every channel back bit-for-bit off a wiped device, "
      "through memory and through the save bytes)" % int(num("layout")))
PY
exit $?
