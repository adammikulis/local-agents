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

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_phase.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
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

out="$(LA_DONE_RE='^BENCH_PHASE_CHANGE_DONE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
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

# ARM 1b -- IRON AND FORSTERITE. Each melts at a POINT, so its caloric curve has a plateau: the solid
# branch and the melt branch are straight lines in (T, E) whose extrapolations to it are apart by exactly
# the enthalpy of fusion of the mass present. The plateau and both branches come off the swept curve.
MELT_JUDGE="$(mktemp "${TMPDIR:-/tmp}/bench_melt.XXXXXX.py")"
trap 'rm -f "$JUDGE" "$MELT_JUDGE"' EXIT INT TERM
cat > "$MELT_JUDGE" <<'PYEOF'
import json, math, os, sys

# Iron: melts at 1538 C, dHfus 13.81 kJ/mol over 55.845 g/mol = 2.473e5 J/kg (Desai 1986, J. Phys. Chem.
# Ref. Data 15:967; CRC 97th ed.). Forsterite: 2163 K = 1890 C, dHfus 142 kJ/mol (Bowen & Andersen 1914;
# Richet et al. 1993, GRL 20:1675) -- per mole, so the mass basis is the swept row's own molar mass.
CITED = {"metal": (1538.0, 2.473e5, None), "olivine": (1890.0, None, 1.42e5)}


def synth(sub, shift):
    """The caloric curve the cited numbers themselves describe: solid, plateau, melt."""
    t_melt, l_kg, l_mol = CITED[sub]
    mm, kg, n = 0.055845 if sub == "metal" else 0.1406931, 3500.0, 2048
    lat = kg * (l_kg if l_kg is not None else l_mol / mm) * (1.0 + shift)
    c_sol, c_liq, span = kg * 449.0, kg * 824.0, 300.0
    e0 = c_sol * (t_melt + 273.15)
    lo, hi = e0 - c_sol * span, e0 + lat + c_liq * span
    rows = []
    for i in range(n):
        e = lo + (hi - lo) * i / (n - 1)
        if e < e0:
            rows.append([e, t_melt - (e0 - e) / c_sol])
        elif e < e0 + lat:
            rows.append([e, t_melt])
        else:
            rows.append([e, t_melt + (e - e0 - lat) / c_liq])
    return {"substance": sub, "kg_per_m3": kg, "cells": n, "molar_mass_kg_mol": mm,
            "columns": ["e_j_m3", "temp_c"], "rows": rows}


MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    sweeps = [synth(s, 0.1 if MODE == "broken" else 0.0) for s in CITED]
else:
    sweeps = [json.loads(l.split("=", 1)[1]) for l in sys.stdin.read().splitlines()
              if l.startswith("BENCH_RAW_MELT_LADDER=")]

fails, out = [], {}
for d in sweeps:
    sub = d["substance"]
    if sub not in CITED:
        fails.append("the rig swept %s, which this gate cites nothing for." % sub)
        continue
    t_melt, l_kg, l_mol = CITED[sub]
    want = d["kg_per_m3"] * (l_kg if l_kg is not None else l_mol / d["molar_mass_kg_mol"])
    rows = d["rows"]
    de = abs(rows[1][0] - rows[0][0])
    span = rows[-1][1] - rows[0][1]
    # THE PLATEAU, found from the curve alone: the longest run the added energy did not warm.
    flat = max(1e-4 * span, 1e-3)
    best_i = best_n = run_i = run_n = 0
    for i in range(1, len(rows)):
        if abs(rows[i][1] - rows[i - 1][1]) <= flat:
            run_n += 1
        else:
            run_i, run_n = i, 0
        if run_n > best_n:
            best_i, best_n = run_i, run_n
    if best_n < 16:
        print("check_bench_phase_change: the %s sweep crossed no melting plateau, so nothing was "
              "examined." % sub, file=sys.stderr)
        sys.exit(2)
    plateau = sum(r[1] for r in rows[best_i:best_i + best_n + 1]) / (best_n + 1)
    # A least-squares line through each branch, clear of the plateau by a tenth of the sweep's span.
    edge = max(0.05 * span, 5.0)
    ends = []
    for lo, hi in ((-1e30, plateau - edge), (plateau + edge, 1e30)):
        seg = [r for r in rows if lo <= r[1] <= hi]
        if len(seg) < 8:
            break
        k = len(seg)
        mt, me = sum(r[1] for r in seg) / k, sum(r[0] for r in seg) / k
        sxx = sum((r[1] - mt) ** 2 for r in seg)
        if sxx <= 0.0:
            break
        ends.append(me + sum((r[1] - mt) * (r[0] - me) for r in seg) / sxx * (plateau - mt))
    if len(ends) < 2:
        print("check_bench_phase_change: the %s sweep resolved only one side of its melting point."
              % sub, file=sys.stderr)
        sys.exit(2)
    got = ends[1] - ends[0]
    bound = 2.0 * de / want
    rel = abs(got - want) / want
    out[sub] = {"plateau_t_c": plateau, "reference_t_c": t_melt, "latent_j_m3": got,
                "reference_j_m3": want, "rel": rel, "bound": bound}
    # The melting point moves with pressure at T dv / L, under a kelvin over the pressure this sweep
    # stands at, so at one atmosphere it is the measured number.
    if abs(plateau - t_melt) > 2.0:
        fails.append("%s melts at %.3f C in the sim; it melts at %.1f C, out by %.3f K."
                     % (sub, plateau, t_melt, abs(plateau - t_melt)))
    if rel > bound:
        fails.append("melting the %s cost %.6g J/m^3; its enthalpy of fusion over that mass is %.6g "
                     "J/m^3, a relative %.4g against the sweep's own %.4g." % (sub, got, want, rel, bound))
missing = sorted(set(CITED) - set(out))
if missing:
    print("check_bench_phase_change: the rig published no melting sweep for %s." % ", ".join(missing),
          file=sys.stderr)
    sys.exit(2)
print("BENCH_MELT_LADDER=" + json.dumps(out, sort_keys=True))
for msg in fails:
    print("check_bench_phase_change: " + msg, file=sys.stderr)
sys.exit(1 if fails else 0)
PYEOF

if ! LA_BENCH_SELFTEST=exact python3 "$MELT_JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects a caloric curve built from the cited melting points and fusion" >&2
  echo "       enthalpies themselves, so its bounds are not ones any solver could meet." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$MELT_JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a latent heat a tenth out, so it cannot fail." >&2
  exit 2
fi

printf '%s\n' "$out" | python3 "$MELT_JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds. The same derive over the matter the seed laid must publish a
# present, finite water inventory and a phase split, or the ladder the rig walked is not the planet's.
FRAMES="${LA_BENCH_PC_FRAMES:-6}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 1 "$FRAMES" "water_liquid_total,ice_cells,all_h2o")"
la_rung_require "$world" water_liquid_total all_h2o || exit $?
printf 'BENCH_PHASE_CHANGE_WORLD={"water_liquid_total":%s,"all_h2o":%s}\n' \
  "$(la_rung_value "$world" water_liquid_total)" "$(la_rung_value "$world" all_h2o)"
echo "check_bench_phase_change: OK"
