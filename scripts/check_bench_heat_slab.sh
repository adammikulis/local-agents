#!/usr/bin/env bash
# CONDUCTION IN A ROCK SLAB against erfc, the half-space with a step at one end (Carslaw & Jaeger,
# Conduction of Heat in Solids, 2.5), at alpha = k/(rho c) for measured basalt (Clauser & Huenges 1995;
# Robertson 1988). Bounds: the 3-point Laplacian's truncation, second-order convergence, and the
# maximum principle at any step size. EXIT 0 within * 1 broken * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_heat_slab.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE="$(mktemp "${TMPDIR:-/tmp}/bench_heat.XXXXXX.py")"
trap 'rm -f "$JUDGE"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys

K_BASALT, RHO_BASALT, C_BASALT = 2.5, 2900.0, 840.0
ALPHA = K_BASALT / (RHO_BASALT * C_BASALT)
MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: the erfc profile itself, sampled on each grid, with a second-order
    # departure so the convergence arm has something to measure; then the same with a wrong diffusivity.
    def arm(n, dt, steps, alpha):
        L, t = 1.28 / n, dt * steps
        eta = L / (2.0 * math.sqrt(ALPHA * t))
        T = [20.0 + 500.0 * math.erfc(c * L / (2.0 * math.sqrt(alpha * t))) + 1e-4 * eta * eta
             for c in range(n)]
        T[0] = 520.0
        return {"cells": n, "cell_m": L, "dt_s": dt, "steps": steps, "t_s": t, "temp": T,
                "conductivity": [K_BASALT] * n, "rho_bulk": [RHO_BASALT] * n}
    a = ALPHA * (1.10 if MODE == "broken" else 1.0)
    d = {"slab_m": 1.28, "t_cold_c": 20.0, "t_hot_c": 520.0,
         "coarse": arm(64, 100.0, 62, a), "fine": arm(128, 25.0, 248, a),
         "stress": arm(128, 100.0, 62, a)}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
# max |d4 erfc / d eta4| over eta, which the 3-point Laplacian's dx^2/12 truncation multiplies.
D4_MAX = 4.40

report, fails, errs = {}, [], {}
for key in ("coarse", "fine", "stress"):
    a = d[key]
    n, L, t, T = a["cells"], a["cell_m"], a["t_s"], a["temp"]
    t0, ts = d["t_cold_c"], T[0]
    deta = L / (2.0 * math.sqrt(ALPHA * t))
    err = 0.0
    for c in range(1, n):
        ref = t0 + (ts - t0) * math.erfc(c * L / (2.0 * math.sqrt(ALPHA * t)))
        err += abs(T[c] - ref)
    errs[key] = err / ((n - 1) * abs(ts - t0))
    bound = deta * deta / 12.0 * D4_MAX
    lo, hi = min(d["t_cold_c"], d["t_hot_c"]), max(d["t_cold_c"], d["t_hot_c"])
    excursion = max(max(lo - min(T), 0.0), max(max(T) - hi, 0.0)) / (hi - lo)
    report[key] = {"L1_rel": errs[key], "bound": bound, "dx_over_diffusion_length": deta,
                   "excursion": excursion, "conductivity": a["conductivity"][1],
                   "rho_bulk": a["rho_bulk"][1], "dt_s": a["dt_s"],
                   "diffusion_number": ALPHA * a["dt_s"] / (L * L)}
    if excursion > 1e-6:
        fails.append("%s: a cell reached %.2f C on a slab that started between %.0f and %.0f C, %.3g "
                     "of the range outside it. The heat equation has a maximum principle: with the ends "
                     "held, no interior point may pass either of them. The diffusion number here is "
                     "%.3f, past the explicit limit of 1/2, and the row's own temporal level did not "
                     "refine." % (key, min(T) if lo - min(T) > max(T) - hi else max(T), lo, hi,
                                  excursion, ALPHA * a["dt_s"] / (L * L)))
    if key != "stress" and errs[key] > bound:
        fails.append("%s: the L1 error is %.4g of the temperature step against a bound of %.4g, which "
                     "is the 3-point Laplacian's own dx^2/12 truncation on this profile."
                     % (key, errs[key], bound))

order = math.log(errs["coarse"] / max(errs["fine"], 1e-30)) / math.log(2.0)
if order < 1.7:
    fails.append("the L1 error converges at order %.3f. A 3-point Laplacian on a uniform grid is second "
                 "order in space, and the step falls as dx^2 between these two arms, so both halves of "
                 "the error are second order." % order)

k, rho = d["coarse"]["conductivity"][1], d["coarse"]["rho_bulk"][1]
if abs(k - K_BASALT) > 0.4 * K_BASALT or abs(rho - RHO_BASALT) > 0.05 * RHO_BASALT:
    fails.append("the slab conducts at %.4g W/mK and weighs %.4g kg/m^3; measured basalt is "
                 "%.4g W/mK and %.4g kg/m^3, so the erfc reference is not this rock's."
                 % (k, rho, K_BASALT, RHO_BASALT))

print("BENCH_HEAT_SLAB=" + json.dumps(
    {"error": {k2: round(v["L1_rel"], 8) for k2, v in report.items()},
     "bound": {k2: round(v["bound"], 8) for k2, v in report.items()},
     "order": round(order, 3), "alpha_m2_s": ALPHA, "detail": report}, sort_keys=True))
for m in fails:
    print("check_bench_heat_slab: " + m, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects the erfc solution itself, so its bound is not one any solver could" >&2
  echo "       meet. Refusing to report a verdict." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a slab diffusing ten percent too fast, so it cannot fail." >&2
  exit 2
fi

# THE RIG RIDES THE SHARED DEVICE BATCH: one launch holds every rig that only needs a device.
out="$(la_rig bench_heat_slab '^BENCH_RAW_HEAT_SLAB=' "res://$PROBE")"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_HEAT_SLAB=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_HEAT_SLAB line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the conduction rung's own world. The rock's decay heat is the source term that sits beside
# the conduction row, and an absent reading means the row is not in the world the sim seeds.
FRAMES="${LA_BENCH_HS_FRAMES:-8}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 4 "$FRAMES" "radiogenic,all_temp_max")"
la_rung_require "$world" radiogenic all_temp_max || exit 2
printf 'BENCH_HEAT_SLAB_WORLD={"radiogenic":%s,"all_temp_max":%s}\n' \
  "$(la_rung_value "$world" radiogenic)" "$(la_rung_value "$world" all_temp_max)"
echo "check_bench_heat_slab: OK"
