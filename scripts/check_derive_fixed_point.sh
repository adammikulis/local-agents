#!/usr/bin/env bash
# ONE STATE PER CELL. The derive solves the temperature at a pressure and states a pressure from that
# temperature; run it twice on the state it just wrote and it must return the same pair. A derive that
# moves is a world whose seed is undone by its own first step.
# EXIT 0 the derive is a fixed point * 1 it moves * 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
[ -f "$PASS" ] || { echo "ERROR: StateDerivePass.gd missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/run_sim_offscreen.sh" ] || { echo "ERROR: run_sim_offscreen.sh missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_derive_fixed_point.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

## A BOX OF REAL MIXTURES: every matter channel holding something, a cemented lattice beside the fluid,
## locked cells beside open ones, momentum, spin and a sea shell — the states a planet actually has.
## The derive runs twice over it; the second pass reads the state the first wrote.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"

const N: int = 4
const CELL: float = 1000.0
## Relative move a second pass may make: float32 on the pressure, and the ladder's own last bit on T.
const TOL_REL: float = 1.0e-5
const TOL_K: float = 1.0e-3
## Fixed, so the gate reproduces. A wider sweep is a soak with its own seed.
const SEED: int = 20260904
## The rig's own body: Earth's sidereal rotation (IAU 2009, rad/s) and standard gravity (CGPM 1901,
## m/s^2), so the frame terms and the weight the solve stands under are a real body's.
const SPIN_RAD_S: float = 7.292115e-5
const G_M_S2: float = 9.80665

var _fails: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rng.seed = SEED
	_run()
	quit(1 if _fails > 0 else 0)


## Uniform across decades: a planet holds amounts and pressures that span them.
func _decades(lo: float, hi: float) -> float:
	return lo * pow(hi / lo, _rng.randf())


func _run() -> void:
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("check_derive_fixed_point: " + rig.error)
		_fails += 1
		return
	# ONLY THE SOLVE: lithification is a per-step process that moves cement, so a world holding it is a
	# world whose second pass is a second step rather than a restatement.
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd"]))
	if not rig.build(N, N, N, CELL):
		printerr("check_derive_fixed_point: " + rig.error)
		_fails += 1
		return
	var cc: int = rig.cell_count
	var derive: RefCounted = rig.attach(PASS_PATH)
	if derive == null:
		printerr("check_derive_fixed_point: " + rig.error)
		_fails += 1
		return

	_seed_world(rig, cc)
	var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO,
		"spin": Vector3(0.0, 1.0, 0.0), "spin_rate_rad_s": SPIN_RAD_S,
		"sea_radius": 1.5 * CELL, "gravity_self": 1.0, "step_index": 0.0, "dt_s": 1.0}
	rig.step_only(derive, ctx)
	var t1: PackedFloat32Array = rig.read("temp")
	var p1: PackedFloat32Array = rig.read("pressure")
	var tl1: PackedFloat32Array = rig.read("temp_lith")
	var pf1: PackedFloat32Array = rig.read("p_fluid")
	var unconv: PackedFloat32Array = rig.read("unconverged")
	var nonfinite: PackedFloat32Array = rig.read("nonfinite")
	rig.step_only(derive, ctx)
	var t2: PackedFloat32Array = rig.read("temp")
	var p2: PackedFloat32Array = rig.read("pressure")
	var tl2: PackedFloat32Array = rig.read("temp_lith")
	var pf2: PackedFloat32Array = rig.read("p_fluid")
	# A DIFFERENT STARTING ITERATE OVER THE SAME MATTER: the cell's state is its matter and its energy,
	# so a solve handed another temperature and another pressure to start from must land in one place.
	_scramble(rig, cc)
	rig.step_only(derive, ctx)
	var t3: PackedFloat32Array = rig.read("temp")
	var p3: PackedFloat32Array = rig.read("pressure")
	var tl3: PackedFloat32Array = rig.read("temp_lith")
	var pf3: PackedFloat32Array = rig.read("p_fluid")
	rig.close()

	var worst_t: float = 0.0
	var worst_p: float = 0.0
	var moved: int = 0
	var live: int = 0
	var unsettled: int = 0
	for c in cc:
		if nonfinite[c] != 0.0:
			_fails += 1
			continue
		# A cell whose solve did not converge has no state to return to.
		if unconv[c] != 0.0:
			unsettled += 1
			continue
		if not (p1[c] > 0.0):
			continue
		live += 1
		var dt: float = maxf(absf(t2[c] - t1[c]), absf(tl2[c] - tl1[c]))
		dt = maxf(dt, maxf(absf(t3[c] - t2[c]), absf(tl3[c] - tl2[c])))
		var dp: float = maxf(absf(p2[c] - p1[c]), absf(pf2[c] - pf1[c]))
		dp = maxf(dp, maxf(absf(p3[c] - p2[c]), absf(pf3[c] - pf2[c]))) / maxf(absf(p1[c]), 1.0)
		worst_t = maxf(worst_t, dt)
		worst_p = maxf(worst_p, dp)
		if dt > TOL_K or dp > TOL_REL:
			moved += 1
	if live <= 0:
		printerr("no cell held a pressure, so the derive was never asked anything.")
		_fails += 1
	if moved > 0:
		_fails += 1
	print('DERIVE_FIXED_POINT={"cells":%d,"live":%d,"unconverged":%d,"moved":%d,"worst_k":%s,"worst_p_rel":%s,"failures":%d}'
		% [cc, live, unsettled, moved, String.num(worst_t, 9), String.num(worst_p, 9), _fails])
	if moved > 0:
		printerr("The derive did not return the state it wrote: %d cell(s) moved. It solves T at a "
			% moved + "pressure and states a pressure from that T, so the two must be solved together, "
			+ "and neither may be read back off the state the last pass wrote.")


## Matter, energy and motion in every cell: amounts scaled so the volume fractions sum under one, a
## cemented share of the lithic channels, and the energy the mixture actually holds at a drawn
## temperature — never an energy picked apart from the matter that carries it.
func _seed_world(rig: RefCounted, cc: int) -> void:
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	var molar: PackedFloat32Array = LAMatterChannels.molar_masses()
	var full: PackedFloat32Array = LAMatterChannels.full_amounts()
	var rows: Dictionary = LAChannels.rows()
	var vol: float = CELL * CELL * CELL
	var subs: PackedStringArray = PackedStringArray()
	var lattice: PackedInt32Array = PackedInt32Array()
	for name: String in channels:
		var row: Dictionary = rows[name]
		subs.append(String(row.get("substance", "")))
		lattice.append(1 if bool(row.get("lithic", false)) or bool(row.get("lattice", false)) else 0)

	var amount: Array = []
	for i in channels.size():
		amount.append(rig.filled(cc, 0.0))
	var pres: PackedFloat32Array = rig.filled(cc, 0.0)
	var cem: PackedFloat32Array = rig.filled(cc, 0.0)
	var sol: PackedFloat32Array = rig.filled(cc, 0.0)
	var e_fluid: PackedFloat32Array = rig.filled(cc, 0.0)
	var e_lat: PackedFloat32Array = rig.filled(cc, 0.0)
	var grain: PackedFloat32Array = rig.filled(cc, 0.0)
	var mom: Array = [rig.filled(cc, 0.0), rig.filled(cc, 0.0), rig.filled(cc, 0.0)]
	for c in cc:
		var frac: float = 0.0
		for i in channels.size():
			var a: float = _decades(1.0e-3, 1.0e2)
			amount[i][c] = a
			frac += a / full[i]
		var fill: float = _rng.randf_range(0.05, 0.95)
		for i in channels.size():
			amount[i][c] = amount[i][c] * fill / frac
		pres[c] = _decades(1.0e3, 1.0e9)
		cem[c] = _rng.randf_range(0.0, 0.9)
		sol[c] = 1.0 if _rng.randf() < 0.3 else 0.0
		grain[c] = _decades(1.0e-5, 1.0e-2)
		var t_c: float = _rng.randf_range(-60.0, 1600.0)
		var h_f: float = 0.0
		var h_l: float = 0.0
		for i in channels.size():
			var kg: float = amount[i][c] * molar[i] * vol
			var sl: float = cem[c] if lattice[i] == 1 else 0.0
			var h: float = kg * LASubstances.enthalpy_at(subs[i], t_c, pres[c])
			h_f += h * (1.0 - sl)
			h_l += h * sl
		# H = U + p V over the room the fluid stands in, so the state handed in is the internal energy.
		e_fluid[c] = h_f / vol - pres[c]
		e_lat[c] = h_l / vol
		for k in 3:
			mom[k][c] = _rng.randf_range(-8.0, 8.0)
	for i in channels.size():
		rig.upload(channels[i], amount[i])
	rig.upload("pressure", pres)
	rig.upload("p_fluid", pres)
	rig.upload("cement", cem)
	rig.upload("solid", sol)
	rig.upload("grain", grain)
	rig.upload("e_j_m3", e_fluid)
	rig.upload("e_lith_j_m3", e_lat)
	rig.upload("mom_x", mom[0])
	rig.upload("mom_y", mom[1])
	rig.upload("mom_z", mom[2])
	# A body that pulls: the derive reads the field, never a direction it assumed.
	var grav: PackedFloat32Array = rig.filled(cc * 3, 0.0)
	for c in cc:
		grav[c * 3 + 1] = -G_M_S2
	rig.upload("gravity", grav)


## Another temperature and another pressure to start the same solve from. A LOCKED cell's pressure is
## not the derive's to state — the column kernel writes it and the seal holds its fluid at it — so only
## an open cell's is replaced.
func _scramble(rig: RefCounted, cc: int) -> void:
	var sol: PackedFloat32Array = rig.read("solid")
	var temp: PackedFloat32Array = rig.read("temp")
	var pres: PackedFloat32Array = rig.read("pressure")
	var pf: PackedFloat32Array = rig.read("p_fluid")
	var tl: PackedFloat32Array = rig.read("temp_lith")
	for c in cc:
		temp[c] = _rng.randf_range(-100.0, 3000.0)
		tl[c] = _rng.randf_range(-100.0, 3000.0)
		if sol[c] == 0.0:
			pres[c] = _decades(1.0e2, 1.0e10)
			pf[c] = pres[c]
	rig.upload("temp", temp)
	rig.upload("temp_lith", tl)
	rig.upload("pressure", pres)
	rig.upload("p_fluid", pf)
GD

OUT="$(LA_DONE_RE='^DERIVE_FIXED_POINT=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
	--path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_derive_fixed_point.gd" 2>&1)"
RC=$?
printf '%s\n' "$OUT" | grep -E '^DERIVE_FIXED_POINT=|did not return|no cell held|no RenderingDevice' || true
# A rig that printed no reading examined nothing, whatever it exited with.
printf '%s\n' "$OUT" | grep -q '^DERIVE_FIXED_POINT=' || {
	echo "check_derive_fixed_point: the rig published no reading, so the derive was never run." >&2
	printf '%s\n' "$OUT" | tail -20 >&2
	exit 2
}
# A world whose cells all failed to settle asserts nothing about the state the derive returns.
LIVE="$(printf '%s\n' "$OUT" | sed -n 's/.*"live":\([0-9]*\).*/\1/p' | head -1)"
CELLS="$(printf '%s\n' "$OUT" | sed -n 's/.*DERIVE_FIXED_POINT={"cells":\([0-9]*\).*/\1/p' | head -1)"
if [ -z "$LIVE" ] || [ -z "$CELLS" ] || [ "$LIVE" -lt $(( CELLS / 2 )) ]; then
	echo "check_derive_fixed_point: only $LIVE of $CELLS cells solved, so the probe asked the derive" >&2
	echo "                          about too little of the world to mean anything." >&2
	exit 1
fi
case "$RC" in
	0) ;;
	1) exit 1 ;;
	*) printf '%s\n' "$OUT" | tail -20 >&2; exit 2 ;;
esac

# THE SEEDED WORLD, not a rig's own inputs: the same derive over the matter the seed actually laid must
# write finite state in every cell. Rung 1 is the lowest that publishes the count.
world="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --rung 1 --frames 4 \
	--report nonfinite_cells 2>&1)"
nf="$(printf '%s\n' "$world" | sed -n "s/^nonfinite_cells  *= *//p" | head -1 \
	| sed -e "s/.*'cur': *//" -e 's/[,}].*//')"
printf 'DERIVE_SEEDED_WORLD={"nonfinite_cells":%s}\n' "${nf:-null}"
case "${nf:-}" in
	"" | *ABSENT*) echo "check_derive_fixed_point: the seeded world published no nonfinite_cells, so the" >&2
		echo "                          derive was never read over the matter the seed laid." >&2
		printf '%s\n' "$world" | tail -15 >&2
		exit 2 ;;
esac
if ! awk -v n="$nf" 'BEGIN{exit !(n == 0)}'; then
	echo "check_derive_fixed_point: the derive wrote non-finite state over the seeded world." >&2
	exit 1
fi
echo "check_derive_fixed_point: OK"
exit 0
