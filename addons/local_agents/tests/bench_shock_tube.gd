extends SceneTree

## SOD'S SHOCK TUBE through the real face solve. A shut tube of diatomic gas, dense and hot on the left,
## stepped by the acoustic group: the gate compares the profile with the exact Riemann solution. Two
## resolutions and two jump strengths, so the order and the linearisation's own cost are both measured.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"

const TUBE_M: float = 1.0
## Sod (1978) states (1, 1) and (0.125, 0.1); in SI at one bar and one kg per cubic metre.
const RHO_L: float = 1.0
const P_L: float = 1.0e5
const RHO_R: float = 0.125
const P_R: float = 1.0e4
## The weak arm's pressure ratio, with the right density set isentropically from it: an acoustic jump,
## where the linearised face solve is the exact one and only the grid can be wrong.
const WEAK_RATIO: float = 0.99
const STEPS: int = 120
const SEED_PASSES: int = 24


func _t_end() -> float:
	# Sod's t = 0.2 in units where the tube is one long and the left sound speed is sqrt(1.4 p / rho).
	return 0.2 * TUBE_M / sqrt(LAPhysical.AIR_ADIABATIC_INDEX * P_L / RHO_L)


func _arm(n: int, rho_r: float, p_r: float) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("bench_shock_tube: " + rig.error)
		return {}
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd", "pass:FluxPass.gd",
		"transport:n2_eddy", "transport:mom_flux"]))
	var cell: float = TUBE_M / float(n)
	if not rig.build(n, 1, 1, cell):
		printerr("bench_shock_tube: " + rig.error)
		return {}
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var flux: RefCounted = rig.attach(FLUX_PATH)
	if derive == null or flux == null:
		printerr("bench_shock_tube: " + rig.error)
		return {}
	rig.add_active_lists(flux.group_count())

	var dt: float = _t_end() / float(STEPS)
	var ctx: Dictionary = {"cell_size": cell, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "gravity_self": 0.0, "dt_s": dt,
		"sun_dir": Vector3.ZERO, "cell_size_min": cell}
	var n2: PackedFloat32Array = rig.filled(n, 0.0)
	var want_p: PackedFloat32Array = rig.filled(n, 0.0)
	for c in n:
		var left: bool = float(c) + 0.5 < 0.5 * float(n)
		n2[c] = (RHO_L if left else rho_r) / LAPhysical.MOLAR_MASS_N2_KG_MOL
		want_p[c] = P_L if left else p_r
	rig.upload("n2", n2)
	_seed_pressure(rig, derive, ctx, want_p)

	for _s in STEPS:
		flux.pre_step(rig.rd, ctx, rig.cell_count, 1)
		rig.step(ctx)
		flux.wake_all()
	rig.step_only(derive, ctx)
	var out: Dictionary = {"cells": n, "cell_m": cell, "t_s": _t_end(), "dt_s": dt,
		"rho_r": rho_r, "p_r": p_r,
		"rho": _list(rig.read("rho_bulk"), n), "pressure": _list(rig.read("pressure"), n),
		"vel_x": _list(rig.read("vel_x"), n), "temp": _list(rig.read("temp"), n),
		"gamma": _list(rig.read("gas_gamma"), n), "gas_r": _list(rig.read("gas_r"), n)}
	rig.close()
	return out


## The energy that puts each cell at the pressure asked for, by the secant rule on the derive's own
## equation of state. The rig states a pressure; it never states an energy datum.
func _seed_pressure(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		want: PackedFloat32Array) -> void:
	var n: int = want.size()
	var prev: PackedFloat32Array = rig.filled(n, 0.0)
	var e: PackedFloat32Array = rig.filled(n, 1.0e5)
	var p_prev: PackedFloat32Array = _pressure_of(rig, derive, ctx, prev)
	for _i in SEED_PASSES:
		var p: PackedFloat32Array = _pressure_of(rig, derive, ctx, e)
		var nxt: PackedFloat32Array = rig.filled(n, 0.0)
		for c in n:
			var dp: float = p[c] - p_prev[c]
			nxt[c] = e[c] if absf(dp) < 1.0e-9 else e[c] + (want[c] - p[c]) * (e[c] - prev[c]) / dp
		prev = e
		p_prev = p
		e = nxt
	var settled: PackedFloat32Array = _pressure_of(rig, derive, ctx, e)
	settled.resize(n)


func _pressure_of(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		e: PackedFloat32Array) -> PackedFloat32Array:
	rig.upload("e_j_m3", e)
	rig.fill("e_lith_j_m3", 0.0)
	rig.step_only(derive, ctx)
	return rig.read("pressure")


func _list(a: PackedFloat32Array, n: int) -> Array:
	var out: Array = []
	for c in n:
		out.append(float(a[c]))
	return out


func _init() -> void:
	QuietWindow.apply_if_automated()
	# Sod's jump, and the same tube at a jump weak enough that the exact solution IS the linear acoustic
	# one: the pair separates what the linearised face pressure costs from what the grid costs.
	var arms: Dictionary = {
		"sod_coarse": _arm(200, RHO_R, P_R), "sod_fine": _arm(400, RHO_R, P_R),
		"weak_coarse": _arm(200, RHO_L * pow(WEAK_RATIO, 1.0 / LAPhysical.AIR_ADIABATIC_INDEX),
			P_L * WEAK_RATIO),
		"weak_fine": _arm(400, RHO_L * pow(WEAK_RATIO, 1.0 / LAPhysical.AIR_ADIABATIC_INDEX),
			P_L * WEAK_RATIO)}
	for key in arms:
		if (arms[key] as Dictionary).is_empty():
			quit(2)
			return
	print('BENCH_RAW_SHOCK_TUBE=' + JSON.stringify({"tube_m": TUBE_M, "rho_l": RHO_L, "p_l": P_L,
		"arms": arms}))
	quit(0)
