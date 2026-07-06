extends SceneTree

## SHORT parity check for the GPU-resident DUST / SAND-STORM passes (kernels3d/dust_loft3d.glsl +
## dust_outscale3d.glsl + dust_transport3d.glsl) added to LAMaterialGPU3D. Seeds a small synthetic 3D field
## with a loose-sediment layer on the floor and a STRONG horizontal wind (> LOFT_WIND) so the wind scours dry
## sediment into airborne dust that then advects / diffuses / settles and deposits back, runs K steps through
## the CPU oracle (step_water -> heat -> wind -> atmosphere -> slump -> dust, matching the GPU step() order —
## lava/fire are zero-seeded no-ops) and the SAME K through the GPU resident frame API (begin_frame -> step xK
## -> end_frame), then asserts the airborne DUST channel matches to ~1e-3 (and the coupled loose SEDIMENT
## within a rel-discounted 1e-3) and prints PASS/FAIL + max diffs. GPU needs a RenderingDevice, so run WINDOWED
## with the metal driver (NOT --headless, which has no local RenderingDevice):
##   godot --rendering-driver metal --path . --script addons/local_agents/scenes/simulation/voxel/material/parity_gpu3d_dust.gd
## (Explicit types only — no ':=' inferred typing.)

const FieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const WindScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWind3D.gd")
const SlumpScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialSlump3D.gd")
const DustScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialDust3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")

const DIM: int = 8
const CELL_SIZE: float = 5.0
const SEA_LEVEL: float = 12.0
const STEPS: int = 8
const TOL_DUST: float = 1.0e-3        # airborne dust gate (tiny magnitude — should match tightly)
const TOL_SED: float = 1.0e-3         # sediment gate (rel-discounted; ~0.6 magnitude, float32 rounding over K)
const WIND: Vector2 = Vector2(10.0, 0.0)   # strong PREVAILING wind (> LOFT_WIND = 6) so lofting is exercised


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
	# A strong, uniform +X wind so the first steps loft sediment everywhere (hspeed = 10 > LOFT_WIND = 6). The
	# prevailing wind (set below) keeps it blowing; buoyancy/pressure evolve vel identically on both paths.
	var velx: PackedFloat32Array = PackedFloat32Array(); velx.resize(cc)
	var velz: PackedFloat32Array = PackedFloat32Array(); velz.resize(cc)

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = _idx(ix, iy, iz)
				temp[i] = 20.0                   # mild uniform temp (dry, warm → no snow; wind driven by prevailing)
				velx[i] = 10.0
				if iy == 0:
					solid[i] = 1                 # rock floor
	# A loose DRY sediment layer sitting on the floor (iy == 1, open air above at iy == 2) — the sand a dust
	# storm scours up. Uniform 0.6 so slump is at rest until lofting carves it non-uniform.
	for iz2 in range(dz):
		for ix2 in range(dx):
			sediment[_idx(ix2, 1, iz2)] = 0.6

	# --- CPU oracle: a real field seeded with copies, stepped water -> heat -> wind -> atmo -> slump -> dust. ---
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
	var wind = WindScript.new(); wind.setup(field); wind.set_prevailing(WIND)
	var atmo = AtmoScript.new(); atmo.setup(field); atmo.set_wind(WIND)
	var slump = SlumpScript.new(); slump.setup(field)
	var dust_sim = DustScript.new(); dust_sim.setup(field)

	var solar: float = heat._solar()       # sun_light null -> constant 0.6, matching the GPU push-constant

	for k in range(STEPS):
		field.step_water()
		heat.step()
		wind.step()                        # PASS A pressure + PASS B velocity (matches GPU order)
		atmo.step()
		slump.step()                       # evolves _sediment (GPU runs slump_flow before dust — must match)
		dust_sim.step()                    # loft + outscale + transport (the GPU port's core)

	# --- GPU resident path: seed the same start, run the same K steps, read back once. ---
	var gpu = GPUScript.new()
	gpu.setup(field)
	gpu.upload_static_state(solid, stat)   # push the ORIGINAL masks (field's were mutated by the CPU run)
	gpu.set_prevailing(WIND)
	gpu.set_raining(false)                 # dry — lofting allowed (matches precipitation()==0 in the oracle)
	gpu.begin_frame(temp, water, solar, WIND)
	gpu.upload_wind(velx, velz)            # same strong +X wind the CPU lofted with
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
	var ok: bool = true
	var da: PackedFloat32Array = field._dust
	var db: PackedFloat32Array = out["dust"]
	var dmd: float = _max_diff(da, db, false)
	var dust_ok: bool = dmd <= TOL_DUST
	print("  dust: max_diff=", dmd, "  tol=", TOL_DUST, "  ", "ok" if dust_ok else "OVER_TOL")
	if not dust_ok:
		ok = false
	var sa: PackedFloat32Array = field._sediment
	var sb: PackedFloat32Array = out["sediment"]
	var smd: float = _max_diff(sa, sb, true)
	var sed_ok: bool = smd <= TOL_SED
	print("  sediment: max_diff=", smd, "  tol=", TOL_SED, "  ", "ok" if sed_ok else "OVER_TOL")
	if not sed_ok:
		ok = false
	# Diagnostic: airborne cells + peak (both paths should agree; > 0 proves lofting actually happened).
	print("  dust_cells cpu=", dust_sim.dust_cells(), " peak=", dust_sim.dust_peak(), " total_dust=", dust_sim.total_dust())
	gpu.dispose()
	field.free()
	return ok


# Max diff: abs, but when use_rel the per-cell diff is discounted by 1e-4 * |cpu| so higher-magnitude
# sediment isn't penalized for float32 rounding over K steps (same gate the fire/atmos harnesses use for temp).
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
