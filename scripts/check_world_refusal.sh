#!/usr/bin/env bash
# A PIECE THE DEVICE REFUSES INSIDE A WORLD ENDS THE RUN AT THE STEP IT FELL IN (gate_world_refusal.gd).
# seed  a slice refused in its seed's derive: RUN_FAILED at step 0, nothing baked, no row drained, no step.
# step  a slice refused after a committed step: that step is counted nowhere and nothing after the field
#       runs on it. body  the planet refused in its Poisson solve: no iteration runs past it. Every arm:
#       one refusal, said aloud, and no other engine error. EXIT 0 clean · 1 a claim is false · 2 no run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool rg
require_tool python3
PROBE="addons/local_agents/tests/gate_world_refusal.gd"
[ -f "$ROOT/$PROBE" ] || { echo "check_world_refusal: $PROBE is missing." >&2; exit 2; }
BOX="$("$ROOT/scripts/sim_run.sh" --print-slice-box)"
PLAYABLE="$(rg -N -o '^[0-9]+$' "$ROOT/docs/PLAYABLE_RUNG" 2>/dev/null | head -1)"
[ -n "$BOX" ] && [ -n "$PLAYABLE" ] || { echo "check_world_refusal: no slice box or playable rung." >&2; exit 2; }
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/la_world_refusal.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT INT TERM

# arm <name> <refuse> <rung> <steps> [slice box]; with no box the world is the whole planet.
arm() {
	local world=(env -u LA_SLICE_BOX)
	[ -n "${5:-}" ] && world=(env "LA_SLICE_BOX=$5")
	"${world[@]}" LA_RUN_TIMEOUT="${LA_WORLD_REFUSAL_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" \
		--path "$ROOT" -s "res://$PROBE" --fixed-fps 60 -- --sandbox "--run-frames=$4" "--rung=$3" \
		--planet-only --no-fauna "--refuse=$2" > "$LOGS/$1.log" 2>&1
	echo "$?" > "$LOGS/$1.rc"
}
arm seed seed 0 10 "$BOX"
arm step step "$PLAYABLE" 100 "$BOX"
arm body seed 1 10

python3 - "$LOGS" <<'PY'
import json, re, sys

logs = sys.argv[1]
REFUSAL = "fence wait, so it was NOT submitted"
fails, unrun = [], []


def read(name):
    text = open("%s/%s.log" % (logs, name), errors="replace").read()
    rc = int(open("%s/%s.rc" % (logs, name)).read().strip() or "-1")
    lines = text.splitlines()

    def last(prefix):
        got = [ln[len(prefix):] for ln in lines if ln.startswith(prefix)]
        return json.loads(got[-1]) if got else None

    errors = [ln for ln in lines if re.match(r"^(SCRIPT )?ERROR:", ln)]
    return rc, last("WORLD_REFUSAL="), last("RUN_FAILED="), last("SIM_REPORT="), errors


for name in ("seed", "step", "body"):
    rc, v, f, report, errors = read(name)
    loud = [e for e in errors if REFUSAL in e]
    if f is None or v is None or report is None:
        if loud or report is not None:
            fails.append("%s: the run did not end RUN_FAILED at a refused step (exit %d)" % (name, rc))
        else:
            unrun.append("%s: the world refused nothing and published no report (exit %d)" % (name, rc))
        continue
    print("WORLD_REFUSAL_%s=%s" % (name.upper(), json.dumps({"failed": v["failed"], "committed": v["committed"],
                                                             "reason": v["reason"]})))
    c = v["committed"]
    say = lambda msg: fails.append("%s: %s" % (name, msg))
    other = [e for e in errors if REFUSAL not in e]
    if v["refused"] != 1 or len(loud) != 1:
        say("the driver counted %d refusals and %d were said aloud, not the one that ends the run"
            % (v["refused"], len(loud)))
    if other:
        say("the engine reported %d errors besides the refusal: %s" % (len(other), other[0][:160]))
    if rc != 1:
        say("the run exited %d, not as a failed run" % rc)
    if f["step"] != v["failed"] or f["committed"] != c:
        say("RUN_FAILED names step %s and %s committed, the loop %d and %d" % (f["step"], f["committed"],
                                                                            v["failed"], c))
    if report.get("sim_steps") != c or v["sim_steps"] != c:
        say("the report reads %s steps and the loop's own report %s, with %d committed"
            % (report.get("sim_steps"), v["sim_steps"], c))
    if v["seen"] != list(range(1, c + 1)):
        say("a subscriber after the field ran on steps %s with %d committed" % (v["seen"], c))
    if v["clock_steps"] != c or v["field_steps"] != c:
        say("the calendar counts %d steps and the field %d, with %d committed" % (v["clock_steps"],
                                                                              v["field_steps"], c))
    if name == "step":
        if not (1 <= v["armed_at"] < v["failed"] and c == v["failed"] - 1):
            say("the refusal fell at step %d, armed after %d, with %d committed" % (v["failed"], v["armed_at"], c))
        if v["full_steps"] != v["full_at_arming"]:
            say("the refused step finished as a full step: %d full steps, %d when armed"
                % (v["full_steps"], v["full_at_arming"]))
        continue
    if v["failed"] != 0 or c != 0:
        say("the seed's refusal failed step %d with %d committed" % (v["failed"], c))
    if v["baked"]:
        say("the refused seed was baked, so the next run would load a world no seed finished")
    if v["reduce_rows"] != 0:
        say("%d reduce rows were drained from a derive the device refused" % v["reduce_rows"])
    if v["poisson_solves"] != 0:
        say("%d gravity solves ran past the refusal, on the density it left" % v["poisson_solves"])

for m in fails:
    print("check_world_refusal: " + m, file=sys.stderr)
for m in unrun:
    print("check_world_refusal: " + m, file=sys.stderr)
sys.exit(1 if fails else 2 if unrun else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
	for n in seed step body; do
		echo "--- $n (exit $(cat "$LOGS/$n.rc" 2>/dev/null)) ---" >&2
		grep -E '^(SCRIPT )?ERROR:|^RUN_FAILED=|^WORLD_REFUSAL=' "$LOGS/$n.log" 2>/dev/null | cut -c1-240 | head -8 >&2
	done
	exit "$rc"
fi
echo "check_world_refusal: OK"
