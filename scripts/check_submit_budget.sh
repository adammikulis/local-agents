#!/usr/bin/env bash
# NO SUBMIT OUTRUNS THE DEVICE'S FENCE WAIT (LAFieldDriver::METAL_FENCE_WAIT_MS).
# Arm 1  derive and reduce, whole and split into many submits, leave every buffer bit-identical; under a wait
#        no workgroup fits in, every one after the measured first is refused before it is submitted, aloud.
# Arm 2  the seeded world refused nothing and no submit reached the wait. Arm 3  only a rig sets a wait, and
#        every pass kernel reads its workgroup through chunk.glsli. EXIT 0 clean · 1 a claim is false · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool rg
require_tool python3
PROBE="addons/local_agents/tests/gate_submit_budget.gd"
[ -f "$ROOT/$PROBE" ] || { echo "check_submit_budget: $PROBE is missing." >&2; exit 2; }
REFUSAL="fence wait, so it was NOT submitted"

# --- arm three: the wait is the backend's everywhere but a rig ----------------------------------------
hits="$(rg -n 'set_wait_usec' "$ROOT/addons/local_agents" -g '*.gd' -g '!**/tests/**' 2>/dev/null)"
if [ -n "$hits" ]; then
	echo "check_submit_budget: simulation code plans against a wait other than its device's own:" >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
# Every kernel a pass dispatches reads its workgroup through chunk.glsli and ends its Params with the words.
kernels="$(rg -N -o -r '$1' 'KERNEL_PATH: String = "res://(.+\.glsl)"' "$ROOT/addons/local_agents/sim/material/sphere_passes" \
	-g '*.gd' 2>/dev/null | sed 's/^.*://' | sort -u)"
[ "$(printf '%s\n' "$kernels" | grep -c .)" -ge 7 ] || { echo "check_submit_budget: found no pass kernels." >&2; exit 2; }
for k in $kernels; do
	f="$ROOT/$k"
	[ -f "$f" ] || { echo "check_submit_budget: $k is missing." >&2; exit 2; }
	if ! grep -q '#include "chunk.glsli"' "$f" || grep -qE 'gl_(GlobalInvocationID|WorkGroupID|NumWorkGroups)' "$f" \
		|| ! tr -d '\n\t ' < "$f" | grep -q 'uintchunk_stride;[^;]*uintchunk_phase;[^;]*}params;'; then
		echo "check_submit_budget: $k does not take its workgroup from chunk.glsli's two trailing words." >&2
		exit 1
	fi
done

# --- arm one: one dispatch or many submits, and the refusal ------------------------------------------
LOG="$(mktemp "${TMPDIR:-/tmp}/la_submit_budget.XXXXXX")"
trap 'rm -f "$LOG"' EXIT INT TERM
LA_DONE_RE='^SUBMIT_BUDGET=' "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" -s "res://$PROBE" \
	> "$LOG" 2>&1
line="$(grep -m1 '^SUBMIT_BUDGET=' "$LOG")"
if [ -z "$line" ]; then
	echo "check_submit_budget: the probe published no SUBMIT_BUDGET line." >&2
	tail -25 "$LOG" >&2
	exit 2
fi
echo "$line"
python3 - "$LOG" "$line" "$REFUSAL" <<'PY'
import json, re, sys
log, line, refusal = open(sys.argv[1], errors="replace").read(), sys.argv[2], sys.argv[3]
d = json.loads(line.split("=", 1)[1])
if d.get("failures", -1) < 0:
    print("check_submit_budget: the probe could not run its arms.", file=sys.stderr)
    sys.exit(2)
fails = [ln for ln in log.splitlines() if ln.startswith("gate_submit_budget:")]
errors = [ln for ln in log.splitlines() if re.match(r"^(SCRIPT )?ERROR:", ln)]
loud = [ln for ln in errors if refusal in ln]
other = [ln for ln in errors if refusal not in ln]
if d["failures"] > 0:
    fails.append("the probe failed %d claims" % d["failures"])
if len(loud) != d.get("refused", -1) or not loud:
    fails.append("%d refusals were said aloud for %s the driver counted" % (len(loud), d.get("refused")))
if other:
    fails.append("the engine reported %d errors besides the refusals: %s" % (len(other), other[0][:160]))
for f in fails:
    print("check_submit_budget: " + f, file=sys.stderr)
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# --- arm two: the seeded world's own submits ---------------------------------------------------------
out="$(la_report "submit_refused,submit_worst_ms,submit_wait_ms")"
rc=$?
[ "$rc" -eq 0 ] || { echo "check_submit_budget: the seeded world could not be read (exit $rc)." >&2; exit 2; }
python3 - "$out" <<'PY'
import ast, sys
vals = {}
for ln in sys.argv[1].splitlines():
    if " = " in ln:
        k, v = [s.strip() for s in ln.split(" = ", 1)]
        vals[k] = v
got = {}
for k in ("submit_refused", "submit_worst_ms", "submit_wait_ms"):
    raw = vals.get(k, "<ABSENT>")
    if raw == "<ABSENT>":
        print("check_submit_budget: the seeded world published no %s." % k, file=sys.stderr)
        sys.exit(2)
    v = ast.literal_eval(raw)
    got[k] = float(v["max"]) if isinstance(v, dict) else float(v)
print("SUBMIT_WORLD=" + str(got))
if got["submit_refused"] != 0:
    print("check_submit_budget: the seeded world refused %d dispatches." % got["submit_refused"], file=sys.stderr)
    sys.exit(1)
if not got["submit_worst_ms"] < got["submit_wait_ms"]:
    print("check_submit_budget: a submit took %.1f ms of a %.1f ms fence wait."
          % (got["submit_worst_ms"], got["submit_wait_ms"]), file=sys.stderr)
    sys.exit(1)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_submit_budget: OK"
