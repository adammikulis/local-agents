extends SceneTree

## SHORT parity check for the GPU-resident CHARGE / ELECTRIFICATION accumulate pass (kernels3d/charge_accum3d.
## glsl) added to LAMaterialGPU3D. Seeds a small synthetic 3D field with a warm-bottom / cold-aloft temperature
## profile (→ buoyant vertical wind = the updraft charge feeds on, and cold cells in the supercooled charging
## band) plus a seeded cloud block, runs K steps through the CPU oracle (step_water -> heat -> wind ->
## atmosphere -> charge, matching the GPU step() order — water/lava/slump/dust/fire are zero-seeded no-ops) and
## the SAME K through the GPU resident frame API (begin_frame -> step xK -> end_frame), then asserts the CHARGE
## channel matches to ~1e-3 and prints PASS/FAIL + max diff. The scenario keeps every COLUMN's summed charge
## below BREAKDOWN_Q (2.5) so NO bolt fires — the CPU oracle's discharge is then a no-op, exactly like the
## GPU (which only runs the accumulate core; the breakdown is a CPU tail). GPU needs a RenderingDevice, so run
## WINDOWED with the metal driver (NOT --headless, which has no local RenderingDevice):
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_charge.gd
## (Explicit types only — no ':=' inferred typing.)

const FieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const WindScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWind3D.gd")
const ChargeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCharge3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")

const DIM: int = 8
const CELL_SIZE: float = 5.0
const SEA_LEVEL: float = 12.0
const STEPS: int = 8
const TOL_CHARGE: float = 1.0e-3
const WIND: Vector2 = Vector2(0.0, 0.0)


func _initialize() -> void:
	var ok: bool = _run()
	print("PARITY_RESULT=", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _idx(ix: int, iy: int, iz: int) -> int:
	return (iy * DIM + iz) * DIM + ix


func _run() -> bool:
	if not GPUScript.available():
		print("GPU_REQUIRED: no local RenderingDevice (run WINDOWED with --rendering-driver metal, not --headless)")
		return false

	var dx: int = DIM
	var dy: int = DIM
	var dz: int = DIM
	var cc: int = dx * dy * dz

	var solid: PackedByteArray = PackedByteArray(); solid.resize(cc)
	var stat: PackedByteArray = PackedByteArray(); stat.resize(cc)
	var temp: PackedFloat32Array = PackedFloat32Array(); temp.resize(cc)
	var water: PackedFloat32Array = PackedFloat32Array(); water.resize(cc)
	var vapor: PackedFloat32Array = PackedFloat32Array(); vapor.resize(cc)
	var cloud: PackedFloat32Array = PackedFloat32Array(); cloud.resize(cc)
	var fog: PackedFloat32Array = PackedFloat32Array(); fog.resize(cc)
	var lava: PackedFloat32Array = PackedFloat32Array(); lava.resize(cc)
	var fuel: PackedFloat32Array = PackedFloat32Array(); fuel.resize(cc)
	var fire: PackedFloat32Array = PackedFloat32Array(); fire.resize(cc)
	var sediment: PackedFloat32Array = PackedFloat32Array(); sediment.resize(cc)
	var dust: PackedFloat32Array = PackedFloat32Array(); dust.resize(cc)
	var charge: PackedFloat32Array = PackedFloat32Array(); charge.resize(cc)
	var velx: PackedFloat32Array = PackedFloat32Array(); velx.resize(cc)
	var velz: PackedFloat32Array = PackedFloat32Array(); velz.resize(cc)

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = _idx(ix, iy, iz)
				# Warm at the ground, cold aloft: every cell is warmer than the one above it → buoyant UPDRAFT
				# everywhere (positive vel_y), and the upper cells sit inside the supercooled charging band
				# (temp < FREEZE_T = 12, cold > 0). Gentle gradient so the updraft (and thus the accumulated
				# charge) stays small → no column ever reaches BREAKDOWN_Q, so the discharge tail is a no-op.
				temp[i] = 18.0 - 3.0 * float(iy)
				if iy == 0:
					solid[i] = 1                 # rock floor
	# A modest cloud block aloft (in the cold band, iy 4..6) — the condensed water the updraft electrifies.
	for iy2 in range(4, 7):
		for iz2 in range(2, 6):
			for ix2 in range(2, 6):
				cloud[_idx(ix2, iy2, iz2)] = 0.12

	# --- CPU oracle: a real field seeded with copies, stepped water -> heat -> wind -> atmosphere -> charge. ---
	var field = FieldScript.new()
	field.setup_dims(dx, dy, dz, CELL_SIZE, Vector3(0.0, 0.0, 0.0))
	field.sea_level = SEA_LEVEL
	field._solid = solid.duplicate()
	field._static = stat.duplicate()
	field._temp = temp.duplicate()
	field._water = water.duplicate()
	field._vapor = vapor.duplicate()
	field._cloud = cloud.duplicate()
	field._fog = fog.duplicate()
	field._lava = lava.duplicate()
	field._fuel = fuel.duplicate()
	field._fire = fire.duplicate()
	field._sediment = sediment.duplicate()
	field._dust = dust.duplicate()
	field._charge = charge.duplicate()
	field._vel_x = velx.duplicate()
	field._vel_z = velz.duplicate()

	var heat = HeatScript.new(); heat.setup(field)
	var wind = WindScript.new(); wind.setup(field)
	var atmo = AtmoScript.new(); atmo.setup(field); atmo.set_wind(WIND)
	var charge_sim = ChargeScript.new(); charge_sim.setup(field)

	var solar: float = heat._solar()       # sun_light null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()
		heat.step()
		wind.step()                        # PASS A pressure + PASS B velocity (buoyant updraft) — matches GPU
		atmo.step()
		charge_sim.step()                  # accumulate core (+ discharge, a no-op below BREAKDOWN_Q)

	# --- GPU resident path: seed the same start, run the same K steps, read back once. ---
	var gpu = GPUScript.new()
	gpu.setup(field)
	gpu.upload_static_state(solid, stat)   # push the ORIGINAL masks
	gpu.begin_frame(temp, water, solar, WIND)
	gpu.upload_wind(velx, velz)            # seed the same (zero) initial horizontal velocity
	gpu.set_field("vapor", vapor)
	gpu.set_field("cloud", cloud)
	gpu.set_field("fog", fog)
	gpu.set_field("lava", lava)
	gpu.set_field("sediment", sediment)
	gpu.set_field("dust", dust)
	gpu.set_field("fuel", fuel)
	gpu.set_field("fire", fire)
	gpu.set_field("charge", charge)
	for k2 in range(STEPS):
		gpu.step()
	var out: Dictionary = gpu.end_frame()

	# --- Compare ---
	var a: PackedFloat32Array = field._charge
	var b: PackedFloat32Array = out["charge"]
	var md: float = _max_diff(a, b)
	var ok: bool = md <= TOL_CHARGE
	print("  charge: max_diff=", md, "  tol=", TOL_CHARGE, "  ", "ok" if ok else "OVER_TOL")
	# Diagnostic: peak charge + bolts (must be 0 — the scenario stays below BREAKDOWN_Q on both paths).
	print("  charge_peak cpu=", charge_sim.charge_peak(), " gpu_peak=", _peak(out["charge"]), " bolts=", charge_sim.bolts_fired())
	if charge_sim.bolts_fired() != 0:
		print("  WARNING: a bolt fired — the discharge tail is no longer a no-op; the accumulate parity is invalid")
		ok = false
	gpu.dispose()
	field.free()
	return ok


func _peak(a: PackedFloat32Array) -> float:
	var m: float = 0.0
	for i in range(a.size()):
		if a[i] > m:
			m = a[i]
	return m


func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size() or a.size() == 0:
		print("  SIZE MISMATCH: ", a.size(), " vs ", b.size())
		return 1.0e9
	var m: float = 0.0
	for i in range(a.size()):
		var d: float = absf(a[i] - b[i])
		if d > m:
			m = d
	return m
