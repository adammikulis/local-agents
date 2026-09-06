#!/usr/bin/env bash
# OBSERVER INDEPENDENCE: the same seed and length, once with `--ui` and once without.
# EVERY reading the report publishes must agree, not the conserved sums alone -- mass moved INSIDE the
# field leaves every sum identical and every peak, profile and extreme different. At least
# MIN_CONSERVED of the conserved totals must be present and non-zero in both arms or the gate cannot run.
#
# EXIT 0 identical · 1 the sim depends on the observer · 2 could not run, never a silent pass.
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
  LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-600}" \
    "$REPO_ROOT/scripts/run_sim_offscreen.sh" --path "$REPO_ROOT" \
    addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
    -- --sandbox --planet-only --no-fauna "--run-frames=${FRAMES}" "--seed=${SEED}" "$@" \
    > "$out" 2>&1
  return 0
}

echo "check_observer_independence: two arms, ${FRAMES} frames, seed ${SEED}" >&2
run_arm "$A" --ui
run_arm "$B"

python3 - "$A" "$B" "$TOL" <<'PY'
import json, re, sys

def report(path):
    line = None
    for ln in open(path, errors="replace"):
        if ln.startswith("SIM_REPORT="):
            line = ln[11:]
    return json.loads(line) if line else None

a, b, tol = report(sys.argv[1]), report(sys.argv[2]), float(sys.argv[3])
if a is None or b is None:
    which = "with presentation" if a is None else "with none"
    print("ERROR: the %s arm produced no SIM_REPORT — refusing to report a pass on one arm." % which,
          file=sys.stderr)
    sys.exit(2)

# Readings OF THE HOST, not of the world: wall-clock costs, the frame rate they imply, driver memory.
# The presentation layer is expected to move these and only these.
HOST = re.compile(r"(^|\.)(fps|video_mem_MB|frame_ms|process_ms|actors|draw_calls)(\.|$)|_ms(\.|$)")
# The conserved totals. Not the whole probe any more, but the gate REFUSES TO RUN without them: a report
# that publishes none of them is a report this gate cannot say anything about.
CONSERVED = ("h2o_total", "element_C_total", "mineral_total", "o2_total", "oxidant_all",
             "nitrogen_all", "energy_stock")
MIN_CONSERVED = 5
MAX_SHOWN = 12


def flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        key = prefix + str(k)
        if isinstance(v, dict):
            out.update(flat(v, key + "."))
        else:
            out[key] = v
    return out


live = [k for k in CONSERVED
        if isinstance(a.get(k), (int, float)) and isinstance(b.get(k), (int, float))
        and a.get(k) and b.get(k)]
if len(live) < MIN_CONSERVED:
    missing = [k for k in CONSERVED if k not in live]
    print("ERROR: only %d of %d conserved totals are present and non-zero in both arms (%s missing). A key "
          "that is absent, non-numeric or exactly 0 was silently 'unmeasured', so this gate printed OK on a "
          "report that measured nothing." % (len(live), len(CONSERVED), ", ".join(missing)), file=sys.stderr)
    sys.exit(2)

steps_a, steps_b = a.get("field_step"), b.get("field_step")
if steps_a != steps_b:
    print('OBSERVER_STEPS={"with":%s,"bare":%s}' % (steps_a, steps_b))
    print("\nThe two arms did not run the same amount of simulation, so nothing below is a comparison.")
    print("Fix that first: the run length itself depends on the presentation layer.")
    sys.exit(1)

fa, fb = flat(a), flat(b)
keys = sorted(k for k in set(fa) | set(fb) if not HOST.search(k) and k != "field_step")
worst, worst_key, differing, rows = 0.0, "", 0, []
for k in keys:
    x, y = fa.get(k), fb.get(k)
    if isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool) \
            and not isinstance(y, bool):
        if x == y:
            continue
        rel = abs(y - x) / abs(x) if x else float("inf")
        differing += 1
        if rel > worst:
            worst, worst_key = rel, k
        rows.append((k, "%.6g vs %.6g  (rel %.3g)" % (x, y, rel)))
    elif x != y:
        differing += 1
        worst, worst_key = float("inf"), k
        rows.append((k, "%r vs %r" % (x, y)))

for k, note in rows[:MAX_SHOWN]:
    print("  %-28s %s" % (k, note))
if differing > MAX_SHOWN:
    print("  and %d more" % (differing - MAX_SHOWN))
print('OBSERVER_INDEPENDENCE={"compared":%d,"differing":%d,"worst_rel":%.6g,"worst":"%s","tol":%.6g}'
      % (len(keys), differing, worst, worst_key, tol))

if worst <= tol:
    print("\ncheck_observer_independence: OK — the sim does not depend on being watched.")
    sys.exit(0)
print("\nTHE SIMULATION CHANGES WHEN IT IS OBSERVED: %s differs by %.4g%%." % (worst_key, worst * 100.0))
print("Until this is 0, no number from this substrate can be attributed to physics rather than to the")
print("presentation layer, and no run may be quoted for conservation.")
print("Look for: a gauge that calls request_channel and so changes which mirrors are fresh; a CPU mirror")
print("read into a physics input; a branch conditioned on a camera, a viewport or a visibility test.")
sys.exit(1)
PY
