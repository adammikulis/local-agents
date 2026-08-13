#!/usr/bin/env bash
# THE SAME SEED MUST GIVE THE SAME PLANET. Two runs, one seed, one length -> diff every conserved total.
#
# Not in `lint` (two windowed runs, minutes). Run it before believing any A/B: a difference between two
# configurations is unreadable while a configuration does not match itself.
#
# WHAT IT SEPARATES, and why that matters more than the red light. Three things make two runs disagree and
# they need different fixes, so the gate names which one it saw instead of reporting one number:
#   HORIZON  the runs simulated different amounts of time. `--run-frames` counts SIMULATED STEPS off
#            LASimLoop, so two runs of the same length cover the same simulated seconds whatever the
#            machine did. A horizon difference here is a defect in the step loop, not in the substrate.
#   RNG      the seeded streams drew different values. Reported per domain from RNG_TRACE.
#   SUBSTRATE  same horizon, same RNG draws, different totals -> the GPU step itself is order-dependent.
#
# Usage:  scripts/check_determinism.sh [--path DIR] [--frames N] [--seed N]
# Exit 0 identical · 1 the runs disagree · 2 the gate could not run (never a silent pass).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool python3
require_tool godot

PROJ="."
# 240 so frame 180 lands inside the run: RNG_TRACE is emitted every 180 frames, and without it the gate
# cannot tell an RNG divergence from a substrate one.
FRAMES=240
SEED=4242
while [ $# -gt 0 ]; do
  case "$1" in
    --path) PROJ="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

A="$(mktemp "${TMPDIR:-/tmp}/la_det_a.XXXXXX")"
B="$(mktemp "${TMPDIR:-/tmp}/la_det_b.XXXXXX")"
trap 'rm -f "$A" "$B"' EXIT

run_one() {
  # SOAK: two full runs compared end to end; run by hand, no lane blocks on it
  LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-900}" LA_NO_STREAMER=1 LA_RNG_TRACE=1 \
    "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
    addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
    -- --sandbox --planet-only "--run-frames=${FRAMES}" "--seed=${SEED}" --no-fauna \
    > "$1" 2>&1
  return 0
}

echo "check_determinism: two runs, ${FRAMES} frames, seed ${SEED}" >&2
run_one "$A"
run_one "$B"

python3 - "$A" "$B" <<'PY'
import json, sys

# Every total the substrate is supposed to conserve, plus the horizon that decides whether they are
# comparable at all. field_step/field_sim_s are NOT conserved quantities and are checked first, separately.
CONSERVED = ("h2o_closed_total", "element_C_total", "mineral_total", "o2_total", "oxidant_total",
             "nitrogen_all", "energy_stock")
HORIZON = ("field_step", "field_sim_s")


def load(path):
    report, traces = None, []
    for line in open(path, errors="replace"):
        if line.startswith("SIM_REPORT="):
            report = line[11:]
        elif line.startswith("RNG_TRACE="):
            traces.append(line[10:].strip())
    return (json.loads(report) if report else None), traces


a, ta = load(sys.argv[1])
b, tb = load(sys.argv[2])
if a is None or b is None:
    which = "first" if a is None else "second"
    print("ERROR: the %s run printed no SIM_REPORT — refusing to call that determinism." % which,
          file=sys.stderr)
    sys.exit(2)

fail = False

# 1. HORIZON. Two runs of different simulated length disagreeing says nothing about the substrate.
horizon_same = True
for k in HORIZON:
    x, y = a.get(k), b.get(k)
    if isinstance(x, (int, float)) and isinstance(y, (int, float)) and x != y:
        horizon_same = False
        print("HORIZON  %-18s %r vs %r" % (k, x, y))
if not horizon_same:
    print("VERDICT: the two runs did not simulate the same amount of time. Nothing below is comparable; "
          "fix the step loop first.")
    fail = True

# 2. RNG. Identical draw counts across every seeded domain exonerate the stochastics.
rng_same = ta == tb
if not ta or not tb:
    print("RNG      no RNG_TRACE in the output (needs a run of at least 180 frames) — RNG not exonerated")
elif rng_same:
    print("RNG      identical draw counts in every domain across both runs")
else:
    print("RNG      the seeded streams DIVERGED — first differing trace line:")
    for x, y in zip(ta, tb):
        if x != y:
            print("           A %s" % x)
            print("           B %s" % y)
            break
    fail = True

# 3. THE TOTALS.
worst, worst_key = 0.0, ""
for k in CONSERVED:
    x, y = a.get(k), b.get(k)
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        print("TOTAL    %-18s absent from the report — UNMEASURED, not 'fine'" % k)
        continue
    if x == y:
        continue
    rel = abs((y - x) / x) if x else float("inf")
    print("TOTAL    %-18s %.10g vs %.10g   (%.4g%%)" % (k, x, y, rel * 100.0))
    if rel > worst:
        worst, worst_key = rel, k
    fail = True

print('DETERMINISM={"horizon_same":%s,"rng_same":%s,"worst_rel":%.6g,"worst_key":"%s"}'
      % (str(horizon_same).lower(), str(rng_same).lower(), worst, worst_key))

if not fail:
    print("check_determinism: OK (same seed, same planet, to the digit)")
    sys.exit(0)
if horizon_same and rng_same:
    print("VERDICT: same horizon, same RNG draws, different planet — the GPU step is order-dependent.")
sys.exit(1)
PY
rc=$?
exit $rc
