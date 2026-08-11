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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
    -- --sandbox --planet-only "--run-frames=${FRAMES}" --fast=8 "--seed=${SEED}" --no-fauna --bare \
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

  # CRITERIA 9 AND 10 NEED THEIR OWN RUNS, so the script takes them. A score that quietly skips its
  # expensive half is the hand-entered problem wearing a script. Both are shorter: determinism and
  # observer-independence are decided by whether two runs AGREE, not by how far the planet got.
  AUX_FRAMES=$(( FRAMES / 2 ))
  [ "$AUX_FRAMES" -lt 60 ] && AUX_FRAMES=60
  run_aux() {  # $1 = output file, $2.. = extra scene args
    local out="$1"; shift
    LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-900}" LA_NO_STREAMER=1 \
      "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
      addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
      -- --sandbox --planet-only "--run-frames=${AUX_FRAMES}" --fast=8 "--seed=${SEED}" --no-fauna "$@" \
      > "$out" 2>&1
    return 0
  }
  if [ "${LA_SCORE_SKIP_AUX:-}" = "" ]; then
    TMP_BASE="$(mktemp "${TMPDIR:-/tmp}/la_score_base.XXXXXX")"
    TMP_REPEAT="$(mktemp "${TMPDIR:-/tmp}/la_score_repeat.XXXXXX")"
    TMP_PRESENT="$(mktemp "${TMPDIR:-/tmp}/la_score_present.XXXXXX")"
    trap 'rm -f "$TMP_OUT" "$TMP_BASE" "$TMP_REPEAT" "$TMP_PRESENT"' EXIT
    # The pair for criterion 9 is two runs of the SAME length, so the main run cannot serve as one half.
    # EVERY MEASUREMENT ARM IS `--bare`. The UI — HUD, audio, ocean, particles, vegetation, overlays — builds
    # a dozen nodes that measure nothing and cost load time on every arm. Determinism is therefore tested in
    # the configuration we actually measure in, and the observer criterion supplies the one arm WITH the
    # presentation layer, because comparing the two is the whole of its job.
    echo "physics_score: determinism pair (bare) + one presentation arm, ${AUX_FRAMES} frames each" >&2
    run_aux "$TMP_BASE" --bare
    run_aux "$TMP_REPEAT" --bare
    run_aux "$TMP_PRESENT"
    export LA_SCORE_BASE="$TMP_BASE" LA_SCORE_REPEAT="$TMP_REPEAT" LA_SCORE_BARE="$TMP_PRESENT"
  fi
fi
if [ ! -f "$REPORT_SRC" ]; then
  echo "ERROR: no report at $REPORT_SRC" >&2
  exit 2
fi

python3 - "$REPORT_SRC" "$REPO_ROOT" <<'PY'
import json, sys, re

src = sys.argv[1]
root = sys.argv[2]
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
    # Criterion 6 asks which substances drift, so it needs the per-substance figures rather than the worst.
    worst_by = {n.split()[0]: r for n, r in rows if r is not None}
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


# --- 3 and 4 come from docs/MODEL_PARAMETERS.md, which is already a ratcheted census ----------------------
# A "scalar where a relation belongs" IS a number in the registry: one that is neither bound to an authority
# nor derived from other constants. The gate counts them on every lint, so criterion 3 has a real population
# rather than an audit somebody remembered to redo. Criterion 4 is the subset whose recorded REASON says it
# is a prescribed target, an outcome-deciding clamp, or a rate fitted to one timestep — the registry's own
# `why` column, written when each row was filed.
import os, re as _re
reg = os.path.join(root, "docs", "MODEL_PARAMETERS.md")
declared, prescribed = 0, 0
FITTED = _re.compile(r"per-step k|presence floor|numerical guard|transport tuning|chosen not derived"
                     r"|inherited, unreviewed|fitted", _re.I)
if os.path.exists(reg):
    for ln in open(reg, errors="replace"):
        if not ln.lstrip().startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in ln.split("|")]
        if len(cells) < 5 or not cells[2] or cells[2] in ("constant",) or set(cells[2]) <= set("-"):
            continue
        declared += 1
        if FITTED.search(cells[4] if len(cells) > 4 else ""):
            prescribed += 1
else:
    declared = prescribed = -1

def count_band(n, edges):
    """edges are the upper bounds of scores 1, 2, 3; below the last is a 4. -1 means never audited -> 0."""
    if n < 0:
        return 0
    for score, hi in enumerate(edges, start=1):
        if n > hi:
            return score - 1 if score > 1 else 1
    return 4

c_score = count_band(declared, [10, 3, 0])
p_score = count_band(prescribed, [15, 5, 0])
print()
print("criterion 3  CONSTITUTIVE score %d   %d constants neither bound nor derived (docs/MODEL_PARAMETERS.md)"
      % (c_score, declared))
print("criterion 4  COMPUTED     score %d   %d of those recorded as a clamp, a floor, or a fitted per-step rate"
      % (p_score, prescribed))

# --- 6. INSTRUMENT INTEGRITY: per-pass attribution for the substances that actually drift -----------------
# The rubric's own bands are about ATTRIBUTION and about gates seen to fail, so both are counted, not judged.
# A substance "drifts" if criterion 1 put it outside 0.1%; it "has attribution" if a per-pass probe covers it.
PROBED = {"mineral": "LA_MINERAL_BUDGET", "h2o": "LA_H2O_BUDGET", "energy": "LA_ENERGY_BUDGET"}
drifting = sorted(k for k, v in globals().get("worst_by", {}).items() if abs(v) > 0.001)
unattributed = [k for k in drifting if k not in PROBED]
gates = []
gdir = os.path.join(root, "scripts")
if os.path.isdir(gdir):
    gates = [f for f in os.listdir(gdir) if f.startswith("check_") and f.endswith(".sh")]
if not drifting:
    i_score = 4
elif unattributed:
    i_score = 2 if len(unattributed) > 1 else 3
else:
    i_score = 3
print("criterion 6  INSTRUMENT   score %d   %d drifting substance(s), %d without per-pass attribution; %d gates"
      % (i_score, len(drifting), len(unattributed), len(gates)))
if unattributed:
    print("    no per-pass probe: %s" % ", ".join(sorted(unattributed)))


# --- 7. MOMENTUM BOOKED — *is the moving air and water accounted for like the matter and heat are?* --------
# Matter has ledgers and energy has a ledger. Momentum has none: wind and flow carry it, pressure gradients
# and gravity create it, drag destroys it, and NOTHING sums it. A substrate that books two of the three
# conserved quantities of mechanics is not measuring the third — it is not looking.
MOMENTUM_KEYS = ("momentum_total", "momentum_drift", "momentum_booked", "momentum_residual")
mom_present = [k for k in MOMENTUM_KEYS if isinstance(d.get(k), (int, float))]
if not mom_present:
    mo_score = 0
else:
    resid = d.get("momentum_residual")
    booked = d.get("momentum_booked")
    if isinstance(resid, (int, float)) and isinstance(booked, (int, float)) and booked:
        mo_score = band(abs(resid / booked), [0.50, 0.10, 0.01])
    else:
        mo_score = 1
print()
print("criterion 7  MOMENTUM     score %d   %s"
      % (mo_score, "no momentum ledger exists" if not mom_present else ", ".join(mom_present)))

# --- 8. EMERGENCE — *do named phenomena have dedicated code?* ---------------------------------------------
# The project's north star: "volcano", "eruption", "tornado" are words humans put on what the physics does,
# not systems anyone writes. Success is measured in special-case code DELETED. Counted mechanically as
# per-phenomenon actor scripts plus the per-phenomenon symbols inside them.
PHENOMENA = ("Volcano", "Earthquake", "Tornado", "Hurricane", "Thunderstorm", "LightningStrike",
             "Flood", "Meteor")
adir = os.path.join(root, "addons", "local_agents", "sim", "actors")
phen_files, phen_symbols = [], 0
SPECIAL = _re.compile(r"_is_erupting|BOMBS_PER_BURST|burst_timer|func erupt|PER_BURST|_burst\b", _re.I)
if os.path.isdir(adir):
    for f in sorted(os.listdir(adir)):
        if not f.endswith(".gd"):
            continue
        if any(f.startswith(n) for n in PHENOMENA):
            phen_files.append(f)
            try:
                phen_symbols += len(SPECIAL.findall(open(os.path.join(adir, f), errors="replace").read()))
            except OSError:
                pass
em_score = count_band(len(phen_files) * 2 + phen_symbols, [12, 4, 0])
print("criterion 8  EMERGENCE    score %d   %d named-phenomenon actor script(s), %d special-case symbol(s)"
      % (em_score, len(phen_files), phen_symbols))
if phen_files:
    print("    %s" % ", ".join(phen_files))

# --- 9 and 10 need a SECOND run each, so they are reported as unmeasured unless the caller supplied one ----
# A score that quietly skips the expensive half is the hand-entered problem again, so an absent comparison
# scores 0 and says which run is missing rather than omitting the row.
def load_report(path):
    if not path or not os.path.exists(path):
        return None
    ln = None
    for x in open(path, errors="replace"):
        if x.startswith("SIM_REPORT="):
            ln = x[11:]
    return json.loads(ln) if ln else None

CONSERVED = ("h2o_closed_total", "element_C_total", "mineral_total", "o2_total", "oxidant_total",
             "nitrogen_all")
def worst_rel(a, b):
    worst = 0.0
    for k in CONSERVED:
        x, y = a.get(k), b.get(k)
        if isinstance(x, (int, float)) and isinstance(y, (int, float)) and x:
            worst = max(worst, abs((y - x) / x))
    return worst

rep_base = load_report(os.environ.get("LA_SCORE_BASE", ""))
rep_repeat = load_report(os.environ.get("LA_SCORE_REPEAT", ""))
rep_bare = load_report(os.environ.get("LA_SCORE_BARE", ""))
# Compared against the short BASE arm, never against the long main run: two runs of different lengths
# disagreeing says nothing about determinism.
ref = rep_base if rep_base is not None else d

if rep_repeat is None or rep_base is None:
    det_score = 0
    det_note = "no repeat pair (LA_SCORE_BASE + LA_SCORE_REPEAT, same seed, same length)"
else:
    dw = worst_rel(ref, rep_repeat)
    det_score = 4 if dw == 0.0 else band(dw, [0.01, 0.001, 0.000001])
    det_note = "worst conserved-total difference %.6g between two runs at one seed" % dw
print("criterion 9  DETERMINISM  score %d   %s" % (det_score, det_note))

if rep_bare is None or rep_base is None:
    obs_score = 0
    obs_note = "no presentation arm (LA_SCORE_BASE + LA_SCORE_BARE)"
else:
    ow = worst_rel(ref, rep_bare)
    obs_score = 4 if ow == 0.0 else band(ow, [0.01, 0.001, 0.000001])
    obs_note = "worst conserved-total difference %.6g between bare and the presentation layer" % ow
print("criterion 10 OBSERVER     score %d   %s" % (obs_score, obs_note))

scores = [m_score, e_score, c_score, p_score, s_score, i_score, mo_score, em_score, det_score, obs_score]
total = sum(scores)
print()
print("TOTAL %d / 40" % total)
print("PHYSICS_SCORE={\"matter\":%d,\"energy\":%d,\"constitutive\":%d,\"computed\":%d,\"seed\":%d,"
      "\"instrument\":%d,\"momentum\":%d,\"emergence\":%d,\"determinism\":%d,\"observer\":%d,"
      "\"total\":%d}" % tuple(scores + [total]))
print()
print("| date | commit | 1 matter | 2 energy | 3 constitutive | 4 computed | 5 seed | 6 instrument "
      "| 7 momentum | 8 emergence | 9 determinism | 10 observer | **total** | what moved |")
print("| DATE | `COMMIT` | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | **%d / 40** | WHAT MOVED |"
      % tuple(scores + [total]))
PY
