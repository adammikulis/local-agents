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
const FIELD_CADENCE_MAX: int = 60                       # clamp for the published Sim knob (avoid absurd skips)

const LakesScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldLakes3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _frame_gate: int = 0                                 # frames elapsed since the last GPU field run (cadence skip counter)


func setup(field) -> void:
	_f = field


## Field substrate steps every N physics frames, N = the player's Sim knob `la_field_cadence` (published by
## LAVoxelSettingsApplier as an Engine metadata global). Default/missing/zero → 1 (step every frame, i.e. the
## historical behaviour). Read live so a mid-game settings re-apply retunes it. Skip-and-accumulate: dt is
## banked every frame regardless, so a slower cadence runs the (fixed-step) loop less often — genuinely less
## GPU field work — without desyncing the buffers (dirty-gated uploads still flush on the next run).
func _field_cadence() -> int:
	if OS.has_environment("LA_FIELD_CADENCE"):   # benchmark override: measure field step-rate vs perf/aggregates
		return clampi(int(OS.get_environment("LA_FIELD_CADENCE")), 1, FIELD_CADENCE_MAX)
	var n: int = int(Engine.get_meta("la_field_cadence", 1)) if Engine.has_meta("la_field_cadence") else 1
	return clampi(n, 1, FIELD_CADENCE_MAX)


## Cubed-sphere per-frame step (Phase B MVP): activate the sphere GPU driver once, then run the fixed-step
## begin_frame/step/end_frame loop over the *_sphere3d kernels and scatter temp/water back. No box CPU tails.
func process(delta: float) -> void:
	if not _f._ready_sim:
		if _f._terrain == null or not _f._terrain.has_method("is_solid"):
			return
		_f._sample_solidity_sphere()
		_f._seed_sphere_sea()         # static field sea = the evaporation source that drives the water cycle
		_f._compute_regolith()        # the permeable aquifer band (+ initial water table) for groundwater flow
		LakesScript.new().seed(_f)    # priority-flood standing lakes in enclosed land basins (static water bodies)
		_f.activate()                 # is_sphere() → picks SphereGPUScript + sets _use_gpu
		_f._ready_sim = true
		return
	if not _f._use_gpu:
		return
	# Bank the frame's dt EVERY frame (even ones we skip), clamped so a high cadence can't let the accumulator
	# run away into a huge catch-up spike after a long skip (excess banked time is dropped → the field simply
	# evolves slower at a slow cadence, the intended perf trade; buffers stay consistent).
	_f._step_accum += delta
	_f._step_accum = minf(_f._step_accum, STEP_DT * float(MAX_STEPS_PER_FRAME + 1))
	# Cadence gate: only run the GPU begin/step/end loop every N frames (N = la_field_cadence). At N == 1 this
	# reduces to the historical every-frame path (the gate never trips).
	var cadence: int = _field_cadence()
	_frame_gate += 1
	if _frame_gate < cadence:
		return
	_frame_gate = 0
	# At the natural cadence (1) allow up to MAX_STEPS to catch up a frame hitch — conserving sim time. At a
	# slower cadence (N > 1) cap to ONE step per gate AND drop the dt banked during the skipped frames, so the
	# field genuinely dispatches LESS often (fewer GPU steps → lower avg field_ms) instead of catching up: it
	# evolves in slight slow-motion, the intended perf trade. Every step is still a full begin/step/end with
	# the dirty-gated uploads, so buffers never desync. (The knob only slows the field once N pushes below the
	# ~10 Hz fixed-step rate; presets 1-2 keep full fidelity.)
	var cap: int = MAX_STEPS_PER_FRAME if cadence <= 1 else 1
	var steps: int = 0
	while _f._step_accum >= STEP_DT and steps < cap:
		_f._step_accum -= STEP_DT
		steps += 1
	if cadence > 1:
		_f._step_accum = minf(_f._step_accum, STEP_DT)
	if steps <= 0:
		return
	var t0: int = Time.get_ticks_usec()
	# Global scalar solar term is a constant fallback; the per-cell solar terminator comes from the sphere
	# ThermalPass' set_sun_dir kernel (max(0, dot(cell_radial, sun_dir))), not this scalar.
	var solar: float = 0.6
	var t_pin: int = Time.get_ticks_usec()
	_f._pin_core_heat()              # geothermal boundary: re-pin the hot inner shells before the upload
	LASimReport.gauge("field_pin_ms", float(Time.get_ticks_usec() - t_pin) / 1000.0)
	var t_begin: int = Time.get_ticks_usec()
	_f._gpu.begin_frame(_f._temp, _f._water, solar, Vector2.ZERO)   # drains prev step (sync+readback) + uploads
	LASimReport.gauge("field_begin_ms", float(Time.get_ticks_usec() - t_begin) / 1000.0)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	# sun_dir points from the planet toward the star; ThermalPass' solar kernel does max(0, dot(cell_radial, sun_dir)).
	if _f._sun_light != null and _f._gpu.has_method("set_sun_dir"):
		# The MAGNITUDE of sun_dir carries INSOLATION (orbit-distance² × atmospheric transmission), stamped on the
		# sun by LASystemOrbits. The solar kernel's max(0, dot(cell_radial, sun_dir)) then scales intensity with the
		# direction — nearer the sun bakes, farther freezes, airborne dust dims it → impact winter. Default 1.0.
		var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
		_f._gpu.set_sun_dir(_f._sun_light.global_transform.basis.z * insol)
	if _f._terrain != null and _f._terrain.has_method("sea_radius") and _f._gpu.has_method("set_sea_radius"):
		_f._gpu.set_sea_radius(_f._terrain.sea_radius())
	# GLOBAL water-cycle bound: feed the current cloud cover to atmos_evap so the infinite static sea tapers its
	# pumping as the atmosphere fills toward a steady cover (a local humidity brake can't cap a total that
	# transport keeps moving around). Uses the cached aggregate (refreshed by the atmos/report cadence) — the
	# brake changes slowly, so a slightly stale value is fine and avoids forcing a per-step GPU readback.
	if _f._gpu.has_method("set_atmos_humidity"):
		# Average atmospheric moisture per cell — the DIRECT measure of the water-cycle load (cloud cover under-reads
		# it, since most moisture rides as sub-saturation humidity, not condensed cloud). The evap gate uses this to
		# stop the infinite sea pumping once the air holds its target mass. Uses cached totals (no per-step readback).
		var open_est: float = maxf(float(_f._cell_count), 1.0)
		_f._gpu.set_atmos_humidity(_f._moisture_total_c / open_est)
	# add_lava injected on the CPU this frame → push the edited lava + bedrock into the GPU before stepping
	# (dirty-gated: on clean frames both stay GPU-resident, so we never clobber the on-device evolution).
	if _f._lava_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("lava", _f._lava)
		_f._lava_dirty = false
	if _f._rock_fill_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("rock_fill", _f._rock_fill)
		_f._rock_fill_dirty = false
	# Substrate-foundation local injections (dirty-gated, mirror lava): emit_shock/add_charge/add_vapor
	# edited the CPU channel this frame → push it into the GPU before the step so the kernel evolves it.
	if _f._shock_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("shock", _f._shock)
		_f._shock_dirty = false
	if _f._charge_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("charge", _f._charge)
		_f._charge_dirty = false
	# Scent is a 5-plane packed channel; deposit() seeded a plane on the CPU this frame → push it before the step.
	if _f._scent_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("scent", _f._scent)
		_f._scent_dirty = false
	# Combustion fuel seeded/refilled on the CPU (surface seed module) → push it into the GPU fuel buffer so the
	# fire kernel (which gates on fuel > 0) can ignite + consume it. Dirty-gated: else fuel stays GPU-resident.
	if _f._fuel_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("fuel", _f._fuel)
		_f._fuel_dirty = false
	# One-shot: push the initial soil detritus seed into the GPU before the first step so the decomposer has
	# substrate from frame 0. Cleared immediately so the GPU-evolved detritus (respiration/decompose) is never clobbered.
	if _f._detritus_seed_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("detritus", _f._detritus)
		_f._detritus_seed_dirty = false
	if _f._vapor_dirty and _f._gpu.has_method("set_field"):
		_f._gpu.set_field("moisture", _f._moisture)
		_f._vapor_dirty = false
	var t_step: int = Time.get_ticks_usec()
	for i in steps:
		_f._gpu.step()
	LASimReport.gauge("field_dispatch_ms", float(Time.get_ticks_usec() - t_step) / 1000.0)
	var res: Dictionary = _f._gpu.end_frame()
	var t_post: int = Time.get_ticks_usec()
	_apply_readback(res)
	# Surface seed module: coarse-cadence refill of fuel from the freshly read-back biomass (marks _fuel_dirty).
	if _f._surface_seed != null:
		_f._surface_seed.post_readback()
	# Charge module scans the fresh charge readback for breakdown → fires bolts (heat inject + visual callback).
	if _f._charge_mod != null:
		_f._charge_mod.post_step()
	if _f._stamp != null:
		_f._stamp.maybe_scan()                       # Stage C: stamp rock_fill 0.5-crossings into the SDF (gated)
	LASimReport.gauge("field_post_ms", float(Time.get_ticks_usec() - t_post) / 1000.0)   # scatter + CPU post-passes
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t0) / 1000.0)
	LASimReport.event("field_step")   # telemetry: GPU field runs/run — a slower cadence lowers this (and the avg field_ms)


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
	if res.has("fuel") and res["fuel"].size() == n: _f._fuel = res["fuel"]
	if res.has("fert") and res["fert"].size() == n: _f._fert = res["fert"]
	if res.has("o2") and res["o2"].size() == n: _f._o2 = res["o2"]
	if res.has("co2") and res["co2"].size() == n: _f._co2 = res["co2"]
	if res.has("biomass") and res["biomass"].size() == n: _f._biomass = res["biomass"]
	if res.has("snow") and res["snow"].size() == n: _f._snow = res["snow"]
	if res.has("dust") and res["dust"].size() == n: _f._dust = res["dust"]
	if res.has("sediment") and res["sediment"].size() == n: _f._sediment = res["sediment"]
	if res.has("susp") and res["susp"].size() == n: _f._susp = res["susp"]   # erosion pickup phase → mineral ledger

	if res.has("soil") and res["soil"].size() == n: _f._soil = res["soil"]        # water-table reservoir readback
	if res.has("rock_fill") and res["rock_fill"].size() == n: _f._rock_fill = res["rock_fill"]
	# Substrate-foundation channels: shock (tremor/impact), charge (bolt breakdown), and the emergent WIND
	# velocity field (wind3_at/wind_at read a real force instead of ZERO).
	if res.has("shock") and res["shock"].size() == n: _f._shock = res["shock"]
	if res.has("charge") and res["charge"].size() == n: _f._charge = res["charge"]
	# Scent is the 5-plane packed buffer (SCENT_CHANNELS * n) — scatter it back so senses smell live gradients.
	if res.has("scent") and res["scent"].size() == LAMaterialField3D.SCENT_CHANNELS * n: _f._scent = res["scent"]
	if res.has("vel_x") and res["vel_x"].size() == n: _f._vel_x = res["vel_x"]
	if res.has("vel_y") and res["vel_y"].size() == n: _f._vel_y = res["vel_y"]
	if res.has("vel_z") and res["vel_z"].size() == n: _f._vel_z = res["vel_z"]
