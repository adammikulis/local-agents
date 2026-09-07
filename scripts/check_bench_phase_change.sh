#!/usr/bin/env bash
# THE WATER PHASE LADDER against IAPWS: a melting plateau at the triple point 273.16 K / 611.657 Pa,
# costing the enthalpy of fusion 333.426 kJ/kg (Feistel & Wagner 2006); a two-phase cell ON the
# saturation curve (Wagner & Pruss 2002, IAPWS-95 eq. 2.5); a normal boiling point of 99.974 C.
# AT FIXED VOLUME THERE IS NO BOILING PLATEAU: the cell climbs the saturation curve instead.
# EXIT 0 within the bounds * 1 outside them * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_phase_change.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE="$(mktemp "${TMPDIR:-/tmp}/bench_phase.XXXXXX.py")"
trap 'rm -f "$JUDGE"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys

TRIPLE_T_C, TRIPLE_P_PA = 0.01, 611.657
L_FUSION = 333426.0            # J/kg at the triple point
BOIL_C, ATM = 99.974, 101325.0
TC_K, PC_PA = 647.096, 22.064e6
A = (-7.85951783, 1.84408259, -11.7866497, 22.6807411, -15.9618719, 1.80122502)
R_VAP = 461.52


def psat(t_k):
    x = 1.0 - t_k / TC_K
    return PC_PA * math.exp(TC_K / t_k * (A[0] * x + A[1] * x ** 1.5 + A[2] * x ** 3
                                          + A[3] * x ** 3.5 + A[4] * x ** 4 + A[5] * x ** 7.5))


MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: a caloric curve built FROM the IAPWS numbers -- ice to the triple point,
    # the fusion plateau, then the saturation curve at fixed volume -- and the same with the melting
    # point moved by a tenth of a kelvin.
    M0, N0, C_ICE, C_LIQ = 1.0, 2048, 2096.0, 4219.9
    shift = 0.1 if MODE == "broken" else 0.0
    e_lo = -M0 * C_ICE * 30.0
    e_hi = M0 * (L_FUSION + C_LIQ * 110.0)
    rr = []
    for c in range(N0):
        e = e_lo + (e_hi - e_lo) * c / (N0 - 1)
        if e < 0.0:
            t = TRIPLE_T_C + shift + e / (M0 * C_ICE)
            rr.append([e, t, psat(t + 273.15), 1.0, 0.0, 0.0])
        elif e < M0 * L_FUSION:
            rr.append([e, TRIPLE_T_C + shift, TRIPLE_P_PA,
                       1.0 - e / (M0 * L_FUSION), e / (M0 * L_FUSION), 0.0])
        else:
            t = TRIPLE_T_C + (e - M0 * L_FUSION) / (M0 * C_LIQ)
            p = psat(t + 273.15)
            vap = min(p / (R_VAP * (t + 273.15)) / M0, 0.999)
            rr.append([e, t, p, 0.0, 1.0 - vap, vap])
    d = {"kg_per_m3": M0, "cells": N0, "molar_mass_kg_mol": 0.018015,
         "columns": ["e_j_m3", "temp_c", "pressure_pa", "solid", "liquid", "vapour"], "rows": rr}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
rows, m = d["rows"], d["kg_per_m3"]


de = rows[1][0] - rows[0][0]
fails, detail = [], {"energy_step_j_m3": de}

# (a) and (b) THE MELTING PLATEAU. Its temperature, and its width in energy read by the lever rule: the
# liquid share of the condensate rises linearly with energy across it, so a least-squares line through
# the interior gives the two ends without the sweep's spacing entering twice.
mush = [r for r in rows if r[3] > 1e-6 and r[4] > 1e-6]
if len(mush) < 16:
    print("check_bench_phase_change: the sweep crossed no melting plateau, so nothing was examined.",
          file=sys.stderr)
    sys.exit(2)
t_plateau = sum(r[1] for r in mush) / len(mush)
p_plateau = sum(r[2] for r in mush) / len(mush)
detail["plateau_t_c"] = t_plateau
detail["plateau_p_pa"] = p_plateau
detail["plateau_t_spread_k"] = max(r[1] for r in mush) - min(r[1] for r in mush)
# The melting point moves with pressure at -7.4e-8 K/Pa (Clausius-Clapeyron on ice Ih), so across a
# plateau whose pressure barely moves the temperature is one number and the bound is that slope.
bound_t = max(7.4e-8 * abs(p_plateau - TRIPLE_P_PA), 1e-3)
ref_t = TRIPLE_T_C - 7.4e-8 * (p_plateau - TRIPLE_P_PA)
detail["plateau_reference_t_c"] = ref_t
if abs(t_plateau - ref_t) > bound_t:
    fails.append("the melting plateau sits at %.6f C at %.2f Pa; ice and water coexist at %.6f C there "
                 "(the triple point is 0.01 C at 611.657 Pa and the boundary moves at -7.4e-8 K/Pa), "
                 "so it is out by %.6f K against a bound of %.6f K."
                 % (t_plateau, p_plateau, ref_t, abs(t_plateau - ref_t), bound_t))

xs = [r[0] for r in mush]
ys = [r[4] / max(r[3] + r[4], 1e-30) for r in mush]
n = len(xs)
mx, my = sum(xs) / n, sum(ys) / n
sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
sxx = sum((x - mx) ** 2 for x in xs)
slope = sxy / sxx if sxx > 0.0 else 0.0
width = 1.0 / slope if slope > 0.0 else 0.0
expect_w = m * L_FUSION
bound_w = 2.0 * de / expect_w
rel_w = abs(width - expect_w) / expect_w
detail["plateau_width_j_m3"] = width
detail["plateau_width_reference_j_m3"] = expect_w
if rel_w > bound_w:
    fails.append("melting the water cost %.6g J/m^3; %.4g kg of ice takes %.6g J at the enthalpy of "
                 "fusion, a relative %.4g against the sweep's own %.4g."
                 % (width, m, expect_w, rel_w, bound_w))

# (c) THE SATURATION LOCUS. Liquid and vapour together fix the pressure at p_sat(T); the fixed-volume
# cell climbs that curve rather than pausing on a boiling plateau.
two = [r for r in rows if r[4] > 1e-6 and r[5] > 1e-6 and r[3] <= 1e-9 and r[1] > 1.0]
if len(two) < 16:
    print("check_bench_phase_change: the sweep found no liquid-and-vapour cell above the melting "
          "point, so the saturation locus was not examined.", file=sys.stderr)
    sys.exit(2)
worst_p, worst_at = 0.0, None
for r in two:
    ref = psat(r[1] + 273.15)
    rel = abs(r[2] - ref) / ref
    if rel > worst_p:
        worst_p, worst_at = rel, (r[1], r[2], ref)
# The sweep steps the energy, so the pressure it reports is one sample coarse in temperature; the
# saturation curve's own slope over that step is what the reading is entitled to.
dt_step = (two[-1][1] - two[0][1]) / max(len(two) - 1, 1)
tk = two[len(two) // 2][1] + 273.15
bound_p = abs(psat(tk + dt_step) - psat(tk)) / psat(tk) + 1e-5
detail["saturation_worst_rel"] = worst_p
detail["saturation_bound_rel"] = bound_p
if worst_p > bound_p:
    fails.append("a cell holding both liquid and vapour stands at %.6g Pa at %.3f C; the saturation "
                 "pressure there is %.6g Pa, a relative %.4g against a bound of %.4g."
                 % (worst_at[1], worst_at[0], worst_at[2], worst_p, bound_p))

# (d) THE NORMAL BOILING POINT: where that locus passes one standard atmosphere.
boil = None
for i in range(1, len(two)):
    if two[i - 1][2] < ATM <= two[i][2]:
        f = (ATM - two[i - 1][2]) / (two[i][2] - two[i - 1][2])
        boil = two[i - 1][1] + f * (two[i][1] - two[i - 1][1])
        break
detail["boiling_point_c"] = boil
if boil is None:
    fails.append("the two-phase locus never reaches one standard atmosphere, so the boiling point "
                 "went unmeasured.")
elif abs(boil - BOIL_C) > 2.0 * dt_step:
    fails.append("the locus passes 101325 Pa at %.4f C; water boils at %.3f C, out by %.4f K against "
                 "the sweep's own %.4f K spacing." % (boil, BOIL_C, abs(boil - BOIL_C), 2.0 * dt_step))

# Reported, not gated: the apparent heat capacities either side of the plateau.
for name, lo, hi, phase in (("ice", -25.0, -5.0, 3), ("liquid", 5.0, 25.0, 4)):
    seg = [r for r in rows if lo < r[1] < hi and r[phase] > 0.9]
    if len(seg) > 3:
        detail[name + "_cp_j_kgk"] = (seg[-1][0] - seg[0][0]) / (seg[-1][1] - seg[0][1]) / m

print("BENCH_PHASE_CHANGE=" + json.dumps(
    {"error": {"plateau_k": round(abs(t_plateau - ref_t), 8), "fusion_rel": round(rel_w, 8),
               "saturation_rel": round(worst_p, 8)},
     "bound": {"plateau_k": round(bound_t, 8), "fusion_rel": round(bound_w, 8),
               "saturation_rel": round(bound_p, 8)},
     "order": 0, "detail": detail}, sort_keys=True))
for msg in fails:
    print("check_bench_phase_change: " + msg, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects a ladder built from the IAPWS numbers themselves, so its bounds are" >&2
  echo "       not ones any solver could meet." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a melting point a tenth of a kelvin out, so it cannot fail." >&2
  exit 2
fi

# THE RIG RIDES THE SHARED DEVICE BATCH: one launch holds every rig that only needs a device.
out="$(la_rig bench_phase_change '^BENCH_RAW_PHASE_CHANGE=' "res://$PROBE")"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_PHASE_CHANGE=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_PHASE_CHANGE line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds. The same derive over the matter the seed laid must publish a
# present, finite water inventory and a phase split, or the ladder the rig walked is not the planet's.
FRAMES="${LA_BENCH_PC_FRAMES:-6}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 1 "$FRAMES" "water_liquid_total,ice_cells,all_h2o")"
la_rung_require "$world" water_liquid_total all_h2o || exit 2
printf 'BENCH_PHASE_CHANGE_WORLD={"water_liquid_total":%s,"all_h2o":%s}\n' \
  "$(la_rung_value "$world" water_liquid_total)" "$(la_rung_value "$world" all_h2o)"
echo "check_bench_phase_change: OK"
