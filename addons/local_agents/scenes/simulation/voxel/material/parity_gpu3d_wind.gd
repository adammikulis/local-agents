extends SceneTree

## SHORT parity check for the GPU-resident WIND passes (kernels3d/wind_pressure3d.glsl PASS A +
## wind_step3d.glsl PASS B) added to LAMaterialGPU3D. Seeds a small synthetic 3D field with a 3-axis
## temperature gradient (→ pressure gradients → horizontal + buoyant vertical wind), a prevailing base wind,
## a nonzero initial velocity, and interior SOLID walls (exercising gradient reflection + terrain
## deflection), then runs K steps through the CPU oracle (step_water -> heat -> WIND, matching the GPU
## step() order — water/atmosphere/lava/slump/fire are zero-seeded no-ops so temp evolves ONLY via heat and
## vel ONLY via wind) and the SAME K through the GPU resident frame API (begin_frame -> step xK -> end_frame).
## Asserts vel_x / vel_y / vel_z and pressure match to ~1e-3 and prints PASS/FAIL + max diffs. GPU needs a
## RenderingDevice, so run WINDOWED with the metal driver (NOT --headless, which has no local RenderingDevice):
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_wind.gd
## (Explicit types only — no ':=' inferred typing.)

const FieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const WindScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWind3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")

const DIM: int = 8
const CELL_SIZE: float = 5.0
const SEA_LEVEL: float = 12.0
const STEPS: int = 8
const TOL_VEL: float = 1.0e-3         # velocity gate (small magnitude — should match tightly)
const TOL_PRESSURE: float = 1.0e-3    # pressure gate (~100 magnitude; float32 rounding stays well under this)
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
	# A nonzero, spatially-varying initial velocity so the drag/clamp on existing momentum is exercised.
	var velx: PackedFloat32Array = PackedFloat32Array(); velx.resize(cc)
	var vely: PackedFloat32Array = PackedFloat32Array(); vely.resize(cc)
	var velz: PackedFloat32Array = PackedFloat32Array(); velz.resize(cc)

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = _idx(ix, iy, iz)
				# 3-axis temperature field: warm low + hot in the +X/-Z corner → real horizontal AND
				# vertical pressure gradients everywhere (drives gradient wind + buoyant lift).
				temp[i] = 30.0 - 2.2 * float(iy) + 1.8 * float(ix) - 1.3 * float(iz)
				velx[i] = 0.6 * (float(ix) - float(dx) * 0.5) / float(dx)
				velz[i] = -0.5 * (float(iz) - float(dz) * 0.5) / float(dz)
				if iy == 0:
					solid[i] = 1                 # rock floor
	# Interior SOLID walls: a partial vertical slab at ix==4 (iy 1..4, iz 2..5) so the pressure gradient
	# REFLECTS off it and horizontal wind gets deflected (mass funnels around) — the emergent-terrain path.
	for iy2 in range(1, 5):
		for iz2 in range(2, 6):
			solid[_idx(4, iy2, iz2)] = 1
	# A lone pillar so a cell is walled on multiple sides (all-axis deflection).
	solid[_idx(2, 1, 2)] = 1
	solid[_idx(2, 2, 2)] = 1

	# --- CPU oracle: a real field seeded with copies, stepped water -> heat -> WIND. ---
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
	field._vel_y = vely.duplicate()
	field._vel_z = velz.duplicate()

	var heat = HeatScript.new(); heat.setup(field)
	var wind = WindScript.new(); wind.setup(field); wind.set_prevailing(WIND)

	var solar: float = heat._solar()       # sun_light null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()                 # no-op (water zero) — kept for step-order fidelity
		heat.step()
		wind.step()                        # PASS A pressure (from post-heat temp) + PASS B velocity

	# --- GPU resident path: seed the same start, run the same K steps, read back once. ---
	var gpu = GPUScript.new()
	gpu.setup(field)                                   # field's masks were mutated only trivially; reseed anyway:
	gpu.upload_static_state(solid, stat)               # push the ORIGINAL masks
	gpu.set_prevailing(WIND)
	gpu.begin_frame(temp, water, solar, WIND)
	gpu.upload_wind(velx, velz)                        # seed the same nonzero initial horizontal velocity
	gpu.set_field("vapor", vapor)
	gpu.set_field("cloud", cloud)
	gpu.set_field("fog", fog)
	gpu.set_field("lava", lava)
	gpu.set_field("fuel", fuel)
	gpu.set_field("fire", fire)
	for k2 in range(STEPS):
		gpu.step()
	var out: Dictionary = gpu.end_frame()
	var gpu_pressure: PackedFloat32Array = gpu.read_pressure()

	# --- Compare ---
	var cpu: Dictionary = {
		"vel_x": field._vel_x, "vel_y": field._vel_y, "vel_z": field._vel_z,
		"pressure": field._pressure,
	}
	var gpu_out: Dictionary = {
		"vel_x": out["vel_x"], "vel_y": out["vel_y"], "vel_z": out["vel_z"],
		"pressure": gpu_pressure,
	}
	var ok: bool = true
	for name in ["vel_x", "vel_y", "vel_z", "pressure"]:
		var a: PackedFloat32Array = cpu[name]
		var b: PackedFloat32Array = gpu_out[name]
		var md: float = _max_diff(a, b)
		var tol: float = TOL_PRESSURE if name == "pressure" else TOL_VEL
		var pass_field: bool = md <= tol
		print("  ", name, ": max_diff=", md, "  tol=", tol, "  ", "ok" if pass_field else "OVER_TOL")
		if not pass_field:
			ok = false
	# Diagnostic: domain-mean horizontal wind magnitude (both paths should agree).
	print("  avg_wind cpu=", wind.avg_wind())
	gpu.dispose()
	field.free()
	return ok


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
