#!/usr/bin/env bash
# THE SKY IS DRAWN THROUGH THE WORLD'S OWN AIR. The substance rows reproduce measured Rayleigh cross-sections.
# A photographed slice holding air publishes the cell it read: its scale height is R T / (M g) and its
# coefficient sum sigma_i n_i exp(h / H), off that cell's own pressure, temperature, gravity, height and
# gases, which are the air the seed laid. A world with gravity and no air, rung 1, draws no Rayleigh sky.
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
SUBSTANCES="$ROOT/addons/local_agents/gdextensions/localagents/src/LASubstances.cpp"
OPTICS="$ROOT/addons/local_agents/gdextensions/localagents/src/LASubstanceOptics.cpp"
CONSTANTS="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
SKY="$ROOT/addons/local_agents/game/render/SkyView.gd"
for f in "$ROOT/$SCENE" "$SUBSTANCES" "$OPTICS" "$CONSTANTS" "$SKY"; do
	[ -f "$f" ] || { echo "check_sky_air: no file at $f" >&2; exit 2; }
done
DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_sky_air.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT INT TERM

cat > "$DIR/check.py" <<'PY'
import ast, json, math, operator, re, sys

mode, subst_path, optics_path, const_path, sky_path = sys.argv[1:6]
TOL = 1.0e-5


def cannot(msg):
    print("check_sky_air: " + msg, file=sys.stderr)
    sys.exit(2)


OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
       ast.USub: operator.neg, ast.UAdd: operator.pos}


def evaluate(text, name=None):
    def ev(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return float(node.value)
        if isinstance(node, ast.BinOp) and type(node.op) in OPS:
            return OPS[type(node.op)](ev(node.left), ev(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in OPS:
            return OPS[type(node.op)](ev(node.operand))
        if isinstance(node, ast.Name) and name is not None:
            return name(node.id)
        cannot("no number in `%s`" % text.strip())
    return ev(ast.parse(text.strip(), mode="eval").body)


gd = dict(re.findall(r"^const ([A-Z_0-9]+): (?:float|int) = ([^#\n]+)", open(const_path).read(), re.M))


def const(n, seen=()):
    if n not in gd or n in seen:
        cannot("PhysicalConstants.gd declares no %s" % n)
    return evaluate(gd[n], lambda x: const(x, seen + (n,)))


KB, T0, R = const("BOLTZMANN_J_K"), const("KELVIN_OFFSET"), const("GAS_CONSTANT_J_MOL_K")
cpp = re.sub(r"//[^\n]*", "", open(subst_path).read())
optics = re.sub(r"//[^\n]*", "", open(optics_path).read())
table = re.search(r"const GasOptics GAS_OPTICS\[\] = \{(.*?)\n\};", optics, re.S)
if not table:
    cannot("LASubstanceOptics.cpp holds no GAS_OPTICS table, so no gas states its optics")
LIST = r"\{([^{}]*)\}"
ROW = re.compile(r'\{\s*"(\w+)",\s*(true|false),\s*' + r",\s*".join([LIST] * 4)
                 + r",\s*([^,{}]+),\s*([^,{}]+),\s*" + LIST + r"\s*\}")


def numbers(text):
    return [evaluate(x) for x in text.split(",") if x.strip()]


rows = {m.group(1): {"squared": m.group(2) == "true", "b": numbers(m.group(3)), "c": numbers(m.group(4)),
                     "d": numbers(m.group(5)), "poly": numbers(m.group(6)), "ref_t_c": evaluate(m.group(7)),
                     "ref_p_pa": evaluate(m.group(8)), "king": numbers(m.group(9))}
        for m in ROW.finditer(table.group(1))}
molar_name = dict(re.findall(r'\{\s*"(\w+)",\s*F_\w+,\s*\d+,\s*"(\w+)"', cpp))
water = re.search(r'Dictionary water_entry\(\)\s*\{.*?d\["molar_mass"\] = pc\("(\w+)"\)', cpp, re.S)
if water:
    molar_name["h2o"] = water.group(1)


def sigma(row, lam_m):
    """24 pi^3 / (lambda^4 N^2) ((n^2 - 1) / (n^2 + 2))^2 F_K, m^2, for the row's refractivity at its state."""
    s2 = (1.0e-6 / lam_m) ** 2
    y = sum(b / (c - d * s2) for b, c, d in zip(row["b"], row["c"], row["d"]))
    y += sum(p * s2 ** j for j, p in enumerate(row["poly"]))
    n2m1 = y if row["squared"] else y * (2.0 + y)
    king = sum(k * s2 ** j for j, k in enumerate(row["king"]))
    per_m3 = row["ref_p_pa"] / (KB * (row["ref_t_c"] + T0))
    ll = n2m1 / (n2m1 + 3.0)
    return 24.0 * math.pi ** 3 / (lam_m ** 4 * per_m3 ** 2) * ll * ll * king


fails = []
if mode == "rows":
    for gas in ("n2", "co2"):
        if gas not in rows:
            cannot("GAS_OPTICS states no optics for %s" % gas)
    # CO2 measured by broadband cavity-enhanced extinction, 1e-27 cm^2 (He et al. 2021, ACP 21:14927, Table 2).
    for nm, measured in ((404.0, 41.6), (532.0, 13.3), (660.0, 5.52)):
        got = sigma(rows["co2"], nm * 1.0e-9) * 1.0e4 / 1.0e-27
        if abs(got / measured - 1.0) > 0.015:
            fails.append("CO2 scatters %.4g e-27 cm^2 at %g nm where it was measured at %g" % (got, nm, measured))
    # N2 against its other measured refractivity, n - 1 = 6.8552e-5 + 3.243157e-2 / (144 - s^2) at 0 C and
    # 101325 Pa (Peck & Khanna 1966, J. Opt. Soc. Am. 56:1059), under the row's own King factor.
    other = dict(rows["n2"], squared=False, b=[3.243157e-2], c=[144.0], d=[1.0], poly=[6.8552e-5], ref_t_c=0.0,
                 ref_p_pa=101325.0)
    for nm in (532.2, 680.0):
        got, want = sigma(rows["n2"], nm * 1.0e-9), sigma(other, nm * 1.0e-9)
        if abs(got / want - 1.0) > 1.0e-3:
            fails.append("N2's row scatters %.5g m^2 at %g nm, its measured refractivity %.5g" % (got, nm, want))
else:
    air_log, none_log, air_rc, none_rc = sys.argv[6], sys.argv[7], int(sys.argv[8]), int(sys.argv[9])
    nm_m = re.search(r"CHANNEL_WAVELENGTHS_NM: Vector3 = Vector3\(([^)]*)\)", open(sky_path).read())
    if not nm_m:
        cannot("SkyView.gd names no channel wavelengths")
    channels = numbers(nm_m.group(1))
    seeded = {m.lower(): const("PREBIOTIC_MOLE_FRAC_" + m) for m in re.findall(r"^PREBIOTIC_MOLE_FRAC_(\w+)$",
              "\n".join(gd), re.M)}

    def last(path):
        lines = [l[len("SKY_AIR="):] for l in open(path, errors="replace").read().splitlines() if l.startswith("SKY_AIR=")]
        return json.loads(lines[-1]) if lines else None

    air, none = last(air_log), last(none_log)
    if air is None or none is None:
        cannot("a photographed run published no SKY_AIR (air arm exit %d, rung-1 arm exit %d), so the air the "
               "sky was drawn through went unmeasured." % (air_rc, none_rc))
    if not air.get("air"):
        fails.append("the slice holding air drew no sky through it: %s" % json.dumps(air))
    else:
        gas = air["gas_mol_m3"]
        total = sum(gas.values())
        x = {k: v / total for k, v in gas.items()}
        if set(x) != set(seeded) or any(abs(x[k] - seeded[k]) > TOL for k in x):
            fails.append("the sky read an air of %s where the seed laid %s" % (json.dumps(x), json.dumps(seeded)))
        missing = [k for k in x if k not in rows or k not in molar_name]
        if missing:
            cannot("no optics or molar mass is stated for %s" % ", ".join(missing))
        t_k = air["t_c"] + T0
        h_want = R * t_k / (sum(x[k] * const(molar_name[k]) for k in x) * air["g_m_s2"])
        if abs(air["scale_height_m"] / h_want - 1.0) > TOL:
            fails.append("the scale height is %.7g m where R T / (M g) at the cell is %.7g" % (air["scale_height_m"], h_want))
        lift = math.exp(air["height_m"] / h_want)
        if abs(lift - 1.0) < 100.0 * TOL:
            cannot("the air cell stands %g m over the ground, too near it for the column's carry to show" % air["height_m"])
        per_m3 = air["p_pa"] / (KB * t_k)
        for ch, nm in enumerate(channels):
            want = sum(x[k] * sigma(rows[k], nm * 1.0e-9) for k in x) * per_m3 * lift
            got = air["beta_ground_per_m"][ch]
            if abs(got / want - 1.0) > TOL:
                fails.append("at %g nm the sky scatters %.7g /m where sum sigma n exp(h / H) is %.7g" % (nm, got, want))
    if none.get("air") or none.get("beta_ground_per_m"):
        fails.append("the world with gravity and no air drew a Rayleigh sky: %s" % json.dumps(none))
    for rc, arm in ((air_rc, "air"), (none_rc, "rung-1")):
        if rc != 0:
            fails.append("the %s arm exited %d" % (arm, rc))
    print("SKY_AIR_CHECK=%s" % json.dumps({"air": air, "none": none}))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_sky_air: FAIL (%d)" % len(fails))
    sys.exit(1)
PY

# The rows first: a table that misstates a measured cross-section fails before any engine starts.
python3 "$DIR/check.py" rows "$SUBSTANCES" "$OPTICS" "$CONSTANTS" "$SKY" || exit $?

shoot() {  # <rung> <log>
	LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_SKY_AIR_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" \
		--path "$ROOT" "$SCENE" -- --sandbox --ui "--rung=$1" --planet-only "--shoot=$DIR/shot_$1.png" \
		"--shots=2000:-89:0" --local-hour=12 --shoot-frames=90 --shoot-size=320x200 > "$2" 2>&1
	echo $?
}
air_rc="$(shoot 2 "$DIR/air.log")"
none_rc="$(shoot 1 "$DIR/none.log")"
python3 "$DIR/check.py" runs "$SUBSTANCES" "$OPTICS" "$CONSTANTS" "$SKY" "$DIR/air.log" "$DIR/none.log" "$air_rc" \
	"$none_rc" \
	|| exit $?
echo "check_sky_air: OK"
