#!/usr/bin/env bash
# A WORLD AT REST IS AUDITED, NOT SKIPPED. Rungs 0 to 2 hold no writer, so their slices rest; their books
# run on the loop's clock, the audit latches past its horizon with every row a number, the energy row with
# nothing crossing is held against the energy held, and the run ends on a whole step, which folds nothing,
# so the audit stands on the last fold's span. With its books switched off, a world reads unmeasured.
# EXIT 0 audited at rest - 1 not - 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

CONS="$ROOT/addons/local_agents/sim/material/MaterialFieldConservation3D.gd"
STEP="$ROOT/addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd"
HORIZON="$(sed -n 's/^const REFERENCE_STEPS: int = \([0-9][0-9]*\)$/\1/p' "$CONS")"
EVERY="$(sed -n 's/^const REST_AUDIT_EVERY: int = \([0-9][0-9]*\)$/\1/p' "$STEP")"
if [ -z "$HORIZON" ] || [ -z "$EVERY" ]; then
	echo "check_audit_at_rest: no REFERENCE_STEPS in ${CONS#"$ROOT"/} or REST_AUDIT_EVERY in ${STEP#"$ROOT"/}." >&2
	exit 2
fi
FRAMES=$(((HORIZON / EVERY + 2) * EVERY))
RUNGS="0 1 2"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_audit_rest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
for rung in $RUNGS; do
	"$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --rung "$rung" --frames "$FRAMES" --raw \
		> "$WORK/$rung.json" 2> "$WORK/$rung.err"
	echo "$?" > "$WORK/$rung.rc"
done
"$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --rung 0 --frames "$FRAMES" --raw -- --ablate=reduce \
	> "$WORK/off.json" 2> "$WORK/off.err"
echo "$?" > "$WORK/off.rc"

python3 - "$WORK" "$FRAMES" "$HORIZON" "$EVERY" $RUNGS <<'PY'
import json, sys

work, frames, horizon, every = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
fails = []
seen = {}
for rung in [int(r) for r in sys.argv[5:]]:
    rc = int(open("%s/%d.rc" % (work, rung)).read().strip())
    text = open("%s/%d.json" % (work, rung), errors="replace").read().strip()
    try:
        d = json.loads(text) if text.startswith("{") else None
    except ValueError:
        d = None
    if rc not in (0, 123, 126) or not isinstance(d, dict):
        print("check_audit_at_rest: the rung-%d world did not report (exit %d)." % (rung, rc), file=sys.stderr)
        print("\n".join(open("%s/%d.err" % (work, rung), errors="replace").read().splitlines()[-12:]),
              file=sys.stderr)
        sys.exit(2)
    rest = int(d.get("events", {}).get("field_rest", 0))
    if rest <= 0:
        print("check_audit_at_rest: the rung-%d world never rested, so no rest was examined." % rung,
              file=sys.stderr)
        sys.exit(2)

    def fail(msg):
        fails.append("rung %d: %s" % (rung, msg))

    if rc == 126:
        fail("the audit fired CONSERVATION_VIOLATION on a world at rest")
    if rc == 123:
        fail("the audit found a quantity it could not measure")
    steps = d.get("conservation_steps")
    if not isinstance(steps, int) or steps < horizon:
        fail("conservation_steps reads %r past %d steps, short of the %d-step horizon" % (steps, frames, horizon))
    if d.get("conservation_audited") is not True:
        fail("the audit never latched")
    rows = d.get("conservation")
    row = rows.get("energy_held") if isinstance(rows, dict) else None
    if not isinstance(row, (int, float)):
        fail("the energy row reads %r" % (row,))
    turnover = d.get("energy_turnover_j")
    if turnover != 0.0:
        fail("energy_turnover_j reads %r where nothing crosses" % (turnover,))
    last = d.get("gauges", {}).get("reduce_step", {}).get("cur")
    if not isinstance(last, (int, float)) or last < frames - every:
        fail("the books were last read at step %r of %d, not within the last %d" % (last, frames, every))
    base = d.get("world_baseline_step")
    if not isinstance(base, int) or not isinstance(last, (int, float)) or steps != int(last) - base:
        fail("the audit spans %r steps where the books last folded span step %r to %r" % (steps, base, last))
    for k in ("conservation_violations", "conservation_unmeasured"):
        if d.get(k):
            fail("%s reads %r" % (k, d.get(k)))
    seen[rung] = {"rest_steps": rest, "conservation_steps": steps, "audited": d.get("conservation_audited"),
                  "energy_row": row, "books_step": last}

rc = int(open("%s/off.rc" % work).read().strip())
text = open("%s/off.json" % work, errors="replace").read().strip()
try:
    d = json.loads(text) if text.startswith("{") else None
except ValueError:
    d = None
if rc not in (0, 123, 126) or not isinstance(d, dict):
    print("check_audit_at_rest: the world with its books switched off did not report (exit %d)." % rc,
          file=sys.stderr)
    sys.exit(2)
if rc != 123 or d.get("conservation_starved") is not True or d.get("conservation_audited") is not False:
    fails.append("books off: exit %d, starved %r, audited %r past the horizon"
                 % (rc, d.get("conservation_starved"), d.get("conservation_audited")))

print("AUDIT_AT_REST=%s" % json.dumps({"frames": frames, "rungs": seen, "failures": len(fails)}))
for f in fails:
    print("FAIL: " + f, file=sys.stderr)
sys.exit(1 if fails else 0)
PY
v=$?
[ "$v" -eq 0 ] && echo "check_audit_at_rest: OK"
exit "$v"
