class_name LASimulation
extends Node3D

## THE SIMULATION — the planet, the field, the star, the clock, ecology, geology, telemetry, persistence.
## Runs in every launch, with or without a camera or a UI.
##
## The node TREE is declared in Simulation.tscn; this script only WIRES it, in order. Nothing here may be a
## Control, a CanvasLayer or a Camera3D. If a node is needed for the world to be RIGHT it belongs here; if
## it is needed for the world to be SEEN it is LARenderLayer; if the player clicks it, it is LAUiLayer.
##
## Order matters: settings are read before the field is built (grid resolution) and before spawning (actor
## budget), and the star exists before the field reads its light.

# The star's world position. The planet is pinned at the origin and the star orbits around it (see
# SystemOrbits) — a deliberate moving-frame choice, not a claim that the planet is stationary.
const STAR_POSITION: Vector3 = Vector3(900.0, 320.0, 620.0)

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
var _spin_rate: float = 0.10


## Wire the world. `opts` carries the planet's shape (LAVoxelWorld's PLANET_* constants) and the
## cmdline-derived knobs the sim needs: fast_multiplier, spin_axis.
func build(opts: Dictionary) -> void:
	_settings_applier.read_settings()

	# The playback rate. A plain Node, so it exists with no UI — LAVoxelTimeControl only shows it.
	# --fast=N applies here, through the one owner of Engine.time_scale.
	_time.set_multiplier(float(opts.get("fast_multiplier", 1)))

	# The star: position, gravity, and the light whose basis + `insolation` meta ARE the field's solar input.
	_star.setup({"position": STAR_POSITION, "energy": 1.4})

	_body.setup(opts.get("planet", {}))
	_terrain = _body.terrain()
	_actors_root = _body.actors_root
	_body.set_spin_axis(Vector3(opts.get("spin_axis", Vector3.UP)).normalized())
	# TERRAIN STREAMING IS PHYSICS. godot_voxel only generates blocks around an attached VoxelViewer, and the
	# field samples that SDF — so the simulation owns a data-only viewer (no visuals, no collision meshing)
	# rather than depending on the camera. When the camera was the only viewer, a run without a render layer
	# never streamed: the seal slid from field_step 9 to 265, so every conservation baseline latched at the
	# end of the run and every drift gauge read a trivial 0.000%.
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
	# CUBED-SPHERE field: a SphereGrid shell enclosing the planet (crust + atmosphere), gathered via the
	# neighbour table with radial gravity. Per-face resolution + shell depth come from the quality setting.
	var field_grid: RefCounted = LASphereGrid.new()
	var scale: float = float(_body.radius()) / 250.0
	field_grid.build(_settings_applier.grid_res_per_face(), _settings_applier.grid_depth(),
		170.0 * scale, 8.0 * scale, _body.center())
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


func _build_system() -> void:
	# The sky controller is rendering and may never exist; LARenderLayer binds it later if it does.
	_orbits.setup(_body, _star, _material)
	_orbits.set_moon(_moon)
	LASimReport.register(Callable(_orbits, "report"))


func _build_geology_and_life() -> void:
	# Disasters seed real matter/energy into the field; the camera + audio they also accept are rendering
	# and UI, injected by those layers when they exist.
	_disasters.setup(self, _terrain, _ecology, _actors_root, null, null)
	# Lightning is EMERGENT: the field's charge process fires a bolt where a convective updraft breaks down,
	# injecting the heat pulse + scare itself, and calls back for the VISUAL bolt only.
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
	# Planet axial SPIN — the body (terrain + actors are children) turns as ONE moving frame. Starts after
	# life is placed so spawn stays deterministic.
	if _spawn.is_spawned() and _terrain.is_planet():
		_body.rotate(_body.spin_axis(), _spin_rate * delta)
	_spawn.try_spawn(overview, farview, auto_meteor, auto_select)


func set_spin_rate(rate: float) -> void:
	_spin_rate = rate


# --- Accessors: the render/UI layers and the world root read the sim through these, never by node path. ---

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
