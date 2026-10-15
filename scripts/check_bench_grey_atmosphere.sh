#!/usr/bin/env bash
# RADIATIVE EQUILIBRIUM against Stefan-Boltzmann (Stefan 1879; Boltzmann 1884; CODATA 2018 sigma;
# basalt emissivity from Salisbury & D'Aria 1992), a lit plate at (F(1-A)/(2 eps sigma))^1/4 under
# 1361 W/m^2 (Kopp & Lean 2011), and the Eddington skin temperature T_s/2^(1/4), which is
# T^4 = (Te^4/2)(1+3 tau/2) at tau = 0 (Eddington 1916; Goody & Yung 1989, 2.4). Detailed balance is
# the sharp one (Prevost 1791). EXIT 0 within * 1 outside * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_grey_atmosphere.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_grey.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys

SIGMA, KELVIN, EPS_BASALT = 5.670374419e-8, 273.15, 0.95
FACES = 6.0                        # an interior cell radiates through every face; div = 1/L each
MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: a plate and a skin layer that satisfy Stefan-Boltzmann, detailed balance
    # and the two-stream balance exactly; then the same with the plate five percent warm.
    L0, DT0, F0, ALB = 100.0, 1.0, 1361.0, 0.15
    t_ref = (F0 * (1.0 - ALB) / (2.0 * EPS_BASALT * SIGMA)) ** 0.25 * (1.05 if MODE == "broken" else 1.0)
    em = EPS_BASALT * SIGMA * t_ref ** 4 * DT0 * FACES / L0
    plate = {"t_c": t_ref - KELVIN, "emitted": em,
             "absorbed": F0 * (1.0 - ALB) * DT0 / L0 + (FACES - 2.0) / FACES * em,
             "albedo": ALB, "emissivity": EPS_BASALT, "solar_w_m2": F0}
    ts, ea, ee = 500.0, 0.06, 0.06
    t1 = ts * (ea * EPS_BASALT / (2.0 * ee)) ** 0.25
    se = EPS_BASALT * SIGMA * ts ** 4 * DT0 * FACES / L0
    le = ee * SIGMA * t1 ** 4 * DT0 * FACES / L0
    skin = {"t_c": t1 - KELVIN, "emitted": le,
            "absorbed": (FACES - 2.0) / FACES * le + ea * se / FACES,
            "surface_t_c": ts - KELVIN, "surface_emitted": se, "surface_hold_emitted": se}
    d = {"cell_m": L0, "width": 7, "dt_s": DT0, "plate": plate, "skin": skin}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
L, dt = d["cell_m"], d["dt_s"]
fails = {}

# (b) THE LIT PLATE. Sunlight on one face, radiation out of the two that face the box edge.
p = d["plate"]
t_eq = p["t_c"] + KELVIN
solar = p["solar_w_m2"] * (1.0 - p["albedo"]) * dt / L
ref = (p["solar_w_m2"] * (1.0 - p["albedo"]) / (2.0 * EPS_BASALT * SIGMA)) ** 0.25
# DETAILED BALANCE, and it needs no band table: two cells at the SAME temperature emit with the same
# weights they absorb with, so whatever the bands are, the exchange between them cancels identically
# (Prevost 1791). The plate's four lateral neighbours are its own state, so what it gains from them
# must equal the four sixths of its emission that go to them, to float32 and no further.
lateral_out = (FACES - 2.0) / FACES * p["emitted"]
lateral_in = p["absorbed"] - solar
balance = abs(lateral_in - lateral_out) / max(p["emitted"], 1e-30)
BALANCE_BOUND = 1e-5
if balance > BALANCE_BOUND:
    fails["balance"] = ("identical neighbours do not exchange evenly: the plate emitted %.6g J/m^3 "
                        "toward its four lateral neighbours and gathered %.6g back from cells in the "
                        "same state, a relative %.4g against a bound of %.4g."
                        % (lateral_out, lateral_in, balance, BALANCE_BOUND))
# What that residual costs the equilibrium: T goes as the fourth root of the net, so the temperature
# a march closing to `balance` is entitled to differs by a quarter of it.
bound_plate = 0.25 * max(BALANCE_BOUND * p["emitted"] / solar, 8.0 * 1.2e-7) * ref
plate_err = abs(t_eq - ref)
if plate_err > bound_plate:
    fails["plate"] = ("a lit rock plate settled at %.4f K; absorbing %.1f W/m^2 and radiating from two "
                      "faces at emissivity %.2f it must settle at %.4f K (bound %.4g K)."
                      % (t_eq, p["solar_w_m2"] * (1.0 - p["albedo"]), EPS_BASALT, ref, bound_plate))

# (a) STEFAN-BOLTZMANN on the held surface, read straight off what the march emitted.
s = d["skin"]
ts = s["surface_t_c"] + KELVIN
eps_surface = s["surface_emitted"] * L / (FACES * SIGMA * ts ** 4 * dt)
if abs(eps_surface - EPS_BASALT) > 1e-3:
    fails["stefan"] = ("the surface at %.2f K emitted %.6g J/m^3 per step, which is sigma T^4 times an "
                       "emissivity of %.5f; measured basalt is %.2f."
                       % (ts, s["surface_emitted"], eps_surface, EPS_BASALT))

# (c) THE SKIN LAYER. Its own emissivity comes out of what it emitted at its equilibrium temperature,
# and its absorptivity of the surface's spectrum out of what it gained beyond the lateral exchange.
t1 = s["t_c"] + KELVIN
eps_emit = s["emitted"] * L / (FACES * SIGMA * t1 ** 4 * dt)
from_below = s["absorbed"] - (FACES - 2.0) / FACES * s["emitted"]
eps_abs = from_below / max(s["surface_emitted"] / FACES, 1e-30)
grey = ts / 2.0 ** 0.25
# The two-stream balance the layer must satisfy whatever its bands are: what it takes from the surface
# equals what it sends up and down.
band = ts * (eps_abs * EPS_BASALT / (2.0 * eps_emit)) ** 0.25 if eps_emit > 0.0 else 0.0
bound_skin = 0.02 * band
if abs(t1 - band) > bound_skin:
    fails["skin"] = ("the layer settled at %.3f K; taking %.5f of the surface's spectrum and emitting "
                     "at %.5f it must balance at %.3f K (bound %.3f K)."
                     % (t1, eps_abs, eps_emit, band, bound_skin))

print("BENCH_GREY_ATMOSPHERE=" + json.dumps({
    "error": {"plate_k": round(plate_err, 6), "stefan_emissivity": round(abs(eps_surface - EPS_BASALT), 8),
              "skin_k": round(abs(t1 - band), 4), "detailed_balance": round(balance, 9)},
    "bound": {"plate_k": round(bound_plate, 8), "stefan_emissivity": 1e-3,
              "skin_k": round(bound_skin, 4), "detailed_balance": BALANCE_BOUND},
    "order": 0,
    "detail": {"plate_equilibrium_k": round(t_eq, 4), "plate_reference_k": round(ref, 4),
               "surface_k": round(ts, 3), "surface_emissivity": round(eps_surface, 5),
               "skin_k": round(t1, 3), "skin_two_stream_k": round(band, 3),
               "skin_grey_eddington_k": round(grey, 3),
               "grey_departure_k": round(t1 - grey, 3),
               "layer_absorptivity": round(eps_abs, 6), "layer_emissivity": round(eps_emit, 6)}},
    sort_keys=True))
for k in sorted(fails):
    print("check_bench_grey_atmosphere: " + fails[k], file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects a march that satisfies Stefan-Boltzmann and detailed balance exactly," >&2
  echo "       so its bounds are not ones any solver could meet." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a plate five percent off its radiative equilibrium, so it cannot fail." >&2
  exit 2
fi

out="$(LA_DONE_RE='^BENCH_RAW_GREY_ATMOSPHERE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_GREY_ATMOSPHERE=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_GREY_ATMOSPHERE line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds, at the radiation rung. Its own Stefan-Boltzmann residual must be
# present and finite, or the march the rig judged is not the planet's.
FRAMES="${LA_BENCH_GA_FRAMES:-8}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 7 "$FRAMES" "rad_emitted,rad_absorbed,rad_sb_rel_max")"
la_rung_require "$world" rad_emitted rad_absorbed || exit 2
printf 'BENCH_GREY_ATMOSPHERE_WORLD={"rad_emitted":%s,"rad_absorbed":%s}\n' \
  "$(la_rung_value "$world" rad_emitted)" "$(la_rung_value "$world" rad_absorbed)"
echo "check_bench_grey_atmosphere: OK"
