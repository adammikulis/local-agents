extends SceneTree

## CONDENSATE HANGS ONLY IN GAS NO FLOOR HOLDS. One column on its own gravity, bottom up: rock, water, a cell a
## third full of water, cloud water in the air over it, more higher up, and dry air. state_derive.glsl's detect
## phase must class the rock, the water, the band and the dry air 0, the cloud over the band 1, the higher 2.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
## The rung whose world holds the cloud rows.
const RUNG: int = 1
const CELL: float = 10.0
const G: float = 9.80665
const T_C: float = 15.0
const P_PA: float = 1.0e5
## Bottom up: what each cell holds, and the class its condensate must take.
const COLUMN: Array = [["rock", 0], ["water", 0], ["water", 0], ["band", 0], ["cloud", 1], ["cloud", 2],
	["air", 0]]


func _init() -> void:
	QuietWindow.apply_if_automated()
	LAProcessSet.declare(RUNG)
	var rig: RefCounted = RigScript.new()
	if not rig.open() or not rig.build(1, COLUMN.size(), 1, CELL):
		_finish(-1, "the column could not be built: " + String(rig.error), [])
		return
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	if derive == null:
		_finish(-1, "the derive did not attach: " + String(rig.error), [])
		return
	_seed(rig)
	rig.step({"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO, "spin_rate_rad_s": 0.0,
		"body_radius": 0.0, "gravity_self": 0.0, "step_index": 0.0, "dt_s": 1.0, "seeding": false})
	var got: PackedFloat32Array = rig.read("air_class")
	rig.close()
	var wrong: Array = []
	for k in COLUMN.size():
		var c: int = _index(rig, k)
		if got[c] != float(COLUMN[k][1]):
			wrong.append("%s at height %d classed %s, not %d" % [COLUMN[k][0], k, str(got[c]), int(COLUMN[k][1])])
	_finish(wrong.size(), "", wrong)


## The cell at height `k` of the column, read off the grid's own centres.
func _index(rig: RefCounted, k: int) -> int:
	var y: float = rig.grid.origin.y + (float(k) + 0.5) * CELL
	for c in rig.cell_count:
		if absf(rig.grid.centres[c].y - y) < 0.25 * CELL:
			return c
	return -1


func _seed(rig: RefCounted) -> void:
	var cc: int = int(rig.cell_count)
	var full_h2o: float = LASubstances.full_mol_m3("h2o")
	var full_sil: float = LASubstances.full_mol_m3("silicate")
	var molar: PackedFloat32Array = LAMatterChannels.molar_masses()
	var m_sil: float = molar[LAMatterChannels.CHANNELS.find("silicate")]
	var m_n2: float = molar[LAMatterChannels.CHANNELS.find("n2")]
	# Air at the column's pressure and temperature, and cloud water well past what that air holds as vapour.
	var n_air: float = P_PA / (LAPhysical.GAS_CONSTANT_J_MOL_K * (T_C + LAPhysical.KELVIN_OFFSET))
	var n_cloud: float = 10.0 * LAMixtureEnthalpy.vapour_p_at("h2o", T_C, P_PA) \
		/ (LAPhysical.GAS_CONSTANT_J_MOL_K * (T_C + LAPhysical.KELVIN_OFFSET))
	var h2o: PackedFloat32Array = rig.filled(cc, 0.0)
	var sil: PackedFloat32Array = rig.filled(cc, 0.0)
	var n2: PackedFloat32Array = rig.filled(cc, 0.0)
	var cement: PackedFloat32Array = rig.filled(cc, 0.0)
	var e: PackedFloat32Array = rig.filled(cc, 0.0)
	var down: PackedInt32Array = PackedInt32Array()
	var up: PackedInt32Array = PackedInt32Array()
	down.resize(cc)
	up.resize(cc)
	down.fill(-1)
	up.fill(-1)
	for k in COLUMN.size():
		var c: int = _index(rig, k)
		match String(COLUMN[k][0]):
			"rock":
				sil[c] = full_sil
				cement[c] = 1.0
			"water":
				h2o[c] = full_h2o
			"band":
				h2o[c] = full_h2o / 3.0
				n2[c] = n_air * 2.0 / 3.0
			"cloud":
				h2o[c] = n_cloud
				n2[c] = n_air
			"air":
				n2[c] = n_air
		e[c] = h2o[c] * LAPhysical.MOLAR_MASS_WATER_KG_MOL * LASubstances.enthalpy_at("h2o", T_C, P_PA) \
			+ sil[c] * m_sil * LASubstances.enthalpy_at("silicate", T_C, P_PA) \
			+ n2[c] * m_n2 * LASubstances.enthalpy_at("n2", T_C, P_PA)
		if k > 0:
			down[c] = _index(rig, k - 1)
		if k + 1 < COLUMN.size():
			up[c] = _index(rig, k + 1)
	rig.upload("h2o", h2o)
	rig.upload("silicate", sil)
	rig.upload("n2", n2)
	rig.upload("cement", cement)
	rig.upload("solid", cement)
	rig.upload("e_j_m3", e)
	rig.fill("pressure", P_PA)
	var g: PackedFloat32Array = rig.filled(cc * 3, 0.0)
	for c in cc:
		g[c * 3 + 1] = -G
	rig.upload("gravity", g)
	for pair in [["vert_down", down], ["vert_up", up]]:
		var b: PackedByteArray = (pair[1] as PackedInt32Array).to_byte_array()
		rig.rd.buffer_update(rig.bufs[pair[0]], 0, b.size(), b)


func _finish(failures: int, why: String, wrong: Array) -> void:
	if why != "":
		printerr("gate_air_class: " + why)
	for w in wrong:
		printerr("gate_air_class: " + String(w))
	print("AIR_CLASS=" + JSON.stringify({"cells": COLUMN.size(), "failures": failures}))
	quit(2 if failures < 0 else (1 if failures > 0 else 0))
