extends SceneTree

## SHORT parity check for the GPU-resident atmosphere + lava passes added to LAMaterialGPU3D. Runs a fixed
## small synthetic 3D field K steps through the CPU oracle (step_water -> heat -> atmosphere -> lava, the
## exact MaterialField3D._physics_process order) and K steps through the GPU resident frame API
## (begin_frame -> step xK -> end_frame), then asserts temp / water / vapor / cloud / fog match to ~1e-2
## and prints PASS/FAIL + max diffs. GPU needs a RenderingDevice, so run WINDOWED with the metal driver:
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_atmos_lava.gd
## (No timing sweeps, no big benchmark — one small correctness gate, then quit.)

const FieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const LavaScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialLava3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")

const DIM: int = 8
const CELL_SIZE: float = 5.0
const SEA_LEVEL: float = 12.0
const STEPS: int = 8
const TOL: float = 1.0e-2
const WIND: Vector2 = Vector2(0.8, -0.4)


func _initialize() -> void:
	var ok: bool = _run()
	print("PARITY_RESULT=", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _run() -> bool:
	if not GPUScript.available():
		print("GPU_REQUIRED: no local RenderingDevice (run WINDOWED with --rendering-driver metal, not --headless)")
		return false

	var dx: int = DIM
	var dy: int = DIM
	var dz: int = DIM
	var cc: int = dx * dy * dz

	# --- Build the synthetic initial state (kept lava DRY + molten so solidify never fires in either path,
	# whose CPU edit-cap is intentionally not replicated on the GPU). ---
	var solid: PackedByteArray = PackedByteArray(); solid.resize(cc)
	var stat: PackedByteArray = PackedByteArray(); stat.resize(cc)
	var temp: PackedFloat32Array = PackedFloat32Array(); temp.resize(cc)
	var water: PackedFloat32Array = PackedFloat32Array(); water.resize(cc)
	var vapor: PackedFloat32Array = PackedFloat32Array(); vapor.resize(cc)
	var cloud: PackedFloat32Array = PackedFloat32Array(); cloud.resize(cc)
	var fog: PackedFloat32Array = PackedFloat32Array(); fog.resize(cc)
	var lava: PackedFloat32Array = PackedFloat32Array(); lava.resize(cc)
	# A spatially-VARYING wind velocity (both signs across the grid) so the atmosphere transport's local-wind
	# advection is actually exercised — this is the parity check for the emergent-wind moisture advection.
	var velx: PackedFloat32Array = PackedFloat32Array(); velx.resize(cc)
	var velz: PackedFloat32Array = PackedFloat32Array(); velz.resize(cc)

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				temp[i] = 22.0 - 2.5 * float(iy)     # warm low, cool aloft (drives dewpoint condensation)
				velx[i] = 1.2 * (float(ix) - float(dx) * 0.5) / float(dx)   # sign flips across X
				velz[i] = -0.9 * (float(iz) - float(dz) * 0.5) / float(dz)  # sign flips across Z
				if iy == 0:
					solid[i] = 1                     # rock floor
					continue
				var wy: float = float(iy) * CELL_SIZE
				# Calm static sea in the -X half, below sea level (evaporation source + drain sink).
				if ix < 4 and wy < SEA_LEVEL:
					water[i] = 1.0
					stat[i] = 1
				# A couple of dynamic water cells (flow + rain target).
				if ix == 2 and iz == 2 and iy == 3:
					water[i] = 0.7
				# Humid air seeded through the mid column (condenses at the cool cells aloft).
				if iy >= 2 and iy <= 5 and ix >= 2 and ix <= 5:
					vapor[i] = 0.25
				# A thick cloud cell -> precipitates.
				if ix == 3 and iz == 3 and iy == 5:
					cloud[i] = 0.7
				# A single thick, hot, DRY lava cell on the floor in the +X corner (creeps laterally, stays molten).
				if ix == 6 and iz == 6 and iy == 1:
					lava[i] = 1.0
					temp[i] = 1150.0

	# --- CPU oracle: a real field seeded with copies, stepped through the concern modules in order. ---
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
	field._vel_x = velx.duplicate()
	field._vel_z = velz.duplicate()

	var heat = HeatScript.new(); heat.setup(field)
	var atmo = AtmoScript.new(); atmo.setup(field); atmo.set_wind(WIND)
	var lava_sim = LavaScript.new(); lava_sim.setup(field)

	var solar: float = heat._solar()   # sun_light is null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()
		heat.step()
		atmo.step()
		lava_sim.step()

	# --- GPU resident path: seed the same start, run the same K steps, read back once. ---
	var gpu = GPUScript.new()
	gpu.setup(field)                                   # uploads field's (CPU-mutated) solid/static — reseed them:
	gpu.upload_static_state(solid, stat)               # push the ORIGINAL masks (field's were mutated by the CPU run)
	gpu.begin_frame(temp, water, solar, WIND)
	gpu.upload_wind(velx, velz)                        # same LOCAL wind the CPU transport advected by
	gpu.set_field("vapor", vapor)
	gpu.set_field("cloud", cloud)
	gpu.set_field("fog", fog)
	gpu.set_field("lava", lava)
	for k2 in range(STEPS):
		gpu.step()
	var out: Dictionary = gpu.end_frame()

	# --- Compare ---
	var names: Array = ["temp", "water", "vapor", "cloud", "fog", "lava"]
	var cpu: Dictionary = {
		"temp": field._temp, "water": field._water, "vapor": field._vapor,
		"cloud": field._cloud, "fog": field._fog, "lava": field._lava,
	}
	var ok: bool = true
	for name in names:
		var a: PackedFloat32Array = cpu[name]
		var b: PackedFloat32Array = out[name]
		# temp reaches ~1150 in lava cells, where GPU float32 vs GDScript float64 rounding over K steps of
		# conduction exceeds a flat 1e-2; use a mixed abs/rel gate there (abs<=1e-2 OR rel<=1e-4). The
		# small-magnitude fields (water/vapor/cloud/fog) use the flat 1e-2 absolute gate.
		var use_rel: bool = (name == "temp")
		var md: float = _max_diff(a, b, use_rel)
		var pass_field: bool = md <= TOL
		print("  ", name, ": max_diff=", md, "  ", "ok" if pass_field else "OVER_TOL")
		if not pass_field:
			ok = false
	gpu.dispose()
	field.free()
	return ok


# Max normalized diff: abs diff, but when use_rel the per-cell diff is discounted by a small relative
# allowance (1e-4 * |cpu|) so high-magnitude lava temps aren't penalized for float32 rounding.
func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array, use_rel: bool) -> float:
	if a.size() != b.size() or a.size() == 0:
		print("  SIZE MISMATCH: ", a.size(), " vs ", b.size())
		return 1.0e9
	var m: float = 0.0
	for i in range(a.size()):
		var d: float = absf(a[i] - b[i])
		if use_rel:
			d = maxf(0.0, d - 1.0e-4 * absf(a[i]))
		if d > m:
			m = d
	return m
