class_name LAMaterialFieldSphereStep3D
extends RefCounted

## ONE field step per call. LASimLoop drives it; nothing here reads a frame delta or banks time.

# Simulated seconds ONE field step represents. Gated by scripts/check_step_quantum.sh.
const SIM_SECONDS_PER_STEP: float = 43.2


const MineralProfileScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd")
const AttributionScript: GDScript = preload("res://addons/local_agents/sim/material/FieldPassAttribution3D.gd")
const ElementProbeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementProbe3D.gd")
const PassProbeScript: GDScript = preload("res://addons/local_agents/runtime/FieldPassProbe3D.gd")
const SnapshotScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

## The pass that solves the potential. Without it this world has no vertical, so the walks that read one
## do not run at all rather than reading a flat field.
const GRAVITY_PASS: String = "GravityPass.gd"

const FILL_META: StringName = &"field_fill"

var _f = null                                          # back-reference to the owning LAMaterialField3D
var _mineral_profile = null                            # holds the SIM_REPORT provider it registered
# The driver's ONE between-pass probe.
var _probe = null
var _seed_job = null
var _seed_bake: String = ""
var _sealed_full_steps: int = 0


## Full steps run since the seal. A snapshot or a cache keyed on it is stale only when it moved.
func full_steps() -> int:
	return _sealed_full_steps


## Field steps per whole step a resting world still takes, so the books the audit folds are a reading of
## the world, and a pass that writes while declaring no writer is caught.
const REST_AUDIT_EVERY: int = 64


## A sealed world with no writer this step is unchanged, so nothing is dispatched or read back. A thrown
## switch is a writer event, so a resting world takes a full step under the process set it now has.
func _at_rest(sim_step: int, switched: bool) -> bool:
	return not switched and sim_step % REST_AUDIT_EVERY != 0 \
		and _sealed_full_steps > 0 and _f._seal != null and _f._seal.sealed() and _f._capture == null \
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
## Returns true when the world is ready and no simulated time has passed yet. A walk the device refused a
## piece of ends the seed: no walk after it runs, nothing is baked, and the run fails.
func seed_tick() -> bool:
	if _f._ready_sim:
		return true
	if _seed_job != null:
		if _seed_job.failed():
			LASimLoop.active().fail("SEED_FAILED")
			return false
		if not _seed_job.complete(_f, LAProcessSet.has_record("pass", GRAVITY_PASS)):
			return false
		_store_seeded(_seed_bake)
		return true
	var fill: Variant = _f.get_meta(FILL_META, {})
	if not LAFieldFill.valid_spec(fill):
		LASimLoop.active().fail("SEED_GAS_FILL_INVALID")
		return false
	if fill.is_empty():
		if _f._terrain == null or not _f._terrain.has_method("is_solid"):
			LASimLoop.active().fail("SEED_MATTER_ABSENT")
			return false
	elif not LAFieldFill.lay_gas(_f, fill["mole_fractions"], LABodySeeds.surface_temp_c(), fill["pressure_pa"]):
		LASimLoop.active().fail("SEED_GAS_FILL_FAILED")
		return false
	# The gas fill and the terrain both feed the same asynchronous seed job.
	_f.activate()                 # builds the GPU driver, which owns the solve the walks below read
	var g: LAVoxelGrid = _f._grid
	var bake: String = LAFieldStateCache.state_key(OS.get_environment("LA_SEAL_KEY"),
			g.nx, g.ny, g.nz, g.cell_size, g.origin)
	if bake != "" and not fill.is_empty():
		bake = LAFieldFill.cache_key(bake, fill, LABodySeeds.surface_temp_c())
	var loaded: bool = OS.get_environment("LA_SEAL_RESEED") == "" and _load_seeded(bake)
	if _f._gpu.refused("the seed"):
		return false
	if loaded:
		_f._ready_sim = true
		return true
	if fill.is_empty() and LAProcessSet.has_record("pass", GRAVITY_PASS) and not LAFieldSeedJob3D.prepare_gravity(_f):
		LASimLoop.active().fail("SEED_GRAVITY_FAILED")
		return false
	# THE WORLD PUT INTO THE BALANCE THE STEPPER HOLDS: a locked cell's rock under the column over it, an
	# open cell at the pressure its own amounts state.
	_f._gpu.derive_seeded()
	if _f._gpu.refused("the seed"):
		return false
	var g_rest: PackedFloat32Array = _f._gpu.read_raw("g_rest").slice(0, _f._cell_count * 3)   # cells, not ghosts
	# The barometric profile is a function of the SOLVED POTENTIAL, so the solve's own phi goes with it,
	# and the water stands under the air that law lays.
	_seed_bake = bake
	_seed_job = LAFieldSeedJob3D.new()
	if not _seed_job.begin(_f, g_rest, fill.is_empty() and LAProcessSet.has_record("pass", GRAVITY_PASS)):
		LASimLoop.active().fail("SEED_WORKER_START_FAILED")
	return false


## The walks below this line are a pure function of the terrain, the box and the process set, so a run
## whose key names a bake reads the world they produced instead of producing it again. The seal's own
## manifest is not stored: it is what the ledgers read off this state, so it comes back with the state.
func _load_seeded(k: String) -> bool:
	if k == "" or _f._gpu == null or not SnapshotScript.device_ready(_f):
		return false
	var data: Dictionary = LAFieldStateCache.load_state(k, _f._cell_count)
	if data.is_empty() or not SnapshotScript.seed_from_bytes(_f, data.get("snapshot", PackedByteArray())):
		return false
	# The soil injector is the one CPU reader left of a seeded mirror; porosity and grain are read only
	# by the uploads this path skips, and they come back with the channels.
	_f._regolith = data.get("regolith", PackedByteArray())
	if _f._seal != null:
		_f._seal.restore(data.get("created", {}))
	return LAFieldSeedJob3D.finish_restore(_f, LAProcessSet.has_record("pass", GRAVITY_PASS))


func _store_seeded(k: String) -> void:
	if k == "" or not SnapshotScript.is_ready(_f):
		return
	var data: Dictionary = {"cell_count": _f._cell_count, "snapshot": SnapshotScript.to_bytes(_f)}
	if (data["snapshot"] as PackedByteArray).is_empty():
		return
	data["regolith"] = _f._regolith
	data["created"] = _f._seal.report().get("world_created", {}) if _f._seal != null else {}
	LAFieldStateCache.save_state(k, data)


## ONE step: SIM_SECONDS_PER_STEP of simulated time, at LASimLoop's `sim_step`, resting or not. Every
## per-step term happens once here, so a step's books cannot be split across a frame boundary.
func step(sim_step: int) -> void:
	if not _f._ready_sim:
		return
	_f._gpu._step_index = sim_step
	# Refresh the body rotation FIRST: everything below that converts a position or a direction reads it.
	_f.sync_body_frame()
	LASimReport.gauge("field_cells", float(_f._gpu._cc))
	# `--ablate=name@step` lands on this clock.
	if _at_rest(sim_step, LAAblate.step_switches(sim_step)):
		var t_rest: int = Time.get_ticks_usec()
		LASimReport.event("field_rest")
		if _f._gpu._pending:              # the last moving step's readback and books, drained once
			_f._gpu.begin_frame()
			if _f._report_mod != null:
				_f._report_mod.sample_ledgers()
		_f._gpu.republish_latest()
		LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t_rest) / 1000.0)
		LASimReport.event("field_step")   # telemetry: field steps completed, moving or at rest
		return
	var t0: int = Time.get_ticks_usec()
	var t_begin: int = t0
	_f._gpu.begin_frame()                    # drains prev step (sync + readback into the mirrors) + uploads
	if LAProcessSet.has_record("pass", GRAVITY_PASS):
		_f._gravity.solve_step(sim_step)   # the potential of the mass that moved, converged; the device is idle here
	LASimReport.gauge("field_begin_ms", float(Time.get_ticks_usec() - t_begin) / 1000.0)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	if _f._star != null:
		# The MAGNITUDE of sun_dir is the irradiance in W/m^2, straight off the star's luminosity and the
		# separation the integrator produced. A field with no star is dark rather than lit by an assumed sun.
		var c: Vector3 = _f.centre()
		var to_star: Vector3 = (_f._star.global_position - c).normalized()
		_f._gpu.set_sun_flux(_f.dir_to_field(to_star * _f._star.irradiance_at(c)), _f._star.xuv_irradiance_at(c))
	_f._gpu.set_sea_radius(_f.sea_radius())
	if _f._inject != null and not _f._inject.queue.is_empty():
		_f._inject.queue.flush(_f._gpu)
	# Boundary face-state record/replay on the loop's step: reads or feeds the state this step starts from.
	if _f._capture != null:
		_f._capture.pre_step(sim_step)
	var t_step: int = Time.get_ticks_usec()
	var submitted: bool = false
	if _probe != null:
		_probe.pre_step()             # arm/disarm the driver's between-pass probe for THIS step
		submitted = _f._gpu.step()
		_probe.post_step()            # print the per-pass budget (no-op on unsampled steps)
	else:
		submitted = _f._gpu.step()
	LASimReport.gauge("field_dispatch_ms", float(Time.get_ticks_usec() - t_step) / 1000.0)
	if not submitted:
		return
	var t_post: int = Time.get_ticks_usec()
	# Seal on the field clock, never the report clock. The seal takes only its own legs.
	if _f._seal != null:
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
	LASimReport.event("field_step")
	if _f._seal != null and _f._seal.sealed():
		_sealed_full_steps += 1
