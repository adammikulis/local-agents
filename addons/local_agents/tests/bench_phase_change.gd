extends SceneTree

## THE PHASE LADDER OF EVERY CONDENSED CHANNEL, read off the real derive: a line of cells holding one
## substance at rising internal energy, water against IAPWS and each mineral against its own melting
## point and enthalpy of fusion.

const MELTERS: PackedStringArray = ["metal", "olivine"]

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
## Kelvin of sensible heat either side of a mineral's melting point, so both branches are resolved.
const SPAN_K: float = 300.0

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
		"spin_rate_rad_s": 0.0, "body_radius": 0.0, "gravity_self": 0.0, "dt_s": 1.0})
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
	_rig.fill("h2o", 0.0)
	for channel: String in MELTERS:
		print('BENCH_RAW_MELT_LADDER=' + JSON.stringify(_melt_sweep(channel)))
	print('BENCH_PHASE_CHANGE_DONE=1')
	_rig.close()
	quit(0)


## One mineral's caloric curve: half a cell of it under nitrogen, swept across its own melting point
## with sensible heat to spare either side. No other channel crosses a boundary in that range.
func _melt_sweep(channel: String) -> Dictionary:
	var id: String = String(LAChannels.rows()[channel].get("substance", ""))
	var row: Dictionary = LASubstances.table()[id]
	var mol_m3: float = 0.5 * float(row["density"]) / float(row["molar_mass"])
	var kg_m3: float = mol_m3 * float(row["molar_mass"])
	var melt_c: float = float(row["melt_c"])
	# NITROGEN OVER IT, at about one atmosphere at the melting point: a condensed phase alone in a cell
	# that is not full has no pressure at all, and a mineral in a vacuum sublimes instead of melting.
	# Nitrogen is far above its own critical point here, so it crosses no boundary of its own.
	_rig.fill(channel, mol_m3)
	_rig.fill("n2", LAPhysical.STANDARD_PRESSURE_PA * 0.5
		/ (LAPhysical.GAS_CONSTANT_J_MOL_K * (melt_c + LAPhysical.KELVIN_OFFSET)))
	_rig.fill("pressure", LAPhysical.STANDARD_PRESSURE_PA)
	var p: float = LAPhysical.STANDARD_PRESSURE_PA
	var e_lo: float = kg_m3 * LASubstances.enthalpy_at(id, melt_c - SPAN_K, p)
	var e_hi: float = kg_m3 * LASubstances.enthalpy_at(id, melt_c + SPAN_K, p)
	var e: PackedFloat32Array = PackedFloat32Array()
	e.resize(N)
	for c in N:
		e[c] = e_lo + (e_hi - e_lo) * float(c) / float(N - 1)
	_rig.upload("e_j_m3", e)
	_rig.fill("e_lith_j_m3", 0.0)
	_rig.step({"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "body_radius": 0.0, "gravity_self": 0.0, "dt_s": 1.0})
	var t: PackedFloat32Array = _rig.read("temp")
	var rows: Array = []
	for c in N:
		rows.append([float(e[c]), float(t[c])])
	_rig.fill(channel, 0.0)
	_rig.fill("n2", 0.0)
	return {"substance": id, "kg_per_m3": kg_m3, "cells": N,
		"molar_mass_kg_mol": float(row["molar_mass"]), "columns": ["e_j_m3", "temp_c"], "rows": rows}
