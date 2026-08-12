class_name LASimulation
extends Node3D


const STAR_POSITION: Vector3 = Vector3(900.0, 320.0, 620.0)

# How much of the body the field models, metres: a shell straddling the surface. The radial resolution
# follows from this and the shell count, rather than from a multiple of a radius nobody believed in.
const MODELLED_CRUST_DEPTH_M: float = 2.7e4
const MODELLED_ATMOSPHERE_HEIGHT_M: float = 2.7e4
const MODELLED_SPAN_M: float = MODELLED_CRUST_DEPTH_M + MODELLED_ATMOSPHERE_HEIGHT_M

@onready var _settings_applier: LAVoxelSettingsApplier = $SettingsApplier
@onready var _clock: LASimClock = $SimClock
@onready var _time: LASimTimeAuthority = $TimeAuthority
@onready var _star: LAStar = $Star
@onready var _body: Node3D = $PlanetBody
@onready var _terrain_viewer: Node3D = $TerrainViewer
@onready var _llm_service: Node = $LlmService
@onready var _ecology: Node = $Ecology
@onready var _material: Node = $MaterialField
@onready var _events: Node = $EventTracker
@onready var _moon: LAMoon = $Moon
@onready var _orbits: LASystemOrbits = $SystemOrbits
@onready var _disasters: Node = $Disasters
@onready var _governor: Node = $PopulationGovernor
@onready var _tectonics: LAPlateTectonics = $PlateTectonics
@onready var _spawn: LAVoxelSpawnController = $SpawnController
@onready var _save: LAWorldSaveController = $WorldSaveController
@onready var _timeline: LAVoxelTimeline = $Timeline

var _terrain = null
var _actors_root: Node3D = null


## Wire the world. `opts` carries the planet's shape (LAVoxelWorld's PLANET_* constants) and the
## cmdline-derived knobs the sim needs: fast_multiplier.
func build(opts: Dictionary) -> void:
	_settings_applier.read_settings()

	_time.set_multiplier(float(opts.get("fast_multiplier", 1)))

	# The star: position, gravity, and the light whose basis + `insolation` meta ARE the field's solar input.
	_star.setup({"position": STAR_POSITION, "energy": 1.4})

	_body.setup(opts.get("planet", {}))
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	# Data-only viewer: godot_voxel streams only around a VoxelViewer, and the field samples that SDF, so
	# streaming must not depend on the camera.
	_terrain_viewer.global_position = _body.center()
	_body.attach_viewer(_terrain_viewer, false)

	_ecology.set_llm_service(_llm_service)
	_ecology.setup(_terrain, _actors_root)

	_build_field()

	# The ONE emergent phenomenon-event source: watches the field aggregates and emits typed events
	# (eruption/wildfire/flood/storm/lightning/impact) that telemetry and the streamer consume.
	if OS.has_environment("LA_NO_EVENT_TRACKER"):
		_events.queue_free()
		_events = null
	else:
		_events.setup(self)

	_build_system()
	_build_geology_and_life()
	_save.setup(self)
	_timeline.setup(_save)


func _build_field() -> void:
	var field_grid: RefCounted = LASphereGrid.new()
	var depth: int = _settings_applier.grid_depth()
	# The modelled shell, in METRES: it straddles the surface, with the interior below standing in as the
	# geotherm reservoir. Declared granularity — see docs/MODEL_PARAMETERS.md.
	var mean_dr: float = MODELLED_SPAN_M / float(maxi(depth, 1))
	var core_r: float = float(_body.radius()) - MODELLED_CRUST_DEPTH_M
	# Surface shell = the one holding the sea, so a graded profile puts its fine cells where the ground is.
	var surf_shell: int = clampi(int((_terrain.sea_radius() - core_r) / mean_dr), 0, depth - 1)
	field_grid.build(_settings_applier.grid_res_per_face(), depth, core_r, mean_dr, _body.center(),
		LASphereGridProfiles.from_env(depth, mean_dr, surf_shell))
	_validate_grid(field_grid)
	_material.setup_sphere(field_grid, _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	LASimReport.register(Callable(_material, "report"))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.population(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.cognition(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.disease(self))
	# The field's solar forcing reads the STAR's light — direction from its basis, intensity from the
	# `insolation` meta SystemOrbits stamps on it. Never a light owned by the sky cycle, which is rendering.
	_material.set_sun(_star.light())
	_material.set_body(_body)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)


## Slot-opposite reciprocity, the contract every gather kernel depends on. Fatal if it fails.
func _validate_grid(grid: RefCounted) -> void:
	if not grid.has_method("validate"):
		return
	var v: Dictionary = grid.validate()
	LASimReport.register(func() -> Dictionary: return {
		"grid_valid": bool(v.get("ok", false)),
		"grid_non_reciprocal": int(v.get("non_reciprocal", -1)),
		"grid_lateral_bends": int(v.get("lateral_bends", -1)),
	})
	if not bool(v.get("ok", false)):
		print("GRID_INVALID=", JSON.stringify(v))
		push_error("LASphereGrid.validate() failed: %s" % JSON.stringify(v))


func _build_system() -> void:
	# The sky controller is rendering and may never exist; LARenderLayer binds it later if it does.
	_orbits.setup(_body, _star, _material)
	_orbits.set_moon(_moon)
	LASimReport.register(Callable(_orbits, "report"))


func _build_geology_and_life() -> void:
	# Disasters seed real matter/energy into the field; the camera + audio they also accept are rendering
	# and UI, injected by those layers when they exist.
	_disasters.setup(self, _terrain, _ecology, _actors_root, null, null)
	if _material.has_method("set_lightning_visual"):
		_material.set_lightning_visual(Callable(_disasters, "spawn_lightning"))

	# Watches the animal count and, when it overflows the frame budget, seeds an emergent culling flood at
	# the densest herd — the cull emerges from the flood, no scripted deaths.
	_governor.setup(_ecology, _terrain, _actors_root)

	# Drifting plates that CARRY THE CRUST (the field advects rock_fill/sediment with their velocity) and
	# whose boundaries seed volcanoes/earthquakes.
	_tectonics.setup(_terrain, _disasters, _material)

	_spawn.setup(self, _body, _terrain, _ecology, null, _material, null, _disasters)
	_spawn.set_spawn_scale(_settings_applier.spawn_scale())


## Advance the orbit, the spin and the spawn probe. Called from the world root's _process.
func step(delta: float, overview: bool, farview: bool, auto_meteor: bool, auto_select: bool) -> void:
	_orbits.update(delta)
	# The sun's world direction, published to ecology so night is a place on the sphere rather than a clock.
	if _ecology.has_method("set_sun"):
		var centre: Vector3 = _body.center()
		_ecology.set_sun((_star.global_position - centre).normalized(), centre)
	if _spawn.is_spawned() and _terrain.is_planet():
		_body.rotate(_body.spin_axis(), LASimClock.SPIN_RAD_PER_SIM_S * delta)
	_spawn.try_spawn(overview, farview, auto_meteor, auto_select)


func settings_applier() -> LAVoxelSettingsApplier: return _settings_applier
func clock() -> LASimClock: return _clock
func time_authority() -> LASimTimeAuthority: return _time
func star() -> LAStar: return _star
func body() -> Node3D: return _body
func terrain(): return _terrain
func actors_root() -> Node3D: return _actors_root
func ecology() -> Node: return _ecology
func material_field() -> Node: return _material
func moon() -> LAMoon: return _moon
func orbits() -> LASystemOrbits: return _orbits
func disasters() -> Node: return _disasters
func spawn_controller() -> LAVoxelSpawnController: return _spawn
func save_controller() -> LAWorldSaveController: return _save
func timeline() -> LAVoxelTimeline: return _timeline
func llm_service() -> Node: return _llm_service
func is_spawned() -> bool: return _spawn != null and _spawn.is_spawned()
