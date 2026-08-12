class_name LAMaterialFieldSphereStep3D
extends RefCounted

## Per-frame step orchestration of LAMaterialField3D.

# Sim-clock seconds banked per field step (accumulator cadence, not simulated time).
const STEP_DT: float = 1.0 / 10.0
const MAX_STEPS_PER_FRAME: int = 2
const FIELD_CADENCE_MAX: int = 60                       # clamp for the published Sim knob (avoid absurd skips)

# Simulated seconds ONE field step represents. Gated by scripts/check_step_quantum.sh.
const SIM_SECONDS_PER_STEP: float = 43.2

## Simulated seconds one field step represents.
static func real_seconds_per_step() -> float:
	return SIM_SECONDS_PER_STEP


## Simulated seconds per sim-clock second.
static func real_seconds_per_sim_second() -> float:
	return SIM_SECONDS_PER_STEP / STEP_DT


## Planet rotation period, seconds.
static func rotation_period_s() -> float:
	return TAU / LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S


## Field steps in one rotation. Rises when the planet spins slower; the per-step chemistry does not move.
static func steps_per_rotation() -> float:
	return rotation_period_s() / SIM_SECONDS_PER_STEP


## Sim-clock seconds in one rotation. The sim clock's day is this and nothing else.
static func day_length_sim_seconds() -> float:
	return steps_per_rotation() * STEP_DT

const LakesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldLakes3D.gd")
const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const AttributionScript: GDScript = preload("res://addons/local_agents/sim/material/FieldPassAttribution3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")
const PassProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldPassProbe3D.gd")

var _f = null                                          # back-reference to the owning LAMaterialField3D
var _frame_gate: int = 0                                 # frames elapsed since the last GPU field run (cadence skip counter)
var _mineral_profile = null
# The driver's ONE between-pass probe.
var _probe = null

var _sim_s: float = 0.0
var _offer_s: float = 0.0


func _armed(name: String) -> bool:
	return OS.get_environment(name) != ""


func setup(field) -> void:
	_f = field
	if _armed("LA_MINERAL_PROFILE"):
		_mineral_profile = MineralProfileScript.new()
		_mineral_profile.setup(field)
	_probe = _pick_probe(field)


## The driver has exactly ONE `set_step_probe` slot.
func _pick_probe(field):
	var armed: PackedStringArray = PackedStringArray()
	for name in LAFieldAttributionRecords.ORDER:
		if _armed(name):
			armed.append(name)
	if _armed("LA_ELEMENT_BUDGET"):
		armed.append("LA_ELEMENT_BUDGET")
	if armed.size() > 1:
		push_warning("%s all set — they share the driver's single step probe. Running %s only; unset it to "
			% [", ".join(armed), armed[0]] + "get one of the others.")
	if armed.size() > 0:
		if armed[0] == "LA_ELEMENT_BUDGET":
			var element_probe = ElementProbeScript.new()
			element_probe.setup(field)
			return element_probe
		var attribution = AttributionScript.new()
		attribution.setup(field, LAFieldAttributionRecords.of(armed[0]))
		return attribution
	var pass_probe = PassProbeScript.new()
	pass_probe.setup(field)
	return pass_probe if pass_probe.armed() else null


func _field_cadence() -> int:
	if OS.has_environment("LA_FIELD_CADENCE"):   # benchmark override: measure field step-rate vs perf/aggregates
		return clampi(int(OS.get_environment("LA_FIELD_CADENCE")), 1, FIELD_CADENCE_MAX)
	var n: int = int(Engine.get_meta("la_field_cadence", 1)) if Engine.has_meta("la_field_cadence") else 1
	return clampi(n, 1, FIELD_CADENCE_MAX)


## Per-frame step.
func process(delta: float) -> void:
	if not _f._ready_sim:
		if _f._terrain == null or not _f._terrain.has_method("is_solid"):
			return
		_f.sample_solidity()
		# Gravity BEFORE anything asks which way is down: every "below"/"above" read is a slot chosen from g.
		_f.solve_gravity()
		_f._seed_sea()                # fills the ocean basin with real, flowing water
		_f._compute_regolith()        # the permeable aquifer band (+ initial water table) for groundwater flow
		LakesScript.new().seed(_f)    # priority-flood standing lakes in enclosed land basins (static water bodies)
		_f.activate()                 # builds the GPU driver + sets _use_gpu
		_f._ready_sim = true
		return
	if not _f._use_gpu:
		return
	# Refresh the body rotation FIRST: everything below that converts a position or a direction reads it.
	_f.sync_body_frame()
	# Bank the frame's dt EVERY frame (even ones we skip).
	_f._step_accum += delta
	_offer_s += delta
	LASimReport.gauge("field_offer_s", _offer_s)
	_f._step_accum = minf(_f._step_accum, STEP_DT * float(MAX_STEPS_PER_FRAME + 1))
	# Cadence gate: only run the GPU begin/step/end loop every N frames (N = la_field_cadence).
	var cadence: int = _field_cadence()
	_frame_gate += 1
	if _frame_gate < cadence:
		return
	_frame_gate = 0
	var cap: int = MAX_STEPS_PER_FRAME if cadence <= 1 else 1
	var steps: int = 0
	while _f._step_accum >= STEP_DT and steps < cap:
		_f._step_accum -= STEP_DT
		steps += 1
	if cadence > 1:
		_f._step_accum = minf(_f._step_accum, STEP_DT)
	_sim_s += STEP_DT * float(steps)
	LASimReport.gauge("field_sim_s", _sim_s)
	if steps <= 0:
		return
	var t0: int = Time.get_ticks_usec()
	var t_pin: int = Time.get_ticks_usec()
	# g follows the mass, and every kernel asking which way is down reads the solved field.
	if _f.solve_gravity():
		_f._gpu.mark_gravity_dirty()
	_f._step_geotherm()              # radiogenic decay: hand the rock the joules its own mass produced
	LASimReport.gauge("field_pin_ms", float(Time.get_ticks_usec() - t_pin) / 1000.0)
	var t_begin: int = Time.get_ticks_usec()
	_f._gpu.begin_frame(_f._h, _f._h2o)      # drains prev step (sync+readback) + uploads
	LASimReport.gauge("field_begin_ms", float(Time.get_ticks_usec() - t_begin) / 1000.0)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	if _f._sun_light != null and _f._gpu.has_method("set_sun_dir"):
		# The MAGNITUDE of sun_dir carries INSOLATION (orbit-distance² × atmospheric transmission).
		var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
		_f._gpu.set_sun_dir(_f.dir_to_field(_f._sun_light.global_transform.basis.z * insol))
	# The world-gen seeds, declared through the seal.
	if _f._fuel_dirty and _f._gpu.has_method("seed_field"):
		_f._gpu.seed_field("fuel", _f._fuel, _f._seal)
		_f._fuel_dirty = false
	if _f._detritus_seed_dirty and _f._gpu.has_method("seed_field"):
		_f._gpu.seed_field("detritus", _f._detritus, _f._seal)
		_f._detritus_seed_dirty = false
	# The seeded litter's bound H and O, in the same one-shot as its carbon.
	if _f._organic_seed_dirty and _f._gpu.has_method("seed_field"):
		_f._gpu.seed_field("org_h", _f._org_h, _f._seal)
		_f._gpu.seed_field("org_o", _f._org_o, _f._seal)
		_f._organic_seed_dirty = false
	if _f._inject != null and not _f._inject.queue.is_empty():
		if OS.has_environment("LA_INJECT_AUDIT"):
			# Diagnostic.
			_f._inject.queue.audit_rewind(_f._gpu, "h2o", _f._h2o)
		_f._inject.queue.flush(_f._gpu)
	var t_step: int = Time.get_ticks_usec()
	for i in steps:
		if _probe != null:
			_probe.pre_step()         # arm/disarm the driver's between-pass probe for THIS step
			_f._gpu.step()
			_probe.post_step()        # print the per-pass budget (no-op on unsampled steps)
		else:
			_f._gpu.step()
	LASimReport.gauge("field_dispatch_ms", float(Time.get_ticks_usec() - t_step) / 1000.0)
	var res: Dictionary = _f._gpu.end_frame()
	var t_post: int = Time.get_ticks_usec()
	_apply_readback(res)
	# Seal on the field clock, never the report clock.
	if _f._seal != null and _f._gpu.has_method("take_probe"):
		_f._seal.poll(_f._gpu.take_probe())
	# Surface seed module: coarse-cadence biomass -> fuel litter transfer, queued sparse.
	if _f._surface_seed != null:
		_f._surface_seed.post_readback()
	# Charge module reads the strike list the breakdown kernel published and fires the bolt visuals.
	if _f._charge_mod != null:
		_f._charge_mod.post_step()
	if _f._stamp != null:
		_f._stamp.maybe_scan()                       # Stage C: stamp rock_fill 0.5-crossings into the SDF (gated)
	LASimReport.gauge("field_post_ms", float(Time.get_ticks_usec() - t_post) / 1000.0)   # scatter + CPU post-passes
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t0) / 1000.0)
	LASimReport.event("field_step")   # telemetry: GPU field runs/run — a slower cadence lowers this (and the avg field_ms)
	if _mineral_profile != null:
		_mineral_profile.post_step()  # LA_MINERAL_PROFILE: print WHERE the loose mineral is, by elevation


func _apply_readback(res: Dictionary) -> void:
	var n: int = _f._cell_count
	if res.has("h_j_m3") and res["h_j_m3"].size() == n: _f._h = res["h_j_m3"]
	if res.has("temp") and res["temp"].size() == n: _f._temp = res["temp"]
	if res.has("h2o") and res["h2o"].size() == n: _f._h2o = res["h2o"]
	# The three DERIVED shares: recomputed by StateDerivePass every step, never conserved, never uploaded.
	if res.has("h2o_solid") and res["h2o_solid"].size() == n: _f._h2o_solid = res["h2o_solid"]
	if res.has("h2o_liquid") and res["h2o_liquid"].size() == n: _f._h2o_liquid = res["h2o_liquid"]
	if res.has("h2o_vapour") and res["h2o_vapour"].size() == n: _f._h2o_vapour = res["h2o_vapour"]
	_f._atmos_dirty = true          # new h2o/temp → invalidate the cached condensate aggregates
	if res.has("lava") and res["lava"].size() == n: _f._lava = res["lava"]
	if res.has("porosity") and res["porosity"].size() == n: _f._porosity = res["porosity"]
	if res.has("fire") and res["fire"].size() == n: _f._fire = res["fire"]
	if res.has("fuel") and res["fuel"].size() == n: _f._fuel = res["fuel"]
	if res.has("fert") and res["fert"].size() == n: _f._fert = res["fert"]
	if res.has("o2") and res["o2"].size() == n: _f._o2 = res["o2"]
	if res.has("co2") and res["co2"].size() == n: _f._co2 = res["co2"]
	if res.has("biomass") and res["biomass"].size() == n: _f._biomass = res["biomass"]
	if res.has("dust") and res["dust"].size() == n: _f._dust = res["dust"]
	if res.has("sediment") and res["sediment"].size() == n: _f._sediment = res["sediment"]
	if res.has("susp") and res["susp"].size() == n: _f._susp = res["susp"]   # erosion pickup phase → mineral ledger

	if res.has("rock_fill") and res["rock_fill"].size() == n: _f._rock_fill = res["rock_fill"]
	# Substrate-foundation channels.
	if res.has("shock") and res["shock"].size() == n: _f._shock = res["shock"]
	if res.has("charge") and res["charge"].size() == n: _f._charge = res["charge"]
	if res.has("vel_x") and res["vel_x"].size() == n: _f._vel_x = res["vel_x"]
	if res.has("vel_y") and res["vel_y"].size() == n: _f._vel_y = res["vel_y"]
	if res.has("vel_z") and res["vel_z"].size() == n: _f._vel_z = res["vel_z"]
	if res.has("pressure") and res["pressure"].size() == n: _f._pressure = res["pressure"]
	if res.has("detritus") and res["detritus"].size() == n: _f._detritus = res["detritus"]
	if res.has("fungus") and res["fungus"].size() == n: _f._fungus = res["fungus"]
