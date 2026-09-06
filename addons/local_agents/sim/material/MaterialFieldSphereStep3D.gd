class_name LAMaterialFieldSphereStep3D
extends RefCounted

## ONE field step per call. LASimLoop drives it; nothing here reads a frame delta or banks time.

## The Courant number one field step may reach; generated.glsli emits it for the kernels.
const COURANT: float = 0.5
## Simulated seconds ONE field step represents, DERIVED from the state the step opens in. Zero in a
## world whose processes take no time at all. Gated by scripts/check_step_quantum.sh.
static var _dt_s: float = 0.0

static func seconds_per_step() -> float:
	return _dt_s

static func publish_step_seconds(dt: float) -> void:
	_dt_s = dt


const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const AttributionScript: GDScript = preload("res://addons/local_agents/sim/material/FieldPassAttribution3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")
const PassProbeScript: GDScript = preload("res://addons/local_agents/runtime/FieldPassProbe3D.gd")
const SnapshotScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

## The pass that solves the potential. Without it this world has no vertical, so the walks that read one
## do not run at all rather than reading a flat field.
const GRAVITY_PASS: String = "GravityPass.gd"

var _f = null                                          # back-reference to the owning LAMaterialField3D
var _mineral_profile = null                            # holds the SIM_REPORT provider it registered
# The driver's ONE between-pass probe.
var _probe = null
var _sealed_full_steps: int = 0


## Full steps run since the seal. A snapshot or a cache keyed on it is stale only when it moved.
func full_steps() -> int:
	return _sealed_full_steps


## A sealed world with no writer this step is unchanged, so nothing is dispatched or read back.
func _at_rest() -> bool:
	return _sealed_full_steps > 0 and _f._seal != null and _f._seal.sealed() and _f._capture == null \
		and not _f._gpu.state_moves() and (_f._inject == null or _f._inject.queue.is_empty()) \
		and not _f._gpu._step_probe.is_valid()


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
	if OS.get_environment("LA_SEAL_RESEED") == "" and _load_seeded(bake):
		return true
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_seed_under_gravity()
	# THE WORLD PUT INTO THE BALANCE THE STEPPER HOLDS. Only the hydrostatic rung stands a column;
	# below it a cell stands at the pressure its own amounts state.
	_f._gpu.derive_seeded()   # publishes g_rest as geometry: gravitation and this frame's own spin
	var g_solved: PackedFloat32Array = LAFieldLithostaticSeed.vertical(_f, _f._gpu.read_raw("g_rest"))
	# The barometric profile is a function of the SOLVED POTENTIAL, so the solve's own phi goes with it.
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		LAFieldLithostaticSeed.shape_atmosphere(_f, LABodySeeds.surface_temp_c(), g_solved, _f._gravity.phi_abs())
	var balance: Dictionary = LAFieldLithostaticSeed.compress(_f, g_solved, _f._t_rock)
	LAFieldEnthalpySeed.seed(_f, _f._t_rock, balance.get("fluid", PackedFloat32Array()), balance.get("rock", PackedFloat32Array()))
	# WEIGH THE BODY once the march has compressed the rock it stands on.
	_f._body_measure.measure(_f, LABodySeeds.spin_axis_of(_f._body_key))
	if _f._gpu != null:                                # hand the device what those walks produced
		_f._gpu._seed_regolith()                       # permeability mask, grain size, Athy porosity
		# The march's own pressure, so the first state derive reads the world at it rather than at zero,
		# where every condensed phase would be asked to boil.
		_f._gpu._seed("pressure", balance.get("pressure", PackedFloat32Array()))
		_f._gpu._seed("p_fluid", balance.get("fluid", PackedFloat32Array()))
		_f._gpu._upload_mirror("e_j_m3")
		_f._gpu._upload_mirror("e_lith_j_m3")
		# Every matter channel, not a hand-written subset: the balance march touched all of them.
		for name in LAFieldCellMass3D.mirror_names(_f):
			_f._gpu.seed_field(String(name), _f._seal)
		_f._gpu.mark_h_dirty()
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve()  # the ocean just landed: relax the potential over the WHOLE seeded mass
	if _f._gpu != null:
		_f._gpu.derive_seeded(true)   # the world's own bulk state, before the first step is budgeted on it
	_store_seeded(bake)
	return true


## The walks below this line are a pure function of the terrain, the box and the process set, so a run
## whose key names a bake reads the world they produced instead of producing it again. The seal's own
## manifest is not stored: it is what the ledgers read off this state, so it comes back with the state.
func _load_seeded(k: String) -> bool:
	if k == "" or _f._gpu == null or not SnapshotScript.is_ready(_f):
		return false
	var data: Dictionary = LAFieldStateCache.load_state(k, _f._cell_count)
	if data.is_empty() or not SnapshotScript.from_bytes(_f, data.get("snapshot", PackedByteArray())):
		return false
	# The soil injector is the one CPU reader left of a seeded mirror; porosity and grain are read only
	# by the uploads this path skips, and they come back with the channels.
	_f._regolith = data.get("regolith", PackedByteArray())
	if _f._seal != null:
		_f._seal.restore(data.get("created", {}))
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve()
	_f._gpu.derive_seeded(true)
	# The body is the matter it is made of, so a world that was LOADED is weighed like one that was walked.
	_f._body_measure.measure(_f, LABodySeeds.spin_axis_of(_f._body_key))
	return true


func _store_seeded(k: String) -> void:
	if k == "" or not SnapshotScript.is_ready(_f):
		return
	var data: Dictionary = {"cell_count": _f._cell_count, "snapshot": SnapshotScript.to_bytes(_f)}
	if (data["snapshot"] as PackedByteArray).is_empty():
		return
	data["regolith"] = _f._regolith
	data["created"] = _f._seal.report().get("world_created", {}) if _f._seal != null else {}
	LAFieldStateCache.save_state(k, data)


## The seed steps that need a vertical, and so need the solve. A world with no gravity solve has no
## "below": no water table, no basins to flood, and no gas for water to displace out of.
func _seed_under_gravity() -> void:
	_f._gravity.solve()      # g FIRST: every "below"/"above" below here is a slot chosen from it
	LAFieldCellMass3D.regolith(_f)   # the aquifer band and its porosity, walked in the GDExtension
	if not _f._regolith.has(1):
		push_error("The regolith walk marked no cell permeable, so every rock cell has zero porosity, the "
			+ "water table is unprimed and darcy_resistance() makes the groundwater row inert. The walk "
			+ "reads `below` from solved gravity: it ran before the solve was dispatched and drained.")
	LAFieldHydrosphereSeed.seed(_f)   # the body's own water, in its basins and its pores


## THE STEP THE BOX ITSELF AFFORDS, seconds: a body released from rest crosses the finest cell in
## sqrt(2 L / g), at the LARGEST g the field solved. 0 where nothing pulls, which FluxPass then reads
## as no bound of its own — and where transport exists, every cell states its own besides.
func _fall_step_seconds() -> float:
	var g: LAVoxelGrid = _f._grid
	var gm: float = LAGridGeometry.max_magnitude(_f._gravity.mirror()) if _f._gravity != null else 0.0
	var edge: float = 0.0 if g == null else g.cell_size * pow(0.5, float(g.max_level))
	return 0.0 if gm <= 0.0 or edge <= 0.0 else sqrt(2.0 * COURANT * edge / gm)


## ONE step: the derived quantum of simulated time. Every per-step term happens once here, so a
## step's books cannot be split across a frame boundary.
func step() -> void:
	if not _f._ready_sim or not _f._use_gpu:
		return
	publish_step_seconds(_fall_step_seconds())   # FluxPass takes the shorter of this and its cells'
	# Refresh the body rotation FIRST: everything below that converts a position or a direction reads it.
	_f.sync_body_frame()
	LASimReport.event("field_step")   # telemetry: field steps per run, moving or at rest
	LASimReport.gauge("field_cells", float(_f._gpu._cc))
	if _at_rest():
		var t_rest: int = Time.get_ticks_usec()
		LASimReport.event("field_rest")
		if _f._gpu._pending:              # the last moving step's readback and books, drained once
			_f._gpu.begin_frame()
			if _f._report_mod != null:
				_f._report_mod.sample_ledgers()
		_f._gpu.republish_latest()
		LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t_rest) / 1000.0)
		return
	var t0: int = Time.get_ticks_usec()
	var t_begin: int = t0
	_f._gpu.begin_frame()                    # drains prev step (sync + readback into the mirrors) + uploads
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
	var t_post: int = Time.get_ticks_usec()
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
	if _f._seal != null and _f._seal.sealed():
		_sealed_full_steps += 1
