#!/usr/bin/env bash
# A neighbour query through LAGroupIndex finds every group member a whole-group scan finds, in group
# order. Arm 1 moves members across cells, turns their parent and swaps members within one frame; arm 2
# runs the life demo with LA_GROUP_INDEX_CHECK, which scans the group beside every query.
# EXIT 0 none missed * 1 one was * 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool python3

UNIT="addons/local_agents/tests/gate_group_index.gd"
[ -f "$ROOT/$UNIT" ] || { echo "check_group_index: no probe at $UNIT" >&2; exit 2; }
unit="$(la_godot --headless --path "$ROOT" -s "res://$UNIT" 2>&1)"
line="$(printf '%s\n' "$unit" | grep -m1 '^GROUP_INDEX=')"
if [ -z "$line" ]; then
	echo "check_group_index: the probe printed no GROUP_INDEX line." >&2
	printf '%s\n' "$unit" | tail -20 >&2
	exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "check_group_index: the probe published no failure count." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$unit" | grep -E '^GROUP_INDEX_' | head -10 >&2
	echo "check_group_index: FAIL, the index disagreed with a whole-group scan $fails time(s)."
	exit 1
fi

SCENE="addons/local_agents/examples/LifeDemo.tscn"
[ -f "$ROOT/$SCENE" ] || { echo "check_group_index: no scene at $SCENE" >&2; exit 2; }
LOG="$(mktemp "${TMPDIR:-/tmp}/la_group_index.XXXXXX")"
trap 'rm -f "$LOG"' EXIT INT TERM
LA_GROUP_INDEX_CHECK=1 LA_RUN_TIMEOUT="${LA_GROUP_INDEX_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" \
	--path "$ROOT" "$SCENE" --fixed-fps 60 -- --sandbox "--run-frames=${LA_GROUP_INDEX_FRAMES:-120}" > "$LOG" 2>&1

python3 - "$LOG" <<'PY'
import json, re, sys
text = open(sys.argv[1], errors="replace").read()
rows = [l[len("SIM_REPORT="):] for l in text.splitlines() if l.startswith("SIM_REPORT=")]
if not rows:
    print("check_group_index: the run published no SIM_REPORT.", file=sys.stderr)
    print("\n".join(text.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)
r = json.loads(re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", rows[-1]))
checked, missed = r.get("group_index_checked"), r.get("group_index_missed")
if checked is None or missed is None or int(checked) <= 0:
    print("check_group_index: no query was checked, so the index went unexamined.", file=sys.stderr)
    sys.exit(2)
if int(missed) > 0:
    print("check_group_index: FAIL, %d member(s) inside a query's range were not returned." % int(missed))
    sys.exit(1)
print("check_group_index: OK (%d queries in the demo, none missed a member)" % int(checked))
PY
