class_name LAMaterialFieldSphereStep3D
extends RefCounted

## LAMaterialFieldSphereStep3D — the cubed-sphere per-frame STEP ORCHESTRATION of LAMaterialField3D,
## factored out so the field node stays a thin substrate/composition core (and under the file-size gate).
## Holds NO field state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the GPU driver,
## the per-cell channel arrays, the dirty flags and the step accumulator, exactly as the query/inject
## modules do. Only the fixed-step begin_frame/step/end_frame loop + the readback scatter live here; the
## in-place packed-array mutators (core-heat pin, solidity sample, sea seed) stay on the field (they edit
## packed arrays element-wise, which is cleanest done on the owning object).
## (Explicit types only — no ':=' inferred typing.)

# Fixed-step cadence — mirrors the field's own constants so the loop is self-contained.
const STEP_DT: float = 1.0 / 10.0
const MAX_STEPS_PER_FRAME: int = 2

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Cubed-sphere per-frame step (Phase B MVP): activate the sphere GPU driver once, then run the fixed-step
## begin_frame/step/end_frame loop over the *_sphere3d kernels and scatter temp/water back. No box CPU tails.
func process(delta: float) -> void:
	if not _f._ready_sim:
		if _f._terrain == null or not _f._terrain.has_method("is_solid"):
			return
		_f._sample_solidity_sphere()
		_f._seed_sphere_sea()         # static field sea = the evaporation source that drives the water cycle
		_f.activate()                 # is_sphere() → picks SphereGPUScript + sets _use_gpu
		_f._ready_sim = true
		return
	if not _f._use_gpu:
		return
	_f._step_accum += delta
	var steps: int = 0
	while _f._step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_f._step_accum -= STEP_DT
		steps += 1
	if steps <= 0:
		return
	var t0: int = Time.get_ticks_usec()
	# Global scalar solar term is a constant fallback; the per-cell solar terminator comes from the sphere
	# ThermalPass' set_sun_dir kernel (max(0, dot(cell_radial, sun_dir))), not this scalar.
	var solar: float = 0.6
	_f._pin_core_heat()              # geothermal boundary: re-pin the hot inner shells before the upload
	_f._gpu.begin_frame(_f._temp, _f._water, solar, Vector2.ZERO)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	# sun_dir points from the planet toward the star; ThermalPass' solar kernel does max(0, dot(cell_radial, sun_dir)).
	if _f._sun_light != null and _f._gpu.has_method("set_sun_dir"):
		_f._gpu.set_sun_dir(_f._sun_light.global_transform.basis.z)
	if _f._terrain != null and _f._terrain.has_method("sea_radius") and _f._gpu.has_method("set_sea_radius"):
		_f._gpu.set_sea_radius(_f._terrain.sea_radius())
	# add_lava injected on the CPU this frame → push the edited lava + bedrock into the GPU before stepping
	# (dirty-gated: on clean frames both stay GPU-resident, so we never clobber the on-device evolution).
	if _f._lava_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("lava", _f._lava)
		_f._lava_dirty = false
	if _f._rock_fill_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("rock_fill", _f._rock_fill)
		_f._rock_fill_dirty = false
	for i in steps:
		_f._gpu.step()
	var res: Dictionary = _f._gpu.end_frame()
	_apply_readback(res)
	if _f._stamp != null:
		_f._stamp.maybe_scan()                       # Stage C: stamp rock_fill 0.5-crossings into the SDF (gated)
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t0) / 1000.0)


## Scatter every channel the sphere driver read back into its CPU array, so actor world-space queries
## (temp_at/o2_at/co2_at/is_submerged_at, routed through world_to_cell) and the SIM_REPORT field metrics
## see LIVE field state instead of the stale seed values. The readback cost is already paid inside
## end_frame(); assigning a PackedFloat32Array is a cheap COW reference. Guarded per channel by size.
func _apply_readback(res: Dictionary) -> void:
	var n: int = _f._cell_count
	if res.has("temp") and res["temp"].size() == n: _f._temp = res["temp"]
	if res.has("water") and res["water"].size() == n: _f._water = res["water"]
	if res.has("moisture") and res["moisture"].size() == n: _f._moisture = res["moisture"]
	_f._atmos_dirty = true          # new moisture/temp → invalidate the cached condensate aggregates
	if res.has("lava") and res["lava"].size() == n: _f._lava = res["lava"]
	if res.has("fire") and res["fire"].size() == n: _f._fire = res["fire"]
	if res.has("o2") and res["o2"].size() == n: _f._o2 = res["o2"]
	if res.has("co2") and res["co2"].size() == n: _f._co2 = res["co2"]
	if res.has("biomass") and res["biomass"].size() == n: _f._biomass = res["biomass"]
	if res.has("snow") and res["snow"].size() == n: _f._snow = res["snow"]
	if res.has("dust") and res["dust"].size() == n: _f._dust = res["dust"]
	if res.has("sediment") and res["sediment"].size() == n: _f._sediment = res["sediment"]
	if res.has("rock_fill") and res["rock_fill"].size() == n: _f._rock_fill = res["rock_fill"]
