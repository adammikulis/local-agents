#!/usr/bin/env bash
# PHYSICS_RUBRIC.md criteria 1, 2 and 5, COMPUTED from a run rather than judged.
#
# WHY THIS IS A SCRIPT AND NOT A PARAGRAPH. The rubric exists because a session was spent making nine copies
# of one formula agree and calling that correctness. The person scoring the work is the person who did it,
# so the parts that can be measured must be measured. Criteria 3, 4 and 6 are audit counts and stay
# hand-entered in PHYSICS_RUBRIC.md — they are the ones to distrust.
#
#   1  MATTER    per-element |drift| since the world seal, mask-free, in MOLES. A raw channel sum is not
#                admissible: carbon_total read +1261% while the mole count read -10.7%, opposite signs.
#   2  ENERGY    energy_residual as a fraction of the booked terms. NOT drift — energy is not closed and
#                must not be; sunlight enters and longwave leaves every step.
#   5  SEED      how many entries the world_seed manifest still carries, i.e. how much the planet was TOLD.
#
# Usage:  scripts/physics_score.sh [--path DIR] [--frames N] [--seed N]
# Reruns the standard verification arm unless LA_SCORE_REPORT points at a file holding a SIM_REPORT line.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool python3

PROJ="."
FRAMES=600
SEED=4242
while [ $# -gt 0 ]; do
  case "$1" in
    --path) PROJ="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPORT_SRC="${LA_SCORE_REPORT:-}"
if [ -z "$REPORT_SRC" ]; then
  require_tool godot
  TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/la_score.XXXXXX")"
  trap 'rm -f "$TMP_OUT"' EXIT
  echo "physics_score: running ${FRAMES} frames, seed ${SEED} (set LA_SCORE_REPORT to score an existing run)" >&2
  LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-900}" LA_NO_STREAMER=1 \
    "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
    addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
    -- --sandbox --planet-only "--run-frames=${FRAMES}" --fast=8 "--seed=${SEED}" --no-fauna \
    > "$TMP_OUT" 2>&1
  rc=$?
  # Exit 126 is a conservation violation, which is a RESULT here rather than a failure to run — the score
  # is exactly the thing that should reflect it. Anything else means no trustworthy report exists.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 126 ]; then
    echo "ERROR: the run failed (exit $rc) — refusing to score a run that did not complete." >&2
    grep -E "STALE_SHADERS=|LINT_FAIL|failed to compile" "$TMP_OUT" >&2 | head -5
    exit 2
  fi
  REPORT_SRC="$TMP_OUT"
fi
if [ ! -f "$REPORT_SRC" ]; then
  echo "ERROR: no report at $REPORT_SRC" >&2
  exit 2
fi

python3 - "$REPORT_SRC" <<'PY'
import json, sys, re

src = sys.argv[1]
line = None
for ln in open(src, errors="replace"):
    if ln.startswith("SIM_REPORT="):
        line = ln[11:]
if line is None:
    print("ERROR: no SIM_REPORT in the run output — refusing to report a score on no data.", file=sys.stderr)
    sys.exit(2)
d = json.loads(line)

def band(mag, edges):
    """edges are the UPPER bounds of scores 1,2,3; anything below the last is a 4."""
    for score, hi in enumerate(edges, start=1):
        if mag > hi:
            return score - 1 if score > 1 else 1
    return 4

# --- 1. MATTER, in moles, mask-free, since the seal ------------------------------------------------------
if not d.get("world_sealed"):
    print("criterion 1: 0  (the world never sealed — no baseline, so nothing is measurable)")
    m_score = 0
    rows = []
else:
    rows = []
    for name, now_k, first_k in [
            ("carbon (mol)", "element_C_total", "element_C_total_first"),
            ("h2o", "h2o_closed_total", "h2o_first"),
            ("o2", "o2_total", "o2_first"),
            ("oxidant", "oxidant_total", "oxidant_first"),
            ("nitrogen", "nitrogen_all", "nitrogen_first"),
            ("mineral", "mineral_total", "mineral_first")]:
        now, first = d.get(now_k), d.get(first_k)
        if not isinstance(now, (int, float)) or not isinstance(first, (int, float)) or not first:
            rows.append((name, None)); continue
        rows.append((name, abs((now - first) / first)))
    measured = [r for _, r in rows if r is not None]
    # The score is the WORST substance. A planet that conserves five things and destroys the sixth is not
    # conserving matter; averaging would let a good substance pay for a bad one.
    m_score = 0 if not measured else band(max(measured), [0.10, 0.01, 0.001])
    print("criterion 1  MATTER      score %d   (worst substance sets it)" % m_score)
    for name, rel in rows:
        print("    %-14s %s" % (name, "unmeasured" if rel is None else "%+.4f%%" % (rel * 100)))

# --- 2. ENERGY: the residual, not the drift --------------------------------------------------------------
booked, residual = d.get("energy_booked"), d.get("energy_residual")
if not isinstance(booked, (int, float)) or not isinstance(residual, (int, float)) or booked == 0:
    e_score = 0
    print("criterion 2  ENERGY      score 0   (no booked terms to measure a residual against)")
else:
    frac = abs(residual / booked)
    e_score = band(frac, [0.50, 0.10, 0.01])
    print("criterion 2  ENERGY      score %d   residual/booked %.3f" % (e_score, frac))
print("    (drift %-12s is NOT the score: energy is not closed and must not be)"
      % ("%.4g" % d["energy_run_drift"] if isinstance(d.get("energy_run_drift"), (int, float)) else "n/a"))

# --- 5. SEED MINIMALITY ----------------------------------------------------------------------------------
seed = d.get("world_seed") or {}
asserted = {k: v for k, v in seed.items() if isinstance(v, (int, float)) and v != 0.0}
# Scored on WHAT is asserted, not how many keys exist: an ocean placed is categorically different from a
# composition given. Ordered from most to least telling.
if not d.get("world_sealed"):
    s_score = 0
elif "h2o" in asserted and isinstance(d.get("temp_ground_p50"), (int, float)):
    s_score = 1
else:
    s_score = 2
print("criterion 5  SEED         score %d   %d asserted entries" % (s_score, len(asserted)))
for k in sorted(asserted):
    print("    %-14s %s" % (k, asserted[k]))
print("    (4 = a molten body and a bulk composition; the ocean, air and crust are outputs)")

print()
print("computed subtotal (1+2+5): %d / 12" % (m_score + e_score + s_score))
print("criteria 3, 4 and 6 are audit counts — hand-entered in PHYSICS_RUBRIC.md, and the ones to distrust.")
PY
