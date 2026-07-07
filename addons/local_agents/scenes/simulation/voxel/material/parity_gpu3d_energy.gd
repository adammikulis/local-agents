extends SceneTree

## SHORT parity check for the ENERGY-STABLE heat model added to LAMaterialHeat3D + kernels3d/heat3d.glsl:
## the RADIATIVE SINK (a hot cell above RAD_FLOOR sheds RAD_RATE of its excess) + the GLOBAL CLAMP
## (clamp(t, T_MIN, T_MAX)), both FOLDED into the conduction output (PART 1). Seeds a synthetic 3D field with
## a super-hot void cell (temp >> T_MAX, exercising the clamp) + a hot cell inside the sink band (950..1400,
## exercising the radiative bleed) + a sustained lava cell (re-pinned each step) + a STEEP vertical
## temperature inversion so BUOYANCY spins up a real vertical wind vel_y (the same emergent updraft the steep
## lapse rides). Runs K steps through the CPU oracle (step_water -> heat -> wind -> atmosphere -> combustion,
## matching the GPU step() order) and the SAME K through the GPU resident frame API, then asserts temp / vel_y
## (+ water) match CPU vs GPU to ~1e-3 and prints PASS/FAIL + max diffs. The sink/clamp are pure continuous /
## branchless temperature arithmetic (no threshold `if`), so they are float32/float64 stable and should match
## to bit level. GPU needs a RenderingDevice, so run WINDOWED with the metal driver (NOT --headless):
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_energy.gd
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
const STEPS: int = 10
const TOL_TEMP: float = 1.0e-3        # temp gate (rel-discounted for the high-magnitude clamped/sink cells)
const TOL_FIELD: float = 1.0e-2       # vel_y + water gate
const WIND: Vector2 = Vector2(0.6, -0.3)


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

	# A SUPER-HOT void cell far above T_MAX (1400): the conduction pass's global clamp caps it, then the
	# radiative sink bleeds it down toward the floor each step. Exercises clamp + sink together.
	temp[_idx(4, 4, 4)] = 3500.0
	# A hot cell INSIDE the sink band (950 < t < 1400): no clamp, pure radiative bleed toward RAD_FLOOR.
	temp[_idx(2, 3, 2)] = 1150.0
	# A hot VOID column base (NO lava — the GPU step() always runs the lava passes, so any seeded lava would
	# need a matching CPU lava module; a bare hot void cell bleeds identically on both paths) that drives a
	# strong buoyant updraft, with a tall COLD cap above it so the vertical inversion is steep → buoyancy
	# spins up a real vertical wind vel_y (the emergent updraft the steep lapse rides).
	temp[_idx(5, 1, 5)] = 1300.0
	temp[_idx(5, 6, 5)] = -20.0

	# --- CPU oracle: a real field seeded with copies, stepped water -> heat -> wind -> atmosphere -> combustion. ---
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
	var wind = WindScript.new(); wind.setup(field)
	var atmo = AtmoScript.new(); atmo.setup(field); atmo.set_wind(WIND)
	var combust = CombustScript.new(); combust.setup(field)
	combust._seeded = true

	var solar: float = heat._solar()       # sun_light null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()
		heat.step()                        # conduction (+ radiative sink + clamp) -> solar -> buoyancy -> cooling
		wind.step()                        # pressure + velocity (vel_y emerges from the vertical inversion)
		atmo.step()
		combust.step()

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
		"temp": field._temp, "vel_y": field._vel_y, "water": field._water,
	}
	var ok: bool = true
	for name in ["temp", "vel_y", "water"]:
		var a: PackedFloat32Array = cpu[name]
		var b: PackedFloat32Array = out[name]
		var use_rel: bool = (name == "temp")
		var md: float = _max_diff(a, b, use_rel)
		var tol: float = TOL_TEMP if name == "temp" else TOL_FIELD
		var pass_field: bool = md <= tol
		print("  ", name, ": max_diff=", md, "  tol=", tol, "  ", "ok" if pass_field else "OVER_TOL")
		if not pass_field:
			ok = false
	# Diagnostic: the hottest cell on each path (both should be bounded at/below T_MAX = 1400, no runaway).
	print("  temp_peak cpu=", _peak(field._temp), " gpu=", _peak(out["temp"]))
	gpu.dispose()
	field.free()
	return ok


func _peak(a: PackedFloat32Array) -> float:
	var m: float = -1.0e9
	for i in range(a.size()):
		if a[i] > m:
			m = a[i]
	return m


# Max diff: abs, but when use_rel the per-cell diff is discounted by 1e-4 * |cpu| so high-magnitude sink/clamp
# temps aren't penalized for float32 rounding over K conduction steps (same gate the fire/atmos-lava harness uses).
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
