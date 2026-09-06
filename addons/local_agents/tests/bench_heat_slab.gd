extends SceneTree

## THE HEAT EQUATION IN A ROCK SLAB. A line of rock cells with the near end held hot, stepped by the real
## conduction rows: the gate judges the profile against erfc(x / 2 sqrt(alpha t)). Two resolutions over
## the same slab and elapsed time, so the convergence order is measured rather than asserted.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"

const SLAB_M: float = 1.28
const T_COLD_C: float = 20.0
const T_HOT_C: float = 520.0
const DT_S: float = 100.0
const STEPS: int = 62
## Secant passes that put the seeded cells at the temperature asked for. The rig asks for a temperature
## and never says which reservoir carries it, so the response is measured rather than assumed.
const SEED_PASSES: int = 24


func _arm(n: int, dt_s: float, steps: int) -> Dictionary:
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("bench_heat_slab: " + rig.error)
		return {}
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd", "pass:FluxPass.gd",
		"transport:heat_conduct", "transport:heat_conduct_lith"]))
	var cell: float = SLAB_M / float(n)
	if not rig.build(n, 1, 1, cell):
		printerr("bench_heat_slab: " + rig.error)
		return {}
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var flux: RefCounted = rig.attach(FLUX_PATH)
	if derive == null or flux == null:
		printerr("bench_heat_slab: " + rig.error)
		return {}
	rig.add_active_lists(flux.group_count())

	# Solid rock, brim full: the slab is one material and the row crosses it as heat, not as matter.
	rig.fill("silicate", LASubstances.full_mol_m3("silicate"))
	rig.fill("pressure", LAPhysical.STANDARD_PRESSURE_PA)
	var ctx: Dictionary = {"cell_size": cell, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "gravity_self": 0.0, "dt_s": dt_s,
		"sun_dir": Vector3.ZERO, "cell_size_min": cell}
	var want: PackedFloat32Array = rig.filled(n, T_COLD_C)
	want[0] = T_HOT_C
	_seed_temperature(rig, derive, ctx, want)

	var held_e: float = rig.read("e_j_m3")[0]
	var held_lith: float = rig.read("e_lith_j_m3")[0]
	var one: PackedFloat32Array = PackedFloat32Array([0.0])
	for _s in steps:
		flux.pre_step(rig.rd, ctx, rig.cell_count, 1)
		rig.step(ctx)
		# The held end: a reservoir at a fixed temperature, rewritten after every step.
		one[0] = held_e
		rig.rd.buffer_update(rig.bufs["e_j_m3"], 0, 4, one.to_byte_array())
		one[0] = held_lith
		rig.rd.buffer_update(rig.bufs["e_lith_j_m3"], 0, 4, one.to_byte_array())
		flux.wake_all()

	# The state the last held step left, with no further crossing: the derive alone.
	rig.step_only(derive, ctx)
	var out: Dictionary = {"cells": n, "cell_m": cell, "dt_s": dt_s, "steps": steps,
		"t_s": dt_s * float(steps),
		"temp": _list(rig.read("temp"), n), "temp_lith": _list(rig.read("temp_lith"), n),
		"lattice_frac": _list(rig.read("lattice_frac"), n),
		"conductivity": _list(rig.read("conductivity"), n),
		"conductivity_lith": _list(rig.read("conductivity_lith"), n),
		"cap_sensible": _list(rig.read("cap_sensible"), n),
		"cap_lith": _list(rig.read("cap_lith"), n),
		"rho_bulk": _list(rig.read("rho_bulk"), n)}
	rig.close()
	return out


## The seeded temperature, by the secant rule on the derive's own response: the rig asks for a
## temperature and reads back what energy produced it, whichever reservoir the derive put it in.
func _seed_temperature(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		want: PackedFloat32Array) -> void:
	var n: int = want.size()
	var prev: PackedFloat32Array = rig.filled(n, 0.0)
	var e: PackedFloat32Array = rig.filled(n, 1.0e9)
	var t_prev: PackedFloat32Array = _temp_of(rig, derive, ctx, prev)
	for _i in SEED_PASSES:
		var t: PackedFloat32Array = _temp_of(rig, derive, ctx, e)
		var nxt: PackedFloat32Array = rig.filled(n, 0.0)
		for c in n:
			var dtemp: float = t[c] - t_prev[c]
			nxt[c] = e[c] if absf(dtemp) < 1.0e-9 else e[c] + (want[c] - t[c]) * (e[c] - prev[c]) / dtemp
		prev = e
		t_prev = t
		e = nxt
	var settled: PackedFloat32Array = _temp_of(rig, derive, ctx, e)
	settled.resize(n)


func _temp_of(rig: RefCounted, derive: RefCounted, ctx: Dictionary,
		e: PackedFloat32Array) -> PackedFloat32Array:
	rig.upload("e_j_m3", e)
	rig.fill("e_lith_j_m3", 0.0)
	rig.step_only(derive, ctx)
	return rig.read("temp")


func _list(a: PackedFloat32Array, n: int) -> Array:
	var out: Array = []
	for c in n:
		out.append(float(a[c]))
	return out


func _init() -> void:
	QuietWindow.apply_if_automated()
	# Two resolutions at an equal diffusion number for the order, and the fine grid again at the coarse
	# step: a diffusion number past the explicit limit, where only the row's own level control keeps the
	# solution inside the two temperatures it started between.
	var coarse: Dictionary = _arm(64, DT_S, STEPS)
	var fine: Dictionary = _arm(128, 0.25 * DT_S, 4 * STEPS)
	var stress: Dictionary = _arm(128, DT_S, STEPS)
	if coarse.is_empty() or fine.is_empty() or stress.is_empty():
		quit(2)
		return
	print('BENCH_RAW_HEAT_SLAB=' + JSON.stringify({"slab_m": SLAB_M, "t_cold_c": T_COLD_C,
		"t_hot_c": T_HOT_C, "coarse": coarse, "fine": fine, "stress": stress}))
	quit(0)
