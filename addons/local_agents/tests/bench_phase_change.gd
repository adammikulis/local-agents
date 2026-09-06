extends SceneTree

## THE WATER PHASE LADDER, read off the real derive. A line of cells holding the same water at rising
## internal energy: the gate judges the caloric curve's melting plateau, liquid slope and two-phase
## locus against the IAPWS values. Three refining sweeps find the window, so no energy datum is assumed.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const CELL: float = 1.0
const N: int = 2048
## Water per cubic metre. Dilute enough that the triple point is reached with liquid to spare, dense
## enough that the saturated vapour does not consume it all before the normal boiling point.
const KG_PER_M3: float = 1.0
const T_LO_C: float = -30.0
const T_HI_C: float = 108.0

var _rig: RefCounted = null
var _pass: RefCounted = null


func _sweep(e_lo: float, e_hi: float) -> Dictionary:
	var e: PackedFloat32Array = PackedFloat32Array()
	e.resize(N)
	for c in N:
		e[c] = e_lo + (e_hi - e_lo) * float(c) / float(N - 1)
	_rig.upload("e_j_m3", e)
	_rig.fill("e_lith_j_m3", 0.0)
	_rig.step({"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "crust_radius": 0.0, "gravity_self": 0.0, "dt_s": 1.0})
	return {"e": e, "temp": _rig.read("temp"), "pressure": _rig.read("pressure"),
		"solid": _rig.read("h2o_solid"), "liquid": _rig.read("h2o_liquid"),
		"vapour": _rig.read("h2o_vapour")}


## The energy at which the swept temperature first reaches `t_c`, by linear interpolation; the window
## edge when the sweep never gets there.
func _energy_at(s: Dictionary, t_c: float) -> float:
	var e: PackedFloat32Array = s["e"]
	var t: PackedFloat32Array = s["temp"]
	for c in range(1, N):
		if t[c] >= t_c and t[c - 1] < t_c:
			var f: float = (t_c - t[c - 1]) / maxf(t[c] - t[c - 1], 1.0e-12)
			return e[c - 1] + f * (e[c] - e[c - 1])
	return e[0] if t[0] > t_c else e[N - 1]


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rig = RigScript.new()
	if not _rig.open():
		printerr("bench_phase_change: " + _rig.error)
		quit(2)
		return
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd"]))
	if not _rig.build(N, 1, 1, CELL):
		printerr("bench_phase_change: " + _rig.error)
		quit(2)
		return
	_pass = _rig.attach(DERIVE_PATH)
	if _pass == null:
		printerr("bench_phase_change: " + _rig.error)
		quit(2)
		return

	var n_h2o: float = KG_PER_M3 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
	_rig.fill("h2o", n_h2o)
	_rig.fill("pressure", LAPhysical.WATER_TRIPLE_P_PA)

	# Three refining sweeps: the first brackets on the substance table's own caloric estimate, and each
	# one after narrows the window to the temperatures asked for. Only the window is taken from the
	# table; every number the gate judges comes off the swept curve.
	var e_lo: float = KG_PER_M3 * LASubstances.enthalpy_at("h2o", T_LO_C, LAPhysical.WATER_TRIPLE_P_PA) - 2.0e6
	var e_hi: float = KG_PER_M3 * LASubstances.enthalpy_at("h2o", T_HI_C, LAPhysical.STANDARD_PRESSURE_PA) + 2.0e6
	var s: Dictionary = {}
	for _i in 3:
		s = _sweep(e_lo, e_hi)
		var lo: float = _energy_at(s, T_LO_C)
		var hi: float = _energy_at(s, T_HI_C)
		if hi <= lo:
			break
		var pad: float = 0.02 * (hi - lo)
		e_lo = lo - pad
		e_hi = hi + pad

	var rows: Array = []
	var e_out: PackedFloat32Array = s["e"]
	for c in N:
		rows.append([float(e_out[c]), float(s["temp"][c]), float(s["pressure"][c]),
			float(s["solid"][c]), float(s["liquid"][c]), float(s["vapour"][c])])
	print('BENCH_RAW_PHASE_CHANGE=' + JSON.stringify({"kg_per_m3": KG_PER_M3, "cells": N,
		"molar_mass_kg_mol": LAPhysical.MOLAR_MASS_WATER_KG_MOL,
		"columns": ["e_j_m3", "temp_c", "pressure_pa", "solid", "liquid", "vapour"], "rows": rows}))
	_rig.close()
	quit(0)
