class_name LAMaterialFieldSphereStep3D
extends RefCounted

## ONE field step per call. LASimLoop drives it; nothing here reads a frame delta or banks time.

# Simulated seconds ONE field step represents. Gated by scripts/check_step_quantum.sh.
const SIM_SECONDS_PER_STEP: float = 43.2

static func real_seconds_per_step() -> float:
	return SIM_SECONDS_PER_STEP


const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const AttributionScript: GDScript = preload("res://addons/local_agents/sim/material/FieldPassAttribution3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")
const PassProbeScript: GDScript = preload("res://addons/local_agents/runtime/FieldPassProbe3D.gd")
const SnapshotScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

## The pass that solves the potential. Without it this world has no vertical, so the walks that read one
## do not run at all rather than reading a flat field.
const GRAVITY_PASS: String = "GravityPass.gd"

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
	_f.activate()                 # builds the GPU driver, which owns the solve the walks below read
	var g: LAVoxelGrid = _f._grid
	var bake: String = LAFieldStateCache.state_key(OS.get_environment("LA_SEAL_KEY"),
			g.nx, g.ny, g.nz, g.cell_size, g.origin)
	if _load_seeded(bake):
		return true
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_seed_under_gravity()
	# THE WORLD PUT INTO THE BALANCE THE STEPPER HOLDS. Only the hydrostatic rung stands a column;
	# below it a cell stands at the pressure its own amounts state.
	_f._gpu.derive_seeded()   # publishes g_rest as geometry: gravitation and this frame's own spin
	var g_solved: PackedFloat32Array = LAFieldLithostaticSeed.vertical(_f, _f._gpu.read_raw("g_rest"))
	# The barometric profile is a function of the SOLVED POTENTIAL, so the solve's own phi goes with it.
	LAFieldLithostaticSeed.shape_atmosphere(_f, LAMaterialField3D.INITIAL_TEMP, _f._body_measure,
		g_solved, _f._gpu.read_raw("grav_phi"))
	var p_marched: PackedFloat32Array = LAFieldLithostaticSeed.compress(_f, g_solved)
	LAFieldEnthalpySeed.seed(_f, LAFieldGeothermSeed.profile(_f, LAMaterialField3D.INITIAL_TEMP), p_marched)
	# WEIGH THE BODY once the march has compressed the rock it stands on.
	_f._body_measure.measure(_f, LABodySeeds.spin_axis_of(_f._body_key))
	if _f._gpu != null:                                # hand the device what those walks produced
		_f._gpu._seed_regolith()                       # permeability mask + grain size
		_f._gpu._seed("porosity", _f._porosity)        # Athy pore fraction
		# The march's own pressure, so the first state derive reads the world at it rather than at zero,
		# where every condensed phase would be asked to boil.
		_f._gpu._seed("pressure", p_marched)
		_f._gpu._seed("h_j_m3", _f._h)
		# Every matter channel, not a hand-written subset: the balance march touched all of them.
		for name in LAFieldCellMass3D.mirror_names(_f):
			_f._gpu.seed_field(String(name), _f.get("_" + String(name)), _f._seal)
		_f._gpu.mark_h_dirty()
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve()  # the ocean just landed: relax the potential over the WHOLE seeded mass
	if _f._gpu != null:
		_f._gpu.derive_seeded()   # the world's own bulk state, before the first step is budgeted on it
	_store_seeded(bake)
	return true


## The walks below this line are a pure function of the terrain, the box and the process set, so a run
## whose key names a bake reads the world they produced instead of producing it again. The seal's own
## manifest is not stored: it is what the ledgers read off this state, so it comes back with the state.
func _load_seeded(k: String) -> bool:
	if k == "" or _f._gpu == null or not SnapshotScript.is_ready(_f):
		return false
	var data: Dictionary = LAFieldStateCache.load_state(k, _f._cell_count)
	if data.is_empty() or not SnapshotScript.restore(_f, data):
		return false
	# The soil injector is the one CPU reader left of a seeded mirror; porosity and grain are read only
	# by the uploads this path skips, and they come back with the channels.
	_f._regolith = data.get("regolith", PackedByteArray())
	if _f._seal != null:
		_f._seal.restore(data.get("created", {}))
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve()
	_f._gpu.derive_seeded()
	# The body is the matter it is made of, so a world that was LOADED is weighed like one that was walked.
	_f._body_measure.measure(_f, LABodySeeds.spin_axis_of(_f._body_key))
	return true


func _store_seeded(k: String) -> void:
	if k == "" or not SnapshotScript.is_ready(_f):
		return
	var data: Dictionary = SnapshotScript.capture(_f)
	if data.is_empty():
		return
	data["regolith"] = _f._regolith
	data["created"] = _f._seal.report().get("world_created", {}) if _f._seal != null else {}
	LAFieldStateCache.save_state(k, data)


## The seed steps that need a vertical, and so need the solve. A world with no gravity solve has no
## "below": no water table, no basins to flood, and no gas for water to displace out of.
func _seed_under_gravity() -> void:
	_f._gravity.solve()      # g FIRST: every "below"/"above" below here is a slot chosen from it
	_f._compute_regolith()        # the permeable aquifer band (+ initial water table) for groundwater flow
	if not _f._regolith.has(1):
		push_error("The regolith walk marked no cell permeable, so every rock cell has zero porosity, the "
			+ "water table is unprimed and darcy_resistance() makes the groundwater row inert. The walk "
			+ "reads `below` from solved gravity: it ran before the solve was dispatched and drained.")
	LAFieldHydrosphereSeed.seed(_f)   # the body's own water, priority-flooded into its basins
	# The water landed in already-seeded cells: displace the gas it occupies.
	LAFieldLithostaticSeed.displace_gas_from_water(_f)


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
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve_step(_f._gpu._step_index)   # the potential of the mass that moved, converged; the device is idle here
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


## Channel -> the CPU mirror it refreshes. The three DERIVED h2o shares are recomputed by
## StateDerivePass every step, never conserved and never uploaded; `vel_*` is the emergent wind
## field that wind3_at reads.
const MIRRORS: Dictionary = {
	"h_j_m3": "_h", "temp": "_temp", "h2o": "_h2o", "h2o_solid": "_h2o_solid",
	"h2o_liquid": "_h2o_liquid", "h2o_vapour": "_h2o_vapour", "silicate": "_silicate",
	"porosity": "_porosity", "fire": "_fire", "fuel": "_fuel", "fert": "_fert", "o2": "_o2",
	"co2": "_co2", "biomass": "_biomass", "cement": "_cement", "silicate_melt": "_silicate_melt",
	"silicate_bed": "_silicate_bed", "silicate_susp_air": "_silicate_susp_air",
	"silicate_susp_water": "_silicate_susp_water", "shock": "_shock", "charge": "_charge",
	"vel_x": "_vel_x", "vel_y": "_vel_y", "vel_z": "_vel_z", "pressure": "_pressure",
	"detritus": "_detritus", "fungus": "_fungus"}


func _apply_readback(res: Dictionary) -> void:
	var n: int = _f._cell_count
	for key: String in MIRRORS:
		if res.has(key) and res[key].size() == n:
			_f.set(String(MIRRORS[key]), res[key])
	_f._atmos_dirty = true          # new h2o/temp -> invalidate the cached condensate aggregates
