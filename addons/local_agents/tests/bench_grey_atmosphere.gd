extends SceneTree

## RADIATIVE EQUILIBRIUM. A lit rock plate settles where its absorbed sunlight equals what it radiates
## from both faces; a thin absorbing layer over a warm surface settles at the Eddington skin temperature,
## T = T_s / 2^(1/4), which is the grey solution T^4 = (Te^4/2)(1 + 3 tau/2) at tau = 0.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"

## Wide enough that the middle column's lateral neighbours are interior cells at the same state, so the
## lateral exchange cancels and the cell is a plane-parallel layer.
const W: int = 7
const CELL: float = 100.0
const DT_S: float = 1.0
const G: float = 9.80665
## Total solar irradiance at one astronomical unit, W/m^2 (Kopp & Lean 2011).
const SOLAR_W_M2: float = 1361.0
const T_SURF_C: float = 226.85
const BISECT_STEPS: int = 44
const SEED_PASSES: int = 20

var _rig: RefCounted = null
var _derive: RefCounted = null
var _flux: RefCounted = null
var _ctx: Dictionary = {}
var _cc: int = 0
## The temperature the seeding actually reached, which is what the equilibrium is reported at.
var _reached: float = 0.0


func _centre(y: int) -> int:
	return _rig.grid.index(W / 2, y, W / 2)


## Sets every cell of layer `y` to `t_c`, dispatches one radiative step and hands back the centre cell's
## absorbed and emitted energy, J/m^3.
func _net_at(y: int, t_c: float, e_hold: PackedFloat32Array) -> Vector2:
	var want: PackedFloat32Array = _rig.filled(_cc, 0.0)
	for c in _cc:
		want[c] = t_c if _rig.grid.coords(c).y == y else -1.0e30
	var prev: PackedFloat32Array = e_hold.duplicate()
	var e: PackedFloat32Array = e_hold.duplicate()
	for c in _cc:
		if want[c] > -1.0e29:
			e[c] += 1.0e9
	var t_prev: PackedFloat32Array = _temp_of(prev)
	for _i in SEED_PASSES:
		var t: PackedFloat32Array = _temp_of(e)
		for c in _cc:
			if want[c] < -1.0e29:
				continue
			var dtemp: float = t[c] - t_prev[c]
			var nx: float = e[c] if absf(dtemp) < 1.0e-9 \
				else e[c] + (want[c] - t[c]) * (e[c] - prev[c]) / dtemp
			prev[c] = e[c]
			e[c] = nx
		t_prev = t
	_rig.upload("e_j_m3", e)
	_rig.step_only(_derive, _ctx)
	_flux.pre_step(_rig.rd, _ctx, _cc, 1)
	_rig.step_only(_flux, _ctx)
	var g: int = _centre(y)
	_reached = float(_rig.read("temp")[g])
	return Vector2(_rig.read("rad_absorbed")[g], _rig.read("rad_emitted")[g])


func _temp_of(e: PackedFloat32Array) -> PackedFloat32Array:
	_rig.upload("e_j_m3", e)
	_rig.fill("e_lith_j_m3", 0.0)
	_rig.step_only(_derive, _ctx)
	return _rig.read("temp")


## The layer temperature at which absorbed equals emitted, by bisection on the measured net.
func _equilibrium(y: int, lo: float, hi: float, e_hold: PackedFloat32Array) -> Dictionary:
	var last: Vector2 = Vector2.ZERO
	var reached: float = 0.0
	for _i in BISECT_STEPS:
		var mid: float = 0.5 * (lo + hi)
		last = _net_at(y, mid, e_hold)
		reached = _reached
		if last.x - last.y > 0.0:
			lo = mid
		else:
			hi = mid
	return {"t_c": reached, "absorbed": last.x, "emitted": last.y}


func _build(ny: int, sun: Vector3) -> bool:
	_rig = RigScript.new()
	if not _rig.open():
		return false
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd", "pass:FluxPass.gd",
		"transport:heat_radiate"]))
	if not _rig.build(W, ny, W, CELL):
		return false
	_derive = _rig.attach(DERIVE_PATH)
	_flux = _rig.attach(FLUX_PATH)
	if _derive == null or _flux == null:
		return false
	_rig.add_active_lists(_flux.group_count())
	_cc = _rig.cell_count
	var g_vec: PackedFloat32Array = _rig.filled(_cc * 3, 0.0)
	for c in _cc:
		g_vec[c * 3 + 1] = -G
	_rig.upload("gravity", g_vec)
	_rig.upload("g_rest", g_vec)
	_rig.fill("pressure", LAPhysical.STANDARD_PRESSURE_PA)
	_ctx = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO, "spin_rate_rad_s": 0.0,
		"sea_radius": 0.0, "gravity_self": 0.0, "dt_s": DT_S, "sun_dir": sun, "cell_size_min": CELL}
	return true


## A lit rock plate: one layer, sun on the up face, radiating from the two faces that face the box edge.
func _plate() -> Dictionary:
	if not _build(1, Vector3(0.0, SOLAR_W_M2, 0.0)):
		return {}
	_rig.fill("silicate", LASubstances.full_mol_m3("silicate"))
	_rig.fill("e_lith_j_m3", 0.0)
	var eq: Dictionary = _equilibrium(0, -120.0, 220.0, _rig.filled(_cc, 0.0))
	eq["albedo"] = LAPhysical.ALBEDO_BARE_GROUND
	eq["emissivity"] = float(LASubstances.table()["silicate"].get("emissivity", 0.0))
	eq["solar_w_m2"] = SOLAR_W_M2
	_rig.close()
	return eq


## A thin carbon-dioxide layer over a warm rock surface, no sun: the skin temperature.
func _skin() -> Dictionary:
	if not _build(2, Vector3.ZERO):
		return {}
	var sil: PackedFloat32Array = _rig.filled(_cc, 0.0)
	var co2: PackedFloat32Array = _rig.filled(_cc, 0.0)
	for c in _cc:
		if _rig.grid.coords(c).y == 0:
			sil[c] = LASubstances.full_mol_m3("silicate")
		else:
			co2[c] = 1.0
	_rig.upload("silicate", sil)
	_rig.upload("co2", co2)
	_rig.fill("e_lith_j_m3", 0.0)
	# The surface, held: its energy is written once and the layer alone is swept.
	var hold: PackedFloat32Array = _rig.filled(_cc, 0.0)
	var eq_hold: Dictionary = _equilibrium(0, T_SURF_C, T_SURF_C + 1.0e-6, hold)
	hold = _rig.read("e_j_m3")
	var eq: Dictionary = _equilibrium(1, -220.0, T_SURF_C, hold)
	eq["surface_t_c"] = float(_rig.read("temp")[_centre(0)])
	eq["surface_emitted"] = float(_rig.read("rad_emitted")[_centre(0)])
	eq["surface_hold_emitted"] = float(eq_hold["emitted"])
	_rig.close()
	return eq


func _init() -> void:
	QuietWindow.apply_if_automated()
	var plate: Dictionary = _plate()
	var skin: Dictionary = _skin()
	if plate.is_empty() or skin.is_empty():
		quit(2)
		return
	print('BENCH_RAW_GREY_ATMOSPHERE=' + JSON.stringify({"cell_m": CELL, "width": W, "dt_s": DT_S,
		"plate": plate, "skin": skin}))
	quit(0)
