extends Node3D

const PlantScene = preload("res://addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.tscn")
const RabbitScene = preload("res://addons/local_agents/scenes/simulation/actors/RabbitSphere.tscn")
const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")
const WindFieldSystemScript = preload("res://addons/local_agents/simulation/WindFieldSystem.gd")
const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const PlantGrowthControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/ecology/PlantGrowthController.gd")
const MammalBehaviorControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/ecology/MammalBehaviorController.gd")
const EcologyDebugRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/ecology/EcologyDebugRenderer.gd")
const ShelterConstructionControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/ecology/ShelterConstructionController.gd")
const SmellSystemControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/ecology/SmellSystemController.gd")

@export var initial_plant_count: int = 14
@export var initial_rabbit_count: int = 4
@export var world_bounds_radius: float = 8.0
@export var smell_voxel_size: float = 1.0
@export var smell_vertical_half_extent: float = 3.0
@export var smell_emit_interval_seconds: float = 0.65
@export var smell_base_decay_per_second: float = 0.12
@export var rain_decay_multiplier: float = 1.9
@export var rain_intensity: float = 0.0
@export var wind_enabled: bool = true
@export var wind_direction: Vector3 = Vector3(1.0, 0.0, 0.0)
@export_range(0.0, 1.0, 0.01) var wind_intensity: float = 0.0
@export var wind_speed: float = 1.25
@export var smell_sim_step_seconds: float = 0.1
@export var wind_sim_step_seconds: float = 0.2
@export_range(1, 16, 1) var max_smell_substeps_per_physics_frame: int = 3
@export var rabbit_perceived_danger_threshold: float = 0.14
@export var rabbit_flee_duration_seconds: float = 3.4
@export var rabbit_eat_distance: float = 0.24
@export var seed_spawn_radius: float = 0.42
@export var debug_refresh_seconds: float = 0.6
@export var debug_max_smell_voxels: int = 120
@export var debug_max_temp_voxels: int = 160
@export var debug_max_wind_vectors: int = 90
@export_range(0.35, 1.0, 0.05) var debug_visual_scale: float = 0.65
@export_range(6.0, 120.0, 1.0) var debug_max_render_distance: float = 52.0
@export_range(2.0, 60.0, 1.0) var debug_near_full_detail_distance: float = 18.0
@export_range(0.1, 1.0, 0.05) var debug_far_lod_scale: float = 0.35
@export var shelter_step_seconds: float = 0.5
@export var shelter_work_scalar: float = 0.35
@export var shelter_builder_search_radius: float = 2.4
@export var shelter_decay_per_second: float = 0.006
@export var actor_refresh_interval_seconds: float = 0.5
@export var plant_step_interval_seconds: float = 0.1
@export var mammal_step_interval_seconds: float = 0.1
@export var living_profile_refresh_interval_seconds: float = 0.2
@export var edible_index_rebuild_interval_seconds: float = 0.35

@onready var plant_root: Node3D = $PlantRoot
@onready var rabbit_root: Node3D = $RabbitRoot

var _sim_time_seconds: float = 0.0
var _plant_step_accumulator: float = 0.0
var _mammal_step_accumulator: float = 0.0
var _profile_refresh_accumulator: float = 0.0
var _edible_index_accumulator: float = 0.0
var _seed_sequence: int = 0
var _rabbit_sequence: int = 0
var _smell_field
var _wind_field
var _living_entity_profiles: Array = []
var _environment_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _solar_snapshot: Dictionary = {}

var _plant_growth_controller: RefCounted
var _mammal_behavior_controller: RefCounted
var _debug_renderer: RefCounted
var _shelter_construction_controller: RefCounted
var _smell_system_controller: RefCounted

func _ready() -> void:
	_smell_field = SmellFieldSystemScript.new()
	_wind_field = WindFieldSystemScript.new()
	_smell_field.configure(world_bounds_radius, smell_voxel_size, smell_vertical_half_extent)
	_wind_field.configure(world_bounds_radius, smell_voxel_size, smell_vertical_half_extent)
	_wind_field.set_global_wind(wind_direction, wind_intensity, wind_speed)
	_plant_growth_controller = PlantGrowthControllerScript.new()
	_mammal_behavior_controller = MammalBehaviorControllerScript.new()
	_debug_renderer = EcologyDebugRendererScript.new()
	_shelter_construction_controller = ShelterConstructionControllerScript.new()
	_smell_system_controller = SmellSystemControllerScript.new()
	_plant_growth_controller.setup(self)
	_mammal_behavior_controller.setup(self)
	_debug_renderer.setup(self)
	_shelter_construction_controller.setup(self)
	_smell_system_controller.setup(self)
	_plant_growth_controller.spawn_initial_plants(initial_plant_count)
	_mammal_behavior_controller.spawn_initial_rabbits(initial_rabbit_count)
	_smell_system_controller.refresh_smell_sources()
	_mammal_behavior_controller.refresh_actor_caches()
	_plant_growth_controller.rebuild_edible_plant_index()

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_sim_time_seconds += delta
	_plant_step_accumulator += delta
	_mammal_step_accumulator += delta
	_profile_refresh_accumulator += delta
	_edible_index_accumulator += delta
	if _plant_step_accumulator >= maxf(0.01, plant_step_interval_seconds):
		_plant_growth_controller.step_plants(_plant_step_accumulator)
		_plant_step_accumulator = 0.0
	if _edible_index_accumulator >= maxf(0.05, edible_index_rebuild_interval_seconds):
		_plant_growth_controller.rebuild_edible_plant_index()
		_edible_index_accumulator = 0.0
	_smell_system_controller.emit_smell(delta)
	_smell_system_controller.step_smell_field(delta)
	if _mammal_step_accumulator >= maxf(0.01, mammal_step_interval_seconds):
		_mammal_behavior_controller.step_mammals(_mammal_step_accumulator)
		_mammal_step_accumulator = 0.0
	if _profile_refresh_accumulator >= maxf(0.05, living_profile_refresh_interval_seconds):
		_refresh_living_entity_profiles()
		_profile_refresh_accumulator = 0.0
	_step_shelter_construction(delta)
	_debug_renderer.update_debug(delta)

func set_debug_overlay(overlay: Node3D) -> void:
	_debug_renderer.set_debug_overlay(overlay)

func apply_debug_settings(settings: Dictionary) -> void:
	_debug_renderer.apply_debug_settings(settings)

func set_debug_quality(density_scalar: float) -> void:
	_debug_renderer.set_debug_quality(density_scalar)

func set_rain_intensity(next_rain_intensity: float) -> void:
	rain_intensity = clampf(next_rain_intensity, 0.0, 1.0)

func set_environment_signals(signals) -> void:
	var snapshot = _normalize_environment_signals(signals)
	_environment_snapshot = snapshot.environment_snapshot.duplicate(true)
	_weather_snapshot = snapshot.weather_snapshot.duplicate(true)
	_solar_snapshot = snapshot.solar_snapshot.duplicate(true)
	var avg_rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", rain_intensity)), 0.0, 1.0)
	set_rain_intensity(avg_rain)
	var wind_row: Dictionary = _weather_snapshot.get("wind_dir", {})
	var wind_vec = Vector3(float(wind_row.get("x", wind_direction.x)), 0.0, float(wind_row.get("y", wind_direction.z)))
	var wind_mag = wind_vec.length()
	if wind_mag > 0.0001:
		set_wind(wind_vec / wind_mag, clampf(float(_weather_snapshot.get("wind_speed", wind_intensity)), 0.0, 1.0), wind_enabled)

func _normalize_environment_signals(signals):
	var snapshot = EnvironmentSignalSnapshotResourceScript.new()
	if signals is Resource and signals.has_method("to_dict"):
		snapshot.from_dict((signals as Resource).to_dict())
	elif signals is Dictionary:
		snapshot.from_dict(signals as Dictionary)
	return snapshot

func set_wind(next_direction: Vector3, next_intensity: float, enabled: bool = true) -> void:
	wind_direction = next_direction
	wind_intensity = clampf(next_intensity, 0.0, 1.0)
	wind_enabled = enabled
	if _wind_field != null:
		_wind_field.set_global_wind(wind_direction, wind_intensity if wind_enabled else 0.0, wind_speed)

func set_smell_voxel_size(size_meters: float) -> void:
	var clamped = clampf(size_meters, 0.5, 3.0)
	if is_equal_approx(smell_voxel_size, clamped):
		return
	smell_voxel_size = clamped
	_smell_system_controller.reconfigure_spatial_fields()

func set_smell_vertical_half_extent(half_extent_meters: float) -> void:
	var clamped = clampf(half_extent_meters, 1.0, 8.0)
	if is_equal_approx(smell_vertical_half_extent, clamped):
		return
	smell_vertical_half_extent = clamped
	_smell_system_controller.reconfigure_spatial_fields()

func spawn_plant_at(world_position: Vector3, initial_growth_ratio: float = 0.0) -> Node3D:
	return _plant_growth_controller.spawn_plant_at(world_position, initial_growth_ratio)

func spawn_rabbit_at(world_position: Vector3) -> Node3D:
	return _mammal_behavior_controller.spawn_rabbit_at(world_position)

func spawn_random(plants: int, rabbits: int) -> void:
	for i in range(maxi(0, plants)):
		_seed_sequence += 1
		spawn_plant_at(_plant_growth_controller.deterministic_spawn_point(_seed_sequence, world_bounds_radius * 0.95), float((_seed_sequence + i) % 6) / 6.0)
	for _j in range(maxi(0, rabbits)):
		_seed_sequence += 1
		spawn_rabbit_at(_plant_growth_controller.deterministic_spawn_point(_seed_sequence * 2, world_bounds_radius * 0.75))
	_plant_growth_controller.rebuild_edible_plant_index()
	_smell_system_controller.refresh_smell_sources()

func clear_generated() -> void:
	_plant_growth_controller.clear_generated_plants()
	_mammal_behavior_controller.clear_generated_rabbits()
	_smell_system_controller.clear_sources()
	if _smell_field != null:
		_smell_field.clear()
	_debug_renderer.reset_debug_multimesh()
	_living_entity_profiles.clear()
	_shelter_construction_controller.clear_sites()

func collect_living_entity_profiles() -> Array:
	return _living_entity_profiles.duplicate(true)

func collect_shelter_sites() -> Array:
	return _shelter_construction_controller.collect_shelter_sites()

func _on_rabbit_seed_dropped(rabbit_id: String, count: int) -> void:
	_mammal_behavior_controller.on_rabbit_seed_dropped(rabbit_id, count)

func _refresh_living_entity_profiles() -> void:
	_living_entity_profiles = _mammal_behavior_controller.refresh_living_entity_profiles()

func _step_shelter_construction(delta: float) -> void:
	_shelter_construction_controller.set_sim_time(_sim_time_seconds)
	_shelter_construction_controller.step_shelter_construction(delta, _living_entity_profiles)
