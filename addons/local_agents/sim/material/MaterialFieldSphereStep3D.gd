class_name LAMaterialFieldSphereStep3D
extends RefCounted

## LAMaterialFieldSphereStep3D: the cubed-sphere per-frame STEP ORCHESTRATION of LAMaterialField3D,

# Fixed-step cadence — mirrors the field's own constants so the loop is self-contained.
const STEP_DT: float = 1.0 / 10.0
const MAX_STEPS_PER_FRAME: int = 2
const FIELD_CADENCE_MAX: int = 60                       # clamp for the published Sim knob (avoid absurd skips)

## Real seconds ONE field step represents.
static func real_seconds_per_step() -> float:
	return STEP_DT * LASimClock.REAL_SECONDS_PER_SIM_SECOND

const LakesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldLakes3D.gd")
const SoilBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd")
const H2OBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldH2OBudget3D.gd")
const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const MineralProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProbe3D.gd")
const EnergyProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldEnergyProbe3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")

var _f = null                                          # back-reference to the owning LAMaterialField3D
var _frame_gate: int = 0                                 # frames elapsed since the last GPU field run (cadence skip counter)
# Per-leg groundwater budget probe (LA_SOIL_BUDGET). Owned here rather than on the field because it is a
# STEP diagnostic: it needs a hook that fires once per GPU step, which is this loop and nowhere else.
var _soil_budget = null
# Per-pass H₂O budget probe (LA_H2O_BUDGET). Owned here for the same reason as the soil budget: it needs a hook
# on BOTH sides of the GPU step (pre_step arms the driver's between-pass probe, post_step prints), and this loop
# is the only place that has one.
var _h2o_budget = null
var _mineral_profile = null
# Per-pass MINERAL budget probe (LA_MINERAL_BUDGET) — the same instrument for the five rock phases. It uses the
# driver's ONE `set_step_probe` slot, so it and the H₂O probe are mutually exclusive; setup() warns and keeps
# this one when both variables are present, rather than letting one silently take every checkpoint.
var _mineral_probe = null
var _energy_probe = null
# LA_ELEMENT_BUDGET=<element>: per-pass attribution for an element, in moles.
var _element_probe = null
# LA_PASS_PROBE=<channel>: totals one channel after every pass for the first few steps. Lowest precedence of
# the step-probe contenders, so it never displaces a ledger someone armed deliberately.
var _pass_probe = null

var _sim_s: float = 0.0
var _offer_s: float = 0.0


func _armed(name: String) -> bool:
	return OS.get_environment(name) != ""


func setup(field) -> void:
	_pass_probe = load("res://addons/local_agents/sim/material/MaterialFieldPassProbe3D.gd").new()
	_pass_probe.setup(field)
	_f = field
	if _armed("LA_SOIL_BUDGET"):
		_soil_budget = SoilBudgetScript.new()
		_soil_budget.setup(field)
	# THE DRIVER HAS EXACTLY ONE `set_step_probe` SLOT and four probes want it. Arming two would give one of
	# them every checkpoint and the other none, silently, so this picks by a DECLARED precedence and says which
	# one it kept.
	var slot_order: Array = [
		["LA_MINERAL_BUDGET", MineralProbeScript],
		["LA_H2O_BUDGET", H2OBudgetScript],
		["LA_ENERGY_BUDGET", EnergyProbeScript],
		["LA_ELEMENT_BUDGET", ElementProbeScript]]
	var slot_armed: PackedStringArray = PackedStringArray()
	for entry in slot_order:
		if _armed(entry[0]):
			slot_armed.append(entry[0])
	if slot_armed.size() > 1:
		push_warning("%s all set — they share the driver's single step probe. Running %s only; unset it to "
			% [", ".join(slot_armed), slot_armed[0]] + "get one of the others.")
	if slot_armed.size() > 0:
		for entry in slot_order:
			if entry[0] != slot_armed[0]:
				continue
			var probe_obj = entry[1].new()
			probe_obj.setup(field)
			match entry[0]:
				"LA_MINERAL_BUDGET": _mineral_probe = probe_obj
				"LA_H2O_BUDGET": _h2o_budget = probe_obj
				"LA_ENERGY_BUDGET": _energy_probe = probe_obj
				"LA_ELEMENT_BUDGET": _element_probe = probe_obj
	if _armed("LA_MINERAL_PROFILE"):
		_mineral_profile = MineralProfileScript.new()
		_mineral_profile.setup(field)


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
		_f._seed_sphere_sea()         # fills the ocean basin with real, flowing water
		_f._compute_regolith()        # the permeable aquifer band (+ initial water table) for groundwater flow
		LakesScript.new().seed(_f)    # priority-flood standing lakes in enclosed land basins (static water bodies)
		if _f._geotherm != null:
			_f._geotherm.arm(LAPhysical.INNER_CORE_C)   # the interior's heat, declared through the seal
		_f.activate()                 # is_sphere() → picks SphereGPUScript + sets _use_gpu
		_f._ready_sim = true
		return
	if not _f._use_gpu:
		return
	# Refresh the body rotation FIRST: everything below that converts a position or a direction reads it.
	_f.sync_body_frame()
	# Bank the frame's dt EVERY frame (even ones we skip), clamped so a high cadence can't let the accumulator
	# run away into a huge catch-up spike after a long skip (excess banked time is dropped → the field simply
	# evolves slower at a slow cadence, the intended perf trade; buffers stay consistent).
	_f._step_accum += delta
	_offer_s += delta
	LASimReport.gauge("field_offer_s", _offer_s)
	_f._step_accum = minf(_f._step_accum, STEP_DT * float(MAX_STEPS_PER_FRAME + 1))
	# Cadence gate: only run the GPU begin/step/end loop every N frames (N = la_field_cadence). At N == 1 this
	# reduces to the historical every-frame path (the gate never trips).
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
	# Global scalar solar term is a constant fallback; the per-cell solar terminator comes from the sphere
	# ThermalPass' set_sun_dir kernel (max(0, dot(cell_radial, sun_dir))), not this scalar.
	var solar: float = 0.6
	var t_pin: int = Time.get_ticks_usec()
	_f._step_geotherm()              # finite core reservoir: cool it, and publish its flux for this step
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
		_f._gpu.set_sun_dir(_f.dir_to_field(_f._sun_light.global_transform.basis.z * insol))
	if _f._body != null and _f._gpu.has_method("set_spin_axis"):
		_f._gpu.set_spin_axis(_f.dir_to_field(_f._body.spin_axis() if _f._body.has_method("spin_axis") else Vector3.UP))
	if _f._terrain != null and _f._terrain.has_method("sea_radius") and _f._gpu.has_method("set_sea_radius"):
		_f._gpu.set_sea_radius(_f._terrain.sea_radius())
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
	if _f._detritus_seed_dirty and _f._gpu.has_method("seed_field"):
		_f._gpu.seed_field("detritus", _f._detritus, _f._seal)
		_f._detritus_seed_dirty = false
	# ...and the C:H:O of that seeded litter, in the same one-shot. Seeding carbon without its hydrogen and
	# oxygen would start every cell at the anthracite end of the spectrum instead of the fresh end.
	if _f._organic_seed_dirty and _f._gpu.has_method("seed_field"):
		_f._gpu.seed_field("org_h", _f._org_h, _f._seal)
		_f._gpu.seed_field("org_o", _f._org_o, _f._seal)
		_f._organic_seed_dirty = false
	if _f._inject != null and not _f._inject.queue.is_empty():
		if OS.has_environment("LA_INJECT_AUDIT"):
			# Diagnostic: how far the CPU mirror has drifted from the live buffer right now == exactly the mass
			# the old mirror-upload would have written away on this frame.
			_f._inject.queue.audit_rewind(_f._gpu, "moisture", _f._moisture)
		_f._inject.queue.flush(_f._gpu)
	var t_step: int = Time.get_ticks_usec()
	# At most one budget probe is ever non-null (setup() enforces it), so this stays one branch, not a nest.
	# Untyped like every other duck-typed module handle in this file.
	var probe = _h2o_budget if _h2o_budget != null else _mineral_probe
	if probe == null:
		probe = _energy_probe
	if probe == null:
		probe = _element_probe
	if probe == null and _pass_probe != null and _pass_probe.armed():
		probe = _pass_probe
	for i in steps:
		if probe != null:
			probe.pre_step()          # arm/disarm the driver's between-pass probe for THIS step
			_f._gpu.step()
			probe.post_step()         # print the per-pass budget (no-op on unsampled steps)
		else:
			_f._gpu.step()
	LASimReport.gauge("field_dispatch_ms", float(Time.get_ticks_usec() - t_step) / 1000.0)
	var res: Dictionary = _f._gpu.end_frame()
	var t_post: int = Time.get_ticks_usec()
	_apply_readback(res)
	# Seal on the field clock, never the report clock: poll() both closes the books and latches every
	# conservation baseline on that step, so no baseline depends on the 64-frame gauge cadence.
	if _f._seal != null and _f._gpu.has_method("take_probe"):
		_f._seal.poll(_f._gpu.take_probe())
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
	if _soil_budget != null:
		_soil_budget.post_step()      # LA_SOIL_BUDGET: print the per-leg groundwater ledger on its own cadence
	if _mineral_profile != null:
		_mineral_profile.post_step()  # LA_MINERAL_PROFILE: print WHERE the loose mineral is, by elevation


func _apply_readback(res: Dictionary) -> void:
	var n: int = _f._cell_count
	if res.has("temp") and res["temp"].size() == n: _f._temp = res["temp"]
	if res.has("water") and res["water"].size() == n: _f._water = res["water"]
	if res.has("moisture") and res["moisture"].size() == n: _f._moisture = res["moisture"]
	_f._atmos_dirty = true          # new moisture/temp → invalidate the cached condensate aggregates
	if res.has("lava") and res["lava"].size() == n: _f._lava = res["lava"]
	if res.has("porosity") and res["porosity"].size() == n: _f._porosity = res["porosity"]
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
	# Hydrostatic column pressure — demand-gated (LAMaterialFieldEnergyBudget3D requests it to mirror the solar
	if res.has("pressure") and res["pressure"].size() == n: _f._pressure = res["pressure"]
	# Decomposer loop channels — demand-gated (LAMaterialFieldElementInventory3D requests them for the carbon
	if res.has("detritus") and res["detritus"].size() == n: _f._detritus = res["detritus"]
	if res.has("fungus") and res["fungus"].size() == n: _f._fungus = res["fungus"]
