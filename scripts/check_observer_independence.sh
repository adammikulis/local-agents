#!/usr/bin/env bash
# =====================================================================================================
# OBSERVER INDEPENDENCE — a simulation may not change because somebody is watching it.
#
# RUN THIS BEFORE YOU TRUST ANY OTHER NUMBER. It is two runs and a diff, and it eliminates a whole class of
# noise from every measurement taken afterwards. It was not run for a whole day of substrate work, and every
# figure from that day — a conservation breach, a per-pass attribution, an energy residual — was taken on a
# substrate where looking at it changed it.
#
# WHY IT IS A GATE AND NOT A TASK. It was a task. It sat in_progress while one MECHANISM was found and
# fixed (a whole-mirror upload whose staleness depended on which consumer was alive), and the property was
# then treated as settled without being measured. Observer independence is not a defect you fix once, it is
# an INVARIANT you test — and an invariant that nothing tests is an invariant you do not have.
#
# WHY A GREEN FRAMERATE GATE DOES NOT COVER IT. check_framerate_independence.sh catches simulation state
# advancing on the render clock. It cannot see a camera-CONDITIONAL branch: MaterialEjecta3D decided
# whether a parcel of rock arcs or deposits on the spot by testing the camera frustum, so where mass and
# heat landed moved with the view. Different shape, same violated principle. Mechanisms are many; the
# property is one, so test the property.
#
# WHAT IT COMPARES. The same seed and the same length, once with the presentation layer and once with
# `--bare`. Every conserved total must agree. Conservation totals are the right probe because they are
# sums over the whole field: a divergence anywhere in the substrate reaches them.
#
# EXIT CODES. 0 identical · 1 the sim depends on the observer · 2 could not run, never a silent pass.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMES="${LA_OBS_FRAMES:-60}"   # enough to seal the world and sample; this is a check, not a soak
SEED="${LA_OBS_SEED:-4242}"
# Float32 round-trips through the GPU, so bit-equality is not available. Anything above this is structural.
TOL="${LA_OBS_TOL:-1e-9}"

# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool godot; require_tool python3
else
  command -v godot >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
fi

A="$(mktemp "${TMPDIR:-/tmp}/la_obs_a.XXXXXX")"
B="$(mktemp "${TMPDIR:-/tmp}/la_obs_b.XXXXXX")"
trap 'rm -f "$A" "$B"' EXIT

run_arm() {  # $1 = out file, $2.. = extra scene args
  local out="$1"; shift
  # SOAK: two full runs, presentation on and off; run by hand
  LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-600}" LA_NO_STREAMER=1 \
    "$REPO_ROOT/scripts/run_sim_offscreen.sh" --path "$REPO_ROOT" \
    addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
    -- --sandbox --planet-only --no-fauna "--run-frames=${FRAMES}" --fast=8 "--seed=${SEED}" "$@" \
    > "$out" 2>&1
  return 0
}

echo "check_observer_independence: two arms, ${FRAMES} frames, seed ${SEED}" >&2
run_arm "$A"
run_arm "$B" --bare

python3 - "$A" "$B" "$TOL" <<'PY'
import json, sys

def report(path):
    line = None
    for ln in open(path, errors="replace"):
        if ln.startswith("SIM_REPORT="):
            line = ln[11:]
    return json.loads(line) if line else None

a, b, tol = report(sys.argv[1]), report(sys.argv[2]), float(sys.argv[3])
if a is None or b is None:
    which = "with presentation" if a is None else "--bare"
    print("ERROR: the %s arm produced no SIM_REPORT — refusing to report a pass on one arm." % which,
          file=sys.stderr)
    sys.exit(2)

# The conserved totals, plus the step count: two arms that ran different amounts of simulation are not a
# comparison at all, and that is a DIFFERENT failure worth naming separately.
KEYS = ("h2o_closed_total", "element_C_total", "mineral_total", "o2_total", "oxidant_all",
        "nitrogen_all", "energy_stock")
steps_a, steps_b = a.get("field_step"), b.get("field_step")
if steps_a != steps_b:
    print('OBSERVER_STEPS={"with":%s,"bare":%s}' % (steps_a, steps_b))
    print("\nThe two arms did not run the same amount of simulation, so nothing below is a comparison.")
    print("Fix that first: the run length itself depends on the presentation layer.")
    sys.exit(1)

worst, rows = 0.0, []
for k in KEYS:
    x, y = a.get(k), b.get(k)
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)) or not x:
        rows.append((k, None)); continue
    rel = abs((y - x) / x)
    worst = max(worst, rel)
    rows.append((k, rel))

for k, rel in rows:
    print("  %-20s %s" % (k, "unmeasured" if rel is None else ("%.6g" % rel)))
print('OBSERVER_INDEPENDENCE={"worst_rel":%.6g,"tol":%.6g}' % (worst, tol))

if worst <= tol:
    print("\ncheck_observer_independence: OK — the sim does not depend on being watched.")
    sys.exit(0)
print("\nTHE SIMULATION CHANGES WHEN IT IS OBSERVED, by %.4g%% at worst." % (worst * 100.0))
print("Until this is 0, no number from this substrate can be attributed to physics rather than to the")
print("presentation layer, and no --bare run may be quoted for conservation.")
print("Look for: a gauge that calls request_channel and so changes which mirrors are fresh; a CPU mirror")
print("read into a physics input; a branch conditioned on a camera, a viewport or a visibility test.")
sys.exit(1)
PY
