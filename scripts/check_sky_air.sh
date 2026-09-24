#!/usr/bin/env bash
# THE SKY IS DRAWN THROUGH THE WORLD'S OWN AIR. A photographed slice that holds air publishes a Rayleigh
# coefficient that is positive in every channel, with the channel ratios the seeded gases' own
# cross-sections give, re-derived here from PhysicalConstants.gd. A world with no solved gravity stands no
# column and publishes no air, so the same view draws no Rayleigh sky there.
# EXIT 0 the sky is the world's air · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool python3

SCENE="addons/local_agents/game/VoxelWorld.tscn"
BOX="${LA_SKY_AIR_BOX:-0,surface,0,3,24,3,5120,10}"
CONSTANTS="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
for f in "$ROOT/$SCENE" "$CONSTANTS"; do
	[ -f "$f" ] || { echo "check_sky_air: no file at $f" >&2; exit 2; }
done
DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_sky_air.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT INT TERM

shoot() {  # <rung> <log>
	LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_SKY_AIR_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" \
		--path "$ROOT" "$SCENE" -- --sandbox --ui "--rung=$1" --planet-only "--shoot=$DIR/shot_$1.png" \
		"--shots=30:10:0" --local-hour=12 --shoot-frames=90 --shoot-size=320x200 > "$2" 2>&1
	echo $?
}
air_rc="$(shoot 2 "$DIR/air.log")"
none_rc="$(shoot 0 "$DIR/none.log")"

python3 - "$DIR/air.log" "$DIR/none.log" "$air_rc" "$none_rc" "$CONSTANTS" <<'PY'
import json, math, re, sys

air_log, none_log, air_rc, none_rc, constants = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
src = open(constants).read()


def const(name):
    m = re.search(r"^const %s: float = ([-0-9.eE+]+)" % name, src, re.M)
    return float(m.group(1)) if m else None


def array(name):
    m = re.search(r"^const %s: Array\[float\] = \[([^\]]*)\]" % name, src, re.M)
    return [float(v) for v in m.group(1).split(",")] if m else None


need = {"N2_SELLMEIER_B": array("N2_SELLMEIER_B"), "N2_SELLMEIER_C_UM2": array("N2_SELLMEIER_C_UM2"),
        "N2_REFRACTIVITY_REF_P_PA": const("N2_REFRACTIVITY_REF_P_PA"), "N2_KING_FACTOR": const("N2_KING_FACTOR"),
        "N2_KING_FACTOR_UM2": const("N2_KING_FACTOR_UM2"), "CO2_REFRACTIVITY_B": array("CO2_REFRACTIVITY_B"),
        "CO2_REFRACTIVITY_C_PER_UM2": array("CO2_REFRACTIVITY_C_PER_UM2"), "CO2_KING_FACTOR": const("CO2_KING_FACTOR"),
        "CO2_KING_FACTOR_CM2": const("CO2_KING_FACTOR_CM2"), "H2_RAYLEIGH_D_CM2": array("H2_RAYLEIGH_D_CM2"),
        "PREBIOTIC_MOLE_FRAC_CO2": const("PREBIOTIC_MOLE_FRAC_CO2"), "PREBIOTIC_MOLE_FRAC_H2": const("PREBIOTIC_MOLE_FRAC_H2"),
        "STANDARD_PRESSURE_PA": const("STANDARD_PRESSURE_PA"), "KELVIN_OFFSET": const("KELVIN_OFFSET"),
        "BOLTZMANN_J_K": const("BOLTZMANN_J_K")}
missing = [k for k, v in need.items() if v is None]
if missing:
    print("check_sky_air: PhysicalConstants.gd declares none of %s, so there is no cross-section to check"
          % ", ".join(missing), file=sys.stderr)
    sys.exit(2)
c = need


def lorentz_lorenz(n2m1, per_m3, lam_m):
    ll = n2m1 / (n2m1 + 3.0)
    return 24.0 * math.pi ** 3 / (lam_m ** 4 * per_m3 ** 2) * ll * ll


def sigma(gas, lam_m):
    um2 = (lam_m * 1.0e6) ** 2
    if gas == "n2":
        x = sum(b * um2 / (um2 - cc) for b, cc in zip(c["N2_SELLMEIER_B"], c["N2_SELLMEIER_C_UM2"]))
        ref = c["N2_REFRACTIVITY_REF_P_PA"] / (c["BOLTZMANN_J_K"] * c["KELVIN_OFFSET"])
        return lorentz_lorenz(x, ref, lam_m) * (c["N2_KING_FACTOR"] + c["N2_KING_FACTOR_UM2"] / um2)
    if gas == "co2":
        nm1 = sum(b / (cc - 1.0 / um2) for b, cc in zip(c["CO2_REFRACTIVITY_B"], c["CO2_REFRACTIVITY_C_PER_UM2"]))
        ref = c["STANDARD_PRESSURE_PA"] / (c["BOLTZMANN_J_K"] * c["KELVIN_OFFSET"])
        nu = 1.0e-2 / lam_m
        return lorentz_lorenz(nm1 * (2.0 + nm1), ref, lam_m) * (c["CO2_KING_FACTOR"] + c["CO2_KING_FACTOR_CM2"] * nu * nu)
    a = lam_m * 1.0e10
    d = c["H2_RAYLEIGH_D_CM2"]
    return 1.0e-4 * (d[0] / a ** 4 + d[1] / a ** 6 + d[2] / a ** 8)


x = {"co2": c["PREBIOTIC_MOLE_FRAC_CO2"], "h2": c["PREBIOTIC_MOLE_FRAC_H2"]}
x["n2"] = 1.0 - x["co2"] - x["h2"]
want = [sum(x[g] * sigma(g, nm * 1.0e-9) for g in x) for nm in (680.0, 550.0, 440.0)]


def last_air(path):
    rows = [l[len("SKY_AIR="):] for l in open(path, errors="replace").read().splitlines() if l.startswith("SKY_AIR=")]
    return json.loads(rows[-1]) if rows else None


fails = []
air = last_air(air_log)
none = last_air(none_log)
if air is None or none is None:
    print("check_sky_air: a photographed run published no SKY_AIR (air arm exit %d, no-gravity arm exit %d), so"
          " the air the sky was drawn through went unmeasured." % (air_rc, none_rc), file=sys.stderr)
    sys.exit(2)
beta = air.get("beta_ground_per_m", [])
if not air.get("air") or len(beta) != 3 or not all(b > 0.0 for b in beta):
    fails.append("the slice holding air drew its sky through %s" % json.dumps(air))
else:
    for ch, name in ((1, "green"), (2, "blue")):
        got = beta[ch] / beta[0]
        rel = abs(got / (want[ch] / want[0]) - 1.0)
        if rel > 1.0e-6:
            fails.append("the %s-to-red Rayleigh ratio is %.6g where the seeded gases give %.6g"
                         % (name, got, want[ch] / want[0]))
# THE CONTROL. With no solved gravity no column stands, and the same view must say so.
if none.get("air") or none.get("beta_ground_per_m"):
    fails.append("the world with no solved gravity drew a Rayleigh sky: %s" % json.dumps(none))
for rc, arm in ((air_rc, "air"), (none_rc, "no-gravity")):
    if rc != 0:
        fails.append("the %s arm exited %d" % (arm, rc))
print("SKY_AIR_CHECK=%s" % json.dumps({"air": air, "none": none}))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_sky_air: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_sky_air: OK")
PY
