extends SceneTree

## JEANS ESCAPE against the kinetic-theory flux. One cell whose +x face is space, one gas, no star: the
## gate judges what the escape row books against Phi = n u (1 + lambda) e^-lambda / (2 sqrt(pi)) at nine
## potential depths, so the exponential's whole decade is examined.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const RigScript: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")

const FLUX_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"
const DERIVE_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
const CELL: float = 500.0
const DT: float = 1.0
const T_C: float = 726.85
const N_GAS: float = 40.0
## Escape parameters spanning the thermal regime: below 3 the row is the XUV wind, not Jeans.
const LAMBDAS: Array = [3.5, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0]
const GAS: String = "h2"


func _init() -> void:
	QuietWindow.apply_if_automated()
	var rig: RefCounted = RigScript.new()
	if not rig.open():
		printerr("bench_jeans_escape: " + rig.error)
		quit(2)
		return
	# ONLY the escape rows: no eddy mixing, no momentum, nothing else can move this gas.
	LAProcessSet.declare_records(PackedStringArray(["pass:FluxPass.gd", "transport:escape_" + GAS]))
	var modes: PackedInt32Array = PackedInt32Array([LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SPACE,
		LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT])
	if not rig.build(1, 1, 1, CELL, modes, [null, null, null, null, null, null]):
		printerr("bench_jeans_escape: " + rig.error)
		quit(2)
		return
	# The derive owns the potential, the gas constants and the enthalpy decomposition transport binds.
	rig.declare(DERIVE_PATH)
	var p: RefCounted = rig.attach(FLUX_PATH)
	if p == null:
		printerr("bench_jeans_escape: " + rig.error)
		quit(2)
		return
	rig.add_active_lists(p.group_count())
	if not rig.attach_boundary():
		printerr("bench_jeans_escape: " + rig.error)
		quit(2)
		return

	# Gravity along -x, so the +x face is up and the escape law's cosine there is one.
	var g_vec: PackedFloat32Array = rig.filled(3, 0.0)
	g_vec[0] = -5.0
	rig.upload("gravity", g_vec)
	rig.upload("g_rest", g_vec)
	rig.fill("cap_sensible", 1.0)
	rig.fill("gas_r", LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK)
	rig.fill("gas_gamma", LAPhysical.AIR_ADIABATIC_INDEX)

	var kg_mol: float = float(LASubstances.table()[GAS]["molar_mass"])
	var t_k: float = T_C + LAPhysical.KELVIN_OFFSET
	var per_lambda: float = LAPhysical.GAS_CONSTANT_J_MOL_K * t_k / kg_mol
	var rows: Array = []
	for lam: float in LAMBDAS:
		rig.fill(GAS, N_GAS)
		rig.fill("temp", T_C)
		rig.fill("pressure", 101325.0)
		rig.fill("grav_phi", -lam * per_lambda)
		rig.clear_prefix("bnd_")
		rig.step({"cell_size": CELL, "sun_dir": Vector3.ZERO, "dt_s": DT, "xuv_w_m2": 0.0})
		rows.append({"lambda": lam, "left": -float(rig.read("bnd_" + GAS)[0]),
			"stock": float(rig.read(GAS)[0])})

	print('BENCH_RAW_JEANS_ESCAPE=' + JSON.stringify({"molar_mass_kg_mol": kg_mol, "t_k": t_k,
		"n_mol_m3": N_GAS, "dt_s": DT, "cell_m": CELL, "phi_per_lambda_j_kg": per_lambda,
		"gas_constant": LAPhysical.GAS_CONSTANT_J_MOL_K, "rows": rows}))
	rig.close()
	quit(0)
