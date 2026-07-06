extends SceneTree

## SHORT parity check for the GPU-resident FIRE / COMBUSTION pass (kernels3d/fire3d.glsl) added to
## LAMaterialGPU3D. Seeds a small synthetic 3D field with a burning fuel strip + an isolated hot ignition
## source (temp >= 300) + a wet firebreak + a spatial wind, runs K steps through the CPU oracle (step_water
## -> heat -> atmosphere -> combustion, matching the GPU step() order — lava/slump are zero-seeded no-ops) and
## the SAME K through the GPU resident frame API (begin_frame -> step xK -> end_frame), then asserts fire /
## fuel match to ~1e-3 (and temp / water within 1e-2) and prints PASS/FAIL + max diffs. The scenario avoids
## ignition-threshold flips (the only ignitor sits far above 300, spread neighbours carry no fuel) so the
## discrete phase logic is deterministic across float32/float64. GPU needs a RenderingDevice, so run WINDOWED
## with the metal driver (NOT --headless, which has no local RenderingDevice):
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_fire.gd
## (Explicit types only — no ':=' inferred typing.)

const FieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const CombustScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCombustion3D.gd")
const WindScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWind3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")

const DIM: int = 8
const CELL_SIZE: float = 5.0
const SEA_LEVEL: float = 12.0
const STEPS: int = 8
const TOL_FIRE: float = 1.0e-3        # fire + fuel gate (small-magnitude, near-discrete → should match tightly)
const TOL_FIELD: float = 1.0e-2       # temp (rel-discounted) + water gate
const WIND: Vector2 = Vector2(0.8, -0.4)


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
	# Uniform wind so the ember gather's downwind bias is exercised (each neighbour throws +X / -Z biased heat).
	var velx: PackedFloat32Array = PackedFloat32Array(); velx.resize(cc)
	var velz: PackedFloat32Array = PackedFloat32Array(); velz.resize(cc)

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = _idx(ix, iy, iz)
				temp[i] = 20.0
				velx[i] = WIND.x
				velz[i] = WIND.y
				if iy == 0:
					solid[i] = 1                 # rock floor

	# A burning fuel strip on the surface layer (iy=1, iz=4, ix=1..4): already alight + pinned hot, so it
	# consumes fuel deterministically (fuel -= BURN_RATE each step, never reaches 0 over K → stays lit).
	for ix in range(1, 5):
		var si: int = _idx(ix, 1, 4)
		fuel[si] = 0.6
		fire[si] = 1.0
		temp[si] = 640.0
	# An ISOLATED hot ignition source (temp 500 >> 300) on a fuel cell far from the strip → ignites step 0.
	var ig: int = _idx(6, 1, 1)
	fuel[ig] = 0.5
	fire[ig] = 0.0
	temp[ig] = 500.0
	# A COLD fuel cell with no burning neighbours → never ignites (stays fuel-full, fire 0).
	var cold: int = _idx(0, 1, 0)
	fuel[cold] = 0.5
	# A WET fuel cell with a spark → water is an emergent firebreak, extinguished to 0 on step 0.
	var wet: int = _idx(6, 1, 6)
	fuel[wet] = 0.5
	fire[wet] = 0.5
	water[wet] = 1.0

	# --- CPU oracle: a real field seeded with copies, stepped water -> heat -> atmosphere -> combustion. ---
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
	field._vel_x = velx.duplicate()
	field._vel_z = velz.duplicate()

	var heat = HeatScript.new(); heat.setup(field)
	# Wind now runs ON-GPU inside step() (between heat + atmosphere), evolving vel each step — so the CPU
	# oracle must run it too or the seeded vel diverges (GPU ember/transport read evolved vel). Default
	# prevailing = ZERO on both sides (the harness never sets it), so both evolve identically.
	var wind = WindScript.new(); wind.setup(field)
	var atmo = AtmoScript.new(); atmo.setup(field); atmo.set_wind(WIND)
	var combust = CombustScript.new(); combust.setup(field)
	combust._seeded = true                 # keep OUR manual fuel seed (skip terrain grass-band seeding)

	var solar: float = heat._solar()       # sun_light null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()
		heat.step()
		wind.step()                        # PASS A pressure + PASS B velocity (matches GPU order)
		atmo.step()
		combust.step()                     # ember gather + phase core (scene tail is a no-op on a bare field)

	# --- GPU resident path: seed the same start, run the same K steps, read back once. ---
	var gpu = GPUScript.new()
	gpu.setup(field)                                   # field's masks were mutated by the CPU run -> reseed:
	gpu.upload_static_state(solid, stat)               # push the ORIGINAL masks
	gpu.begin_frame(temp, water, solar, WIND)
	gpu.upload_wind(velx, velz)
	gpu.set_field("vapor", vapor)
	gpu.set_field("cloud", cloud)
	gpu.set_field("fog", fog)
	gpu.set_field("lava", lava)
	gpu.set_field("fuel", fuel)
	gpu.set_field("fire", fire)
	for k2 in range(STEPS):
		gpu.step()
	var out: Dictionary = gpu.end_frame()

	# --- Compare ---
	var cpu: Dictionary = {
		"fire": field._fire, "fuel": field._fuel,
		"temp": field._temp, "water": field._water,
	}
	var ok: bool = true
	for name in ["fire", "fuel", "temp", "water"]:
		var a: PackedFloat32Array = cpu[name]
		var b: PackedFloat32Array = out[name]
		var use_rel: bool = (name == "temp")
		var md: float = _max_diff(a, b, use_rel)
		var tol: float = TOL_FIRE if (name == "fire" or name == "fuel") else TOL_FIELD
		var pass_field: bool = md <= tol
		print("  ", name, ": max_diff=", md, "  tol=", tol, "  ", "ok" if pass_field else "OVER_TOL")
		if not pass_field:
			ok = false
	# Diagnostic: how many cells are burning at the end (both paths should agree).
	print("  burning_cells cpu=", _burning(field._fire), " gpu=", _burning(out["fire"]))
	gpu.dispose()
	field.free()
	return ok


func _burning(a: PackedFloat32Array) -> int:
	var n: int = 0
	for i in range(a.size()):
		if a[i] > 0.02:
			n += 1
	return n


# Max diff: abs, but when use_rel the per-cell diff is discounted by 1e-4 * |cpu| so high-magnitude burn
# temps aren't penalized for float32 rounding over K conduction steps (same gate the atmos/lava harness uses).
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
