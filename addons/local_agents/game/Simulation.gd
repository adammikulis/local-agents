class_name LASimulation
extends Node3D


const STAR_POSITION: Vector3 = Vector3(900.0, 320.0, 620.0)

@onready var _settings_applier: LAVoxelSettingsApplier = $SettingsApplier
@onready var _loop: LASimLoop = $SimLoop
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
@onready var _impacts: LAMeteorImpacts = $MeteorImpacts
@onready var _markers: LAPhenomenaMarkers = $PhenomenaMarkers
@onready var _spawn: LAVoxelSpawnController = $SpawnController
@onready var _save: LAWorldSaveController = $WorldSaveController
@onready var _timeline: LAVoxelTimeline = $Timeline

var _terrain = null
var _actors_root: Node3D = null

# Harness probe flags, set once from the CLI. They gate the spawn probe, not any physics.
var _auto_meteor: bool = false
var _auto_select: bool = false
var _overview: bool = false
var _farview: bool = false


## Wire the world. `opts` carries the planet's shape.
func build(opts: Dictionary) -> void:
	_settings_applier.read_settings()

	_star.setup({"position": STAR_POSITION, "energy": 1.4})

	_body.setup(opts.get("planet", {}))
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	# Streaming must not depend on the camera: the field samples the SDF godot_voxel streams.
	_terrain_viewer.global_position = _body.center()
	_body.attach_viewer(_terrain_viewer, false)

	_ecology.set_llm_service(_llm_service)
	_ecology.setup(_terrain, _actors_root)

	_build_field()

	if OS.has_environment("LA_NO_EVENT_TRACKER"):
		_events.queue_free()
		_events = null
	else:
		_events.setup(self)

	_build_system()
	_build_geology_and_life()
	_save.setup(self)
	_timeline.setup(_save)
	_wire_loop()


## THE ONE DRIVER. Everything that advances subscribes to the loop; nothing subscribes to a frame.
func _wire_loop() -> void:
	# The world is being SEEDED until the field has its sea, its regolith and its GPU driver. No simulated
	# time passes while that is true.
	_loop.hold()
	_loop.seeding.connect(_on_seeding)
	_loop.stepped.connect(_on_step)
	_loop.stepped.connect(Callable(_ecology, "on_sim_step"))
	_loop.stepped.connect(Callable(_material.step_driver(), "step").unbind(1))


func _on_seeding(_tick: int) -> void:
	if _material.step_driver().seed_tick():
		_loop.release()


func _build_field() -> void:
	# METRES: LAFieldGravity solves Poisson in SI on this grid.
	var extent_m: float = float(_body.radius()) + LocalAgentSimWorld.MODELLED_ATMOSPHERE_HEIGHT_M
	var cells: int = maxi(_settings_applier.grid_cells_per_edge(), 1)
	_material.setup_body(_body.center(), extent_m, 2.0 * extent_m / float(cells), _terrain)
	_validate_grid(_material._grid)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()
	LASimReport.register(Callable(_material, "report"))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.population(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.cognition(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.disease(self))
	# The STAR's light, never the sky cycle's: direction from its basis, intensity from `insolation`.
	_material.set_sun(_star.light())
	_material.set_body(_body)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)


## Slot-opposite reciprocity, the contract every gather kernel depends on. Fatal if it fails.
func _validate_grid(grid: LAVoxelGrid) -> void:
	var v: Dictionary = grid.validate()
	LASimReport.register(func() -> Dictionary: return {
		"grid_valid": bool(v.get("ok", false)),
		"grid_non_reciprocal": int(v.get("non_reciprocal", -1)),
		"grid_boundary_faces": int(v.get("boundary_faces", -1)),
	})
	if not bool(v.get("ok", false)):
		print("GRID_INVALID=", JSON.stringify(v))
		push_error("LAVoxelGrid.validate() failed: %s" % JSON.stringify(v))


func _build_system() -> void:
	_orbits.setup(_body, _star, _material)
	_orbits.set_moon(_moon)
	LASimReport.register(Callable(_orbits, "report"))


func _build_geology_and_life() -> void:
	# The camera + audio are rendering, injected by those layers when they exist.
	_impacts.setup(self, _terrain, _ecology, _actors_root, null)

	_markers.setup(_material)
	if _material.has_method("set_lightning_visual"):
		_material.set_lightning_visual(Callable(_markers, "show_bolt"))

	_spawn.setup(self, _body, _terrain, _ecology, null, _material, null)
	_spawn.set_spawn_scale(_settings_applier.spawn_scale())


## The CLI probe flags, set once. They arm harness hooks; nothing physical reads them.
func set_probe_flags(overview: bool, farview: bool, auto_meteor: bool, auto_select: bool) -> void:
	_overview = overview
	_farview = farview
	_auto_meteor = auto_meteor
	_auto_select = auto_select


## ONE simulated step: the clock, the orbit, the spin and the spawn probe. `dt` is a fixed quantum of
## SIMULATED seconds, so the orbit and the rotation advance by real physics rather than by a frame period.
func _on_step(_step: int) -> void:
	var dt: float = LAMaterialFieldSphereStep3D.SIM_SECONDS_PER_STEP
	_clock.advance()
	_orbits.update(dt)
	# The sun's world direction, published to ecology so night is a place on the sphere rather than a clock.
	if _ecology.has_method("set_sun"):
		var centre: Vector3 = _body.center()
		_ecology.set_sun((_star.global_position - centre).normalized(), centre)
	if _spawn.is_spawned() and _terrain.is_planet():
		_body.rotate(_body.spin_axis(), LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S * dt)
	_spawn.try_spawn(_overview, _farview, _auto_meteor, _auto_select)


func settings_applier() -> LAVoxelSettingsApplier: return _settings_applier
func loop() -> LASimLoop: return _loop
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
func meteor_impacts() -> LAMeteorImpacts: return _impacts
func phenomena_markers() -> LAPhenomenaMarkers: return _markers
func spawn_controller() -> LAVoxelSpawnController: return _spawn
func save_controller() -> LAWorldSaveController: return _save
func timeline() -> LAVoxelTimeline: return _timeline
func llm_service() -> Node: return _llm_service
func is_spawned() -> bool: return _spawn != null and _spawn.is_spawned()
