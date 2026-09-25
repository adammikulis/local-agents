extends SceneTree

## THE BAROMETRIC COLUMN. An isothermal column of dry nitrogen under uniform gravity: the derived
## pressure is compared with p0 exp(-z/H), H = RT/(Mg), and again after the acoustic group has stepped
## it. A control column seeded flat must NOT hold, or the arm proves nothing.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"

const N: int = 48
const CELL: float = 200.0
const G: float = 9.80665
const T_C: float = 15.0
const P_BASE: float = 101325.0
const STEPS: int = 40
const DT_S: float = 0.05
const SEED_PASSES: int = 24


## `exponential` seeds the moles the barometric law asks for; otherwise the column is uniform, which is
## the arm that must move.
func _arm(exponential: bool) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("bench_hydrostatic_column: " + rig.error)
		return {}
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd", "pass:FluxPass.gd",
		"transport:n2_eddy", "transport:mom_flux"]))
	if not rig.build(1, N, 1, CELL):
		printerr("bench_hydrostatic_column: " + rig.error)
		return {}
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var flux: RefCounted = rig.attach(FLUX_PATH)
	if derive == null or flux == null:
		printerr("bench_hydrostatic_column: " + rig.error)
		return {}
	rig.add_levels(flux.group_count())

	# Uniform gravity down -y, with the potential that generates it: phi = g z, J/kg.
	var g_vec: PackedFloat32Array = rig.filled(N * 3, 0.0)
	var phi: PackedFloat32Array = rig.filled(N, 0.0)
	var z: PackedFloat32Array = rig.filled(N, 0.0)
	for c in N:
		g_vec[c * 3 + 1] = -G
		z[c] = (float(c) + 0.5) * CELL
		phi[c] = G * z[c]
	rig.upload("gravity", g_vec)
	rig.upload("g_rest", g_vec)
	rig.upload("grav_phi", phi)
	rig.fill("grav_ref", 0.0)

	var scale_h: float = LAPhysical.GAS_CONSTANT_J_MOL_K * (T_C + LAPhysical.KELVIN_OFFSET) \
		/ (LAPhysical.MOLAR_MASS_N2_KG_MOL * G)
	var want_p: PackedFloat32Array = rig.filled(N, 0.0)
	var n2: PackedFloat32Array = rig.filled(N, 0.0)
	var n_base: float = P_BASE / (LAPhysical.GAS_CONSTANT_J_MOL_K * (T_C + LAPhysical.KELVIN_OFFSET))
	for c in N:
		var f: float = exp(-(z[c] - 0.5 * CELL) / scale_h) if exponential else 1.0
		n2[c] = n_base * f
		want_p[c] = P_BASE * f
	rig.upload("n2", n2)

	var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "body_radius": 0.0, "gravity_self": 0.0, "dt_s": DT_S,
		"sun_dir": Vector3.ZERO, "cell_size_min": CELL}
	_seed_pressure(rig, derive, ctx, want_p)
	var p_seeded: Array = _list(rig.read("pressure"))
	for _s in STEPS:
		flux.pre_step(rig.rd, ctx, rig.cell_count, 1)
		rig.step(ctx)
		flux.wake_all()
	rig.step_only(derive, ctx)
	var out: Dictionary = {"cells": N, "cell_m": CELL, "g": G, "t_c": T_C, "p_base": P_BASE,
		"scale_h_m": scale_h, "steps": STEPS, "dt_s": DT_S, "t_s": DT_S * float(STEPS),
		"z": _list(z), "p_seeded": p_seeded, "p_stepped": _list(rig.read("pressure")),
		"vel_y": _list(rig.read("vel_y")), "temp": _list(rig.read("temp")),
		"rho": _list(rig.read("rho_bulk"))}
	rig.close()
	return out


func _seed_pressure(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		want: PackedFloat32Array) -> void:
	var prev: PackedFloat32Array = rig.filled(N, 0.0)
	var e: PackedFloat32Array = rig.filled(N, 1.0e5)
	var p_prev: PackedFloat32Array = _pressure_of(rig, derive, ctx, prev)
	for _i in SEED_PASSES:
		var p: PackedFloat32Array = _pressure_of(rig, derive, ctx, e)
		var nxt: PackedFloat32Array = rig.filled(N, 0.0)
		for c in N:
			var dp: float = p[c] - p_prev[c]
			nxt[c] = e[c] if absf(dp) < 1.0e-9 else e[c] + (want[c] - p[c]) * (e[c] - prev[c]) / dp
		prev = e
		p_prev = p
		e = nxt
	var settled: PackedFloat32Array = _pressure_of(rig, derive, ctx, e)
	settled.resize(N)


func _pressure_of(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		e: PackedFloat32Array) -> PackedFloat32Array:
	rig.upload("e_j_m3", e)
	rig.fill("e_lith_j_m3", 0.0)
	rig.step_only(derive, ctx)
	return rig.read("pressure")


func _list(a: PackedFloat32Array) -> Array:
	var out: Array = []
	for c in N:
		out.append(float(a[c]))
	return out


func _init() -> void:
	QuietWindow.apply_if_automated()
	var balanced: Dictionary = _arm(true)
	var flat: Dictionary = _arm(false)
	if balanced.is_empty() or flat.is_empty():
		quit(2)
		return
	print('BENCH_RAW_HYDROSTATIC_COLUMN=' + JSON.stringify({"balanced": balanced, "flat": flat}))
	quit(0)
