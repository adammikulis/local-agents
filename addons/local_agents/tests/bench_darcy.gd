extends SceneTree

## DARCY'S LAW THROUGH POROUS ROCK. Six saturated columns, each at its own porosity and grain size,
## draining under gravity: the gate judges the flux against K = rho g k / mu with the Kozeny-Carman
## permeability k = d^2 phi^3 / (180 (1 - phi)^2), so both dependencies are exercised.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"

const NX: int = 6
const NY: int = 12
const CELL: float = 1.0
const G: float = 9.80665
const DT_S: float = 1.0
const STEPS: int = 1
## Porosity and grain diameter per column, m.
## The temperature the water in these pores stands at: the one closures.glsli's WATER_VISC_REF is
## measured at, so the kernel reads the viscosity this gate's law is quoted with.
const WATER_VISC_T_C: float = 20.0
const POROSITY: Array = [0.10, 0.20, 0.30, 0.40, 0.40, 0.40]
const GRAIN_M: Array = [4.0e-3, 4.0e-3, 4.0e-3, 4.0e-3, 6.0e-5, 2.0e-4]


func _init() -> void:
	QuietWindow.apply_if_automated()
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("bench_darcy: " + rig.error)
		quit(2)
		return
	LAProcessSet.declare_records(PackedStringArray(["pass:StateDerivePass.gd", "pass:FluxPass.gd",
		"transport:h2o_groundwater"]))
	if not rig.build(NX, NY, 1, CELL):
		printerr("bench_darcy: " + rig.error)
		quit(2)
		return
	var derive: RefCounted = rig.attach(DERIVE_PATH)
	var flux: RefCounted = rig.attach(FLUX_PATH)
	if derive == null or flux == null:
		printerr("bench_darcy: " + rig.error)
		quit(2)
		return
	rig.add_levels(flux.group_count())

	var cc: int = rig.cell_count
	var g_vec: PackedFloat32Array = rig.filled(cc * 3, 0.0)
	var phi: PackedFloat32Array = rig.filled(cc, 0.0)
	for c in cc:
		g_vec[c * 3 + 1] = -G
		phi[c] = G * (float(rig.grid.coords(c).y) + 0.5) * CELL
	rig.upload("gravity", g_vec)
	rig.upload("g_rest", g_vec)
	rig.upload("grav_phi", phi)
	rig.fill("grav_ref", 0.0)

	# Brim-full rock: the derive states `solid`, which is what makes the pore law run at all.
	rig.fill("silicate", LASubstances.full_mol_m3("silicate"))
	rig.fill("pressure", LAPhysical.STANDARD_PRESSURE_PA)
	# ROCK AT 20 C, which is the temperature this bench's viscosity is quoted at. The cement below puts
	# every grain in the LATTICE, so the lattice is the reservoir that carries the energy; a fluid
	# reservoir holding a cemented rock's whole mass at zero kelvin is not a state this planet has.
	var t_c: float = WATER_VISC_T_C
	var mm: float = float(LASubstances.table()["silicate"]["molar_mass"])
	var rock_kg: float = LASubstances.full_mol_m3("silicate") * mm
	var p_pa: float = LAPhysical.STANDARD_PRESSURE_PA
	rig.fill("e_j_m3", 0.0)
	rig.fill("e_lith_j_m3", rock_kg * LASubstances.enthalpy_at("silicate", t_c, p_pa))
	var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "body_radius": 0.0, "gravity_self": 0.0, "dt_s": DT_S,
		"sun_dir": Vector3.ZERO, "cell_size_min": CELL}
	rig.step_only(derive, ctx)

	# Cemented rock. The derive raises `solid` only through its lithification record, which is the top
	# rung's and outside this world, so the rig states the rock it is asking about.
	rig.fill("cement", 1.0)
	rig.fill("solid", 1.0)
	# The pore field, written AFTER the derive: it states `grain` from the melt share every step, and the
	# rig is asking what Darcy's law does at a grain size it chose.
	var por: PackedFloat32Array = rig.filled(cc, 0.0)
	var grain: PackedFloat32Array = rig.filled(cc, 0.0)
	var pore: PackedFloat32Array = rig.filled(cc, 0.0)
	var full_h2o: float = LASubstances.full_mol_m3("h2o")
	for c in cc:
		var xy: Vector3i = rig.grid.coords(c)
		por[c] = float(POROSITY[xy.x])
		grain[c] = float(GRAIN_M[xy.x])
		pore[c] = full_h2o * por[c]
	rig.upload("porosity", por)
	rig.upload("grain", grain)
	rig.upload("h2o_pore", pore)
	var before: PackedFloat32Array = rig.read("h2o_pore")
	var solid: PackedFloat32Array = rig.read("solid")

	for _s in STEPS:
		flux.pre_step(rig.rd, ctx, cc, 1)
		rig.step_only(flux, ctx)
		flux.wake_all()
	var after: PackedFloat32Array = rig.read("h2o_pore")
	var claim: PackedInt32Array = rig.rd.buffer_get_data(rig.bufs["act_claim"]).to_int32_array()
	var level: PackedInt32Array = rig.rd.buffer_get_data(rig.bufs["tlevel"]).to_int32_array()

	var cols: Array = []
	for x in NX:
		var col_before: Array = []
		var col_after: Array = []
		for y in NY:
			var c: int = rig.grid.index(x, y, 0)
			col_before.append(float(before[c]))
			col_after.append(float(after[c]))
		cols.append({"porosity": float(POROSITY[x]), "grain_m": float(GRAIN_M[x]),
			"solid": float(solid[rig.grid.index(x, 0, 0)]),
			"pore_before": col_before, "pore_after": col_after,
			"claim": int(claim[rig.grid.index(x, 0, 0)]),
			"tlevel": int(level[rig.grid.index(x, 0, 0)]),
			"g_rest_y": float(rig.read("g_rest")[rig.grid.index(x, 1, 0) * 3 + 1]),
			"porosity_read": float(rig.read("porosity")[rig.grid.index(x, 1, 0)]),
			"grain_read": float(rig.read("grain")[rig.grid.index(x, 1, 0)]),
			"cement_read": float(rig.read("cement")[rig.grid.index(x, 1, 0)]),
			"edge": float(rig.read("cell_edge")[rig.grid.index(x, 1, 0)])})
	print('BENCH_RAW_DARCY=' + JSON.stringify({"cell_m": CELL, "g": G, "dt_s": DT_S,
		"full_h2o_mol_m3": full_h2o, "kozeny_carman_c": LAPhysical.KOZENY_CARMAN_C,
		"water_rho_kg_m3": LAPhysical.WATER_DENSITY_KG_M3, "columns": cols}))
	rig.close()
	quit(0)
