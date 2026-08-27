class_name LAMaterialFieldSphereStep3D
extends RefCounted

## ONE field step per call. LASimLoop drives it; nothing here reads a frame delta or banks time.

# Simulated seconds ONE field step represents. Gated by scripts/check_step_quantum.sh.
const SIM_SECONDS_PER_STEP: float = 43.2

static func real_seconds_per_step() -> float:
	return SIM_SECONDS_PER_STEP


const LakesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldLakes3D.gd")
const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const AttributionScript: GDScript = preload("res://addons/local_agents/sim/material/FieldPassAttribution3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")
const PassProbeScript: GDScript = preload("res://addons/local_agents/runtime/FieldPassProbe3D.gd")

var _f = null                                          # back-reference to the owning LAMaterialField3D
var _mineral_profile = null
# The driver's ONE between-pass probe.
var _probe = null


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


## SEEDING. Runs while LASimLoop is held; releases the hold once the world exists and can be sealed.
## Returns true when the world is ready and no simulated time has passed yet.
func seed_tick() -> bool:
	if _f._ready_sim:
		return true
	if _f._terrain == null or not _f._terrain.has_method("is_solid"):
		return false
	_f.sample_solidity()          # solid mask -> the bedrock silicate + cement the gravity solve weighs
	_f._seed_sea()                # fills the ocean basin with real, flowing water
	_f.activate()                 # builds the GPU driver, which owns the solve the walks below read
	_f._gravity.solve_seed()      # g FIRST: every "below"/"above" below here is a slot chosen from it
	_f._compute_regolith()        # the permeable aquifer band (+ initial water table) for groundwater flow
	if not _f._regolith.has(1):
		push_error("The regolith walk marked no cell permeable, so every rock cell has zero porosity, the "
			+ "water table is unprimed and darcy_resistance() makes the groundwater row inert. The walk "
			+ "reads `below` from solved gravity: it ran before the solve was dispatched and drained.")
	LakesScript.new().seed(_f)    # priority-flood standing lakes in enclosed land basins
	# The lakes poured water into already-seeded cells: displace the gas it occupies, and re-derive
	# the enthalpy so the water arrives WITH its heat.
	LAFieldLithostaticSeed.displace_gas_from_water(_f)
	# THE WORLD PUT INTO THE BALANCE THE STEPPER HOLDS, now that gravity has a direction: the atmosphere
	# falls off over the scale height the SOLVED g states, then every open cell's amounts are set to the
	# marched pressure and every rock cell is squeezed by what stands over it.
	var g_solved: PackedFloat32Array = _f._gravity.mirror()
	LAFieldLithostaticSeed.shape_atmosphere(_f, LAMaterialField3D.INITIAL_TEMP, _f._body_measure, g_solved)
	var p_marched: PackedFloat32Array = LAFieldLithostaticSeed.compress(_f, g_solved)
	LAFieldEnthalpySeed.seed(_f, LAMaterialField3D.INITIAL_TEMP)
	if _f._gpu != null:                                # hand the device what those walks produced
		_f._gpu._seed_regolith()                       # permeability mask + grain size
		_f._gpu._seed("porosity", _f._porosity)        # Athy pore fraction
		# The march's own pressure, so the first state derive reads the world at it rather than at zero,
		# where every condensed phase would be asked to boil.
		_f._gpu._seed("pressure", p_marched)
		# Every matter channel, not a hand-written subset: the balance march touched all of them.
		for name in LAFieldCellMass3D.mirror_names(_f):
			_f._gpu.seed_field(String(name), _f.get("_" + String(name)), _f._seal)
		_f._gpu.mark_h_dirty()
	_f._gravity.solve_seed()      # the ocean just landed: relax the potential over the WHOLE seeded mass
	if _f._gpu != null:
		_f._gpu.derive_seeded()   # the world's own celerity, before the first step is budgeted against it
	return true


## ONE step: SIM_SECONDS_PER_STEP of simulated time. Every per-step term happens once here, so a
## step's books cannot be split across a frame boundary.
func step() -> void:
	if not _f._ready_sim or not _f._use_gpu:
		return
	# Refresh the body rotation FIRST: everything below that converts a position or a direction reads it.
	_f.sync_body_frame()
	var t0: int = Time.get_ticks_usec()
	var t_begin: int = t0
	_f._gpu.begin_frame(_f._h, _f._h2o)      # drains prev step (sync+readback) + uploads
	LASimReport.gauge("field_begin_ms", float(Time.get_ticks_usec() - t_begin) / 1000.0)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	if _f._sun_light != null and _f._gpu.has_method("set_sun_flux") \
			and _f._sun_light.has_meta("irradiance_w_m2"):
		# The MAGNITUDE of sun_dir is the irradiance in W/m^2, straight off the star's luminosity and the
		# separation the integrator produced. A light with no irradiance meta is a light nobody has placed
		# in a system yet, and an unlit field is dark rather than lit by an assumed sun.
		var irr: float = float(_f._sun_light.get_meta("irradiance_w_m2"))
		var xuv: float = float(_f._sun_light.get_meta("xuv_w_m2", 0.0))
		_f._gpu.set_sun_flux(_f.dir_to_field(_f._sun_light.global_transform.basis.z * irr), xuv)
	if _f._gpu.has_method("set_sea_radius"):
		_f._gpu.set_sea_radius(_f.sea_radius())
	# The transport substep budget reads last step's drained maxima; before the first drain the field
	# is the seed, whose hottest cell is the declared seed temperature.
	if _f._gpu.has_method("set_cfl_inputs") and _f._queries != null:
		_f._gpu.set_cfl_inputs(_cfl_maxima())
	if _f._inject != null and not _f._inject.queue.is_empty():
		if _armed("LA_INJECT_AUDIT"):
			# Diagnostic.
			_f._inject.queue.audit_rewind(_f._gpu, "h2o", _f._h2o)
		_f._inject.queue.flush(_f._gpu)
	# Boundary face-state record/replay: samples at the drain, feeds REPLAY tails before the dispatch.
	if _f._capture != null:
		_f._capture.pre_step()
	var t_step: int = Time.get_ticks_usec()
	if _probe != null:
		_probe.pre_step()             # arm/disarm the driver's between-pass probe for THIS step
		_f._gpu.step()
		_probe.post_step()            # print the per-pass budget (no-op on unsampled steps)
	else:
		_f._gpu.step()
	LASimReport.gauge("field_dispatch_ms", float(Time.get_ticks_usec() - t_step) / 1000.0)
	var res: Dictionary = _f._gpu.end_frame()
	var t_post: int = Time.get_ticks_usec()
	_apply_readback(res)
	# Seal on the field clock, never the report clock. The seal takes only its own legs.
	if _f._seal != null and _f._gpu.has_method("take_probe"):
		_f._seal.poll(_f._gpu.take_probe(LAMaterialFieldSeal3D.required_channels()))
	# The ledgers fold this step's drained books here, never on the report clock.
	if _f._report_mod != null:
		_f._report_mod.sample_ledgers()
	# Charge module reads the strike list the breakdown kernel published and fires the bolt visuals.
	if _f._charge_mod != null:
		_f._charge_mod.post_step()
	if _f._stamp != null:
		_f._stamp.maybe_scan()                       # stamp solid-flag crossings into the SDF (gated)
	LASimReport.gauge("field_post_ms", float(Time.get_ticks_usec() - t_post) / 1000.0)   # scatter + CPU post-passes
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t0) / 1000.0)
	LASimReport.event("field_step")   # telemetry: GPU field steps per run
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
	if res.has("silicate") and res["silicate"].size() == n: _f._silicate = res["silicate"]
	if res.has("porosity") and res["porosity"].size() == n: _f._porosity = res["porosity"]
	if res.has("fire") and res["fire"].size() == n: _f._fire = res["fire"]
	if res.has("fuel") and res["fuel"].size() == n: _f._fuel = res["fuel"]
	if res.has("fert") and res["fert"].size() == n: _f._fert = res["fert"]
	if res.has("o2") and res["o2"].size() == n: _f._o2 = res["o2"]
	if res.has("co2") and res["co2"].size() == n: _f._co2 = res["co2"]
	if res.has("biomass") and res["biomass"].size() == n: _f._biomass = res["biomass"]

	if res.has("cement") and res["cement"].size() == n: _f._cement = res["cement"]
	if res.has("silicate_melt") and res["silicate_melt"].size() == n: _f._silicate_melt = res["silicate_melt"]
	if res.has("silicate_bed") and res["silicate_bed"].size() == n: _f._silicate_bed = res["silicate_bed"]
	if res.has("silicate_susp_air") and res["silicate_susp_air"].size() == n:
		_f._silicate_susp_air = res["silicate_susp_air"]
	if res.has("silicate_susp_water") and res["silicate_susp_water"].size() == n:
		_f._silicate_susp_water = res["silicate_susp_water"]
	# Substrate-foundation channels: shock (tremor/impact), charge (bolt breakdown), and the emergent WIND
	# velocity field (wind3_at/wind_at read a real force instead of ZERO).
	if res.has("shock") and res["shock"].size() == n: _f._shock = res["shock"]
	if res.has("charge") and res["charge"].size() == n: _f._charge = res["charge"]
	if res.has("vel_x") and res["vel_x"].size() == n: _f._vel_x = res["vel_x"]
	if res.has("vel_y") and res["vel_y"].size() == n: _f._vel_y = res["vel_y"]
	if res.has("vel_z") and res["vel_z"].size() == n: _f._vel_z = res["vel_z"]
	if res.has("pressure") and res["pressure"].size() == n: _f._pressure = res["pressure"]
	if res.has("detritus") and res["detritus"].size() == n: _f._detritus = res["detritus"]
	if res.has("fungus") and res["fungus"].size() == n: _f._fungus = res["fungus"]


## The drained maxima the substep budget reads. An unreduced row is ABSENT; one that reduced to a
## non-number is reported and left absent, never passed on as a permissive zero.
func _cfl_maxima() -> Dictionary:
	var out: Dictionary = {}
	for pair: Array in [["cfl_speed_max", "wind_speed_max"], ["cfl_temp_max_k", "all_temp_max"],
			["cfl_celerity_max", "celerity_max"]]:
		var key: String = String(pair[1])
		if not _f._queries.has_row(key):
			continue
		var v: float = _f._queries.row_f(key)
		if not is_finite(v):
			push_error("LAMaterialField3D: %s reduced to %f, so every reading after it is fiction." % [key, v])
			continue
		out[String(pair[0])] = v + (LAPhysical.KELVIN_OFFSET if key == "all_temp_max" else 0.0)
	var g: float = _f._gravity.mean_g() if _f._gravity != null else NAN
	if is_finite(g):
		out["cfl_mean_g"] = g
	return out
