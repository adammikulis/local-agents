extends Node3D

const PlantScene = preload("res://addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.tscn")
const RabbitScene = preload("res://addons/local_agents/scenes/simulation/actors/RabbitSphere.tscn")
const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")
const WindFieldSystemScript = preload("res://addons/local_agents/simulation/WindFieldSystem.gd")
const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

@export var initial_plant_count: int = 14
@export var initial_rabbit_count: int = 4
@export var world_bounds_radius: float = 8.0
@export var smell_voxel_size: float = 0.55
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
@export var rabbit_perceived_danger_threshold: float = 0.14
@export var rabbit_flee_duration_seconds: float = 3.4
@export var rabbit_eat_distance: float = 0.24
@export var seed_spawn_radius: float = 0.42

@export var debug_refresh_seconds: float = 0.6
@export var debug_max_smell_voxels: int = 120
@export var debug_max_temp_voxels: int = 160
@export var debug_max_wind_vectors: int = 90
@export_range(0.35, 1.0, 0.05) var debug_visual_scale: float = 0.65
@export var shelter_step_seconds: float = 0.5
@export var shelter_work_scalar: float = 0.35
@export var shelter_builder_search_radius: float = 2.4
@export var shelter_decay_per_second: float = 0.006
@export var actor_refresh_interval_seconds: float = 0.5

@onready var plant_root: Node3D = $PlantRoot
@onready var rabbit_root: Node3D = $RabbitRoot

var _sim_time_seconds: float = 0.0
var _smell_emit_accumulator: float = 0.0
var _smell_step_accumulator: float = 0.0
var _wind_step_accumulator: float = 0.0
var _smell_source_refresh_accumulator: float = 0.0
var _shelter_step_accumulator: float = 0.0
var _debug_accumulator: float = 0.0
var _actor_refresh_accumulator: float = 0.0
var _seed_sequence: int = 0
var _rabbit_sequence: int = 0
var _smell_sources: Array[Node] = []
var _mammal_actors: Array[Node] = []
var _living_creatures: Array[Node] = []
var _edible_plants_by_voxel: Dictionary = {}
var _smell_field
var _wind_field
var _living_entity_profiles: Array = []
var _shelter_sites: Dictionary = {}
var _shelter_site_sequence: int = 0
var _environment_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _solar_snapshot: Dictionary = {}

var _debug_overlay: Node3D
var _debug_smell_root: Node3D
var _debug_wind_root: Node3D
var _debug_temperature_root: Node3D

var _debug_voxel_mesh: BoxMesh
var _debug_arrow_mesh: BoxMesh
var _debug_voxel_material: StandardMaterial3D
var _debug_arrow_material: StandardMaterial3D
var _debug_smell_mm_instance: MultiMeshInstance3D
var _debug_temperature_mm_instance: MultiMeshInstance3D
var _debug_wind_mm_instance: MultiMeshInstance3D
var _debug_show_smell: bool = true
var _debug_show_wind: bool = true
var _debug_show_temperature: bool = true
var _debug_smell_layer: String = "all"

func _ready() -> void:
	_smell_field = SmellFieldSystemScript.new()
	_wind_field = WindFieldSystemScript.new()
	_smell_field.configure(world_bounds_radius, smell_voxel_size, smell_vertical_half_extent)
	_wind_field.configure(world_bounds_radius, smell_voxel_size, smell_vertical_half_extent)
	_wind_field.set_global_wind(wind_direction, wind_intensity, wind_speed)
	_ensure_debug_resources()
	_spawn_initial_plants(initial_plant_count)
	_spawn_initial_rabbits(initial_rabbit_count)
	_refresh_smell_sources()
	_refresh_actor_caches()
	_rebuild_edible_plant_index()

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_sim_time_seconds += delta
	_step_plants(delta)
	_rebuild_edible_plant_index()
	_emit_smell(delta)
	_step_smell_field(delta)
	_step_mammals(delta)
	_refresh_living_entity_profiles()
	_step_shelter_construction(delta)
	_update_debug(delta)

func set_debug_overlay(overlay: Node3D) -> void:
	_debug_overlay = overlay
	if _debug_overlay == null:
		return
	_debug_smell_root = _debug_overlay.get_node_or_null("SmellDebug")
	_debug_wind_root = _debug_overlay.get_node_or_null("WindDebug")
	_debug_temperature_root = _debug_overlay.get_node_or_null("TemperatureDebug")
	_ensure_debug_multimesh_instances()
	_apply_debug_visibility()

func apply_debug_settings(settings: Dictionary) -> void:
	_debug_show_smell = bool(settings.get("show_smell", _debug_show_smell))
	_debug_show_wind = bool(settings.get("show_wind", _debug_show_wind))
	_debug_show_temperature = bool(settings.get("show_temperature", _debug_show_temperature))
	_debug_smell_layer = String(settings.get("smell_layer", _debug_smell_layer)).to_lower().strip_edges()
	if _debug_smell_layer == "":
		_debug_smell_layer = "all"
	_apply_debug_visibility()

func set_debug_quality(density_scalar: float) -> void:
	var s = clampf(density_scalar, 0.2, 1.0)
	debug_max_smell_voxels = maxi(24, int(round(120.0 * s)))
	debug_max_temp_voxels = maxi(32, int(round(160.0 * s)))
	debug_max_wind_vectors = maxi(24, int(round(90.0 * s)))
	debug_refresh_seconds = lerpf(0.8, 0.3, s)
	debug_visual_scale = lerpf(0.5, 0.8, s)
	_debug_voxel_mesh = null
	_debug_arrow_mesh = null
	_ensure_debug_resources()
	if _debug_smell_mm_instance != null and is_instance_valid(_debug_smell_mm_instance):
		_debug_smell_mm_instance.queue_free()
		_debug_smell_mm_instance = null
	if _debug_temperature_mm_instance != null and is_instance_valid(_debug_temperature_mm_instance):
		_debug_temperature_mm_instance.queue_free()
		_debug_temperature_mm_instance = null
	if _debug_wind_mm_instance != null and is_instance_valid(_debug_wind_mm_instance):
		_debug_wind_mm_instance.queue_free()
		_debug_wind_mm_instance = null
	_ensure_debug_multimesh_instances()

func _apply_debug_visibility() -> void:
	if _debug_smell_root != null:
		_debug_smell_root.visible = _debug_show_smell
	if _debug_wind_root != null:
		_debug_wind_root.visible = _debug_show_wind
	if _debug_temperature_root != null:
		_debug_temperature_root.visible = _debug_show_temperature

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

func _normalize_environment_signals(signals) -> LocalAgentsEnvironmentSignalSnapshotResource:
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

func spawn_plant_at(world_position: Vector3, initial_growth_ratio: float = 0.0) -> Node3D:
	var plant = PlantScene.instantiate()
	plant_root.add_child(plant)
	plant.global_position = _clamp_to_field(world_position, 0.14)
	if plant.has_method("set_initial_growth_ratio"):
		plant.call("set_initial_growth_ratio", initial_growth_ratio)
	return plant

func spawn_rabbit_at(world_position: Vector3) -> Node3D:
	_rabbit_sequence += 1
	var rabbit = RabbitScene.instantiate()
	rabbit.rabbit_id = "rabbit_%d" % _rabbit_sequence
	rabbit_root.add_child(rabbit)
	rabbit.global_position = _clamp_to_field(world_position, 0.18)
	rabbit.seed_dropped.connect(_on_rabbit_seed_dropped)
	return rabbit

func spawn_random(plants: int, rabbits: int) -> void:
	for i in range(maxi(0, plants)):
		_seed_sequence += 1
		spawn_plant_at(_deterministic_spawn_point(_seed_sequence, world_bounds_radius * 0.95), float((_seed_sequence + i) % 6) / 6.0)
	for _j in range(maxi(0, rabbits)):
		_seed_sequence += 1
		spawn_rabbit_at(_deterministic_spawn_point(_seed_sequence * 2, world_bounds_radius * 0.75))
	_rebuild_edible_plant_index()
	_refresh_smell_sources()

func clear_generated() -> void:
	for child in plant_root.get_children():
		child.queue_free()
	for child in rabbit_root.get_children():
		child.queue_free()
	_edible_plants_by_voxel.clear()
	_smell_sources.clear()
	if _smell_field != null:
		_smell_field.clear()
	_reset_debug_multimesh()
	_living_entity_profiles.clear()
	_shelter_sites.clear()
	_shelter_site_sequence = 0

func collect_living_entity_profiles() -> Array:
	return _living_entity_profiles.duplicate(true)

func collect_shelter_sites() -> Array:
	var rows: Array = []
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var row: Dictionary = _shelter_sites.get(site_id, {})
		if row.is_empty():
			continue
		rows.append(row.duplicate(true))
	return rows

func _spawn_initial_plants(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		var ring := 2.4 + 1.8 * float(i % 3)
		spawn_plant_at(Vector3(cos(angle) * ring, 0.14, sin(angle) * ring), float(i % 5) / 5.0)

func _spawn_initial_rabbits(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		spawn_rabbit_at(Vector3(cos(angle) * 1.8, 0.18, sin(angle) * 1.8))

func _step_plants(delta: float) -> void:
	for plant in plant_root.get_children():
		if not is_instance_valid(plant):
			continue
		var env_context = _plant_environment_context(plant.global_position)
		if plant.has_method("simulation_step_with_environment"):
			plant.call("simulation_step_with_environment", delta, env_context)
		elif plant.has_method("simulation_step"):
			plant.call("simulation_step", delta)

func _rebuild_edible_plant_index() -> void:
	_edible_plants_by_voxel.clear()
	if _smell_field == null:
		return
	for plant in plant_root.get_children():
		if not is_instance_valid(plant):
			continue
		if not plant.has_method("is_edible") or not bool(plant.call("is_edible")):
			continue
		var voxel: Vector3i = _smell_field.world_to_voxel(plant.global_position)
		if voxel == Vector3i(2147483647, 2147483647, 2147483647):
			continue
		var key := _voxel_key(voxel)
		var bucket: Array = _edible_plants_by_voxel.get(key, [])
		bucket.append(plant)
		_edible_plants_by_voxel[key] = bucket

func _emit_smell(delta: float) -> void:
	_smell_emit_accumulator += delta
	_smell_source_refresh_accumulator += delta
	if _smell_source_refresh_accumulator >= 1.0:
		_smell_source_refresh_accumulator = 0.0
		_refresh_smell_sources()
	if _smell_emit_accumulator < smell_emit_interval_seconds:
		return
	_smell_emit_accumulator = 0.0
	for source in _smell_sources:
		if not is_instance_valid(source):
			continue
		if source.has_method("can_emit_smell") and not bool(source.call("can_emit_smell")):
			continue
		if not source.has_method("get_smell_source_payload"):
			continue
		var payload: Dictionary = source.call("get_smell_source_payload")
		if payload.is_empty():
			continue
		var position := Vector3(payload.get("position", Vector3.ZERO))
		var base_strength := float(payload.get("strength", 0.0))
		var chemicals_variant = payload.get("chemicals", null)
		if chemicals_variant is Dictionary:
			var chemicals: Dictionary = chemicals_variant
			for chem_name_variant in chemicals.keys():
				var chem_name := String(chem_name_variant)
				var concentration := float(chemicals[chem_name_variant])
				_smell_field.deposit_chemical(chem_name, position, base_strength * concentration)
		else:
			_smell_field.deposit(String(payload.get("kind", "")), position, base_strength)

func _refresh_smell_sources() -> void:
	_smell_sources.clear()
	for node in get_tree().get_nodes_in_group("living_smell_source"):
		if node is Node:
			_smell_sources.append(node)

func _refresh_actor_caches() -> void:
	_mammal_actors.clear()
	_living_creatures.clear()
	for node in get_tree().get_nodes_in_group("mammal_actor"):
		if node is Node:
			_mammal_actors.append(node)
	for node in get_tree().get_nodes_in_group("living_creature"):
		if node is Node:
			_living_creatures.append(node)

func _step_smell_field(delta: float) -> void:
	_smell_step_accumulator += delta
	while _smell_step_accumulator >= smell_sim_step_seconds:
		_smell_step_accumulator -= smell_sim_step_seconds
		var wind_source: Variant = Vector2.ZERO
		if wind_enabled and wind_intensity > 0.0 and _wind_field != null:
			_wind_step_accumulator += smell_sim_step_seconds
			if _wind_step_accumulator >= wind_sim_step_seconds:
				var wind_delta := _wind_step_accumulator
				_wind_step_accumulator = 0.0
				_wind_field.set_global_wind(wind_direction, wind_intensity, wind_speed)
				var diurnal_phase := fmod(_sim_time_seconds / 24.0, TAU)
				_wind_field.step(wind_delta, 0.52, diurnal_phase, rain_intensity, _solar_air_context())
			wind_source = Callable(_wind_field, "sample_wind")
		_smell_field.step(smell_sim_step_seconds, wind_source, smell_base_decay_per_second, rain_intensity, rain_decay_multiplier)

func _plant_environment_context(world_position: Vector3) -> Dictionary:
	var tile = _tile_at_world(world_position)
	var sunlight = clampf(float(tile.get("sunlight_absorbed", tile.get("sunlight_total", 0.5))), 0.0, 1.5)
	var uv = clampf(float(tile.get("uv_index", 0.0)), 0.0, 3.0)
	var heat_load = clampf(float(tile.get("heat_load", 0.5)), 0.0, 2.0)
	var growth = clampf(float(tile.get("plant_growth_factor", 0.5)), 0.0, 1.0)
	var moisture = clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0)
	var air_temp = 0.5
	if _wind_field != null:
		air_temp = clampf(_wind_field.sample_temperature(world_position + Vector3(0.0, smell_voxel_size, 0.0)), 0.0, 1.2)
	return {
		"sunlight_absorbed": sunlight,
		"uv_index": uv,
		"heat_load": heat_load,
		"plant_growth_factor": growth,
		"moisture": moisture,
		"air_temperature": air_temp,
		"rain_intensity": rain_intensity,
	}

func _tile_at_world(world_position: Vector3) -> Dictionary:
	var tile_index: Dictionary = _environment_snapshot.get("tile_index", {})
	if tile_index.is_empty():
		return {}
	var tile_id = TileKeyUtilsScript.from_world_xz(world_position)
	var row = tile_index.get(tile_id, {})
	return (row as Dictionary).duplicate(true) if row is Dictionary else {}

func _solar_air_context() -> Dictionary:
	var out := {
		"sun_altitude": clampf(float(_solar_snapshot.get("sun_altitude", 0.0)), 0.0, 1.0),
		"avg_insolation": clampf(float(_solar_snapshot.get("avg_insolation", 0.0)), 0.0, 1.0),
		"avg_uv_index": clampf(float(_solar_snapshot.get("avg_uv_index", 0.0)), 0.0, 2.0),
		"avg_heat_load": clampf(float(_solar_snapshot.get("avg_heat_load", 0.0)), 0.0, 1.5),
		"air_heating_scalar": 1.0,
	}
	return out

func _step_mammals(delta: float) -> void:
	_actor_refresh_accumulator += maxf(0.0, delta)
	if _actor_refresh_accumulator >= actor_refresh_interval_seconds:
		_actor_refresh_accumulator = 0.0
		_refresh_actor_caches()
	for mammal in _mammal_actors:
		if not is_instance_valid(mammal):
			continue
		var can_smell_entity := true
		if mammal.has_method("can_smell"):
			can_smell_entity = bool(mammal.call("can_smell"))
		if can_smell_entity:
			var danger_radius := 4
			if mammal.has_method("get_danger_smell_radius_cells"):
				danger_radius = int(mammal.call("get_danger_smell_radius_cells"))
			var danger_weights: Dictionary = {}
			if mammal.has_method("get_danger_chemical_weights"):
				danger_weights = mammal.call("get_danger_chemical_weights")
			var danger = _smell_field.strongest_weighted_chemical_score(mammal.global_position, danger_weights, danger_radius)
			var danger_threshold := rabbit_perceived_danger_threshold
			if mammal.has_method("get_danger_threshold"):
				danger_threshold = float(mammal.call("get_danger_threshold"))
			if float(danger.get("score", 0.0)) >= danger_threshold:
				var danger_pos = danger.get("position", null)
				if danger_pos != null and mammal.has_method("trigger_flee"):
					mammal.trigger_flee(danger_pos, rabbit_flee_duration_seconds)
			elif (not mammal.has_method("is_fleeing")) or (not bool(mammal.call("is_fleeing"))):
				var food_radius := 8
				if mammal.has_method("get_food_smell_radius_cells"):
					food_radius = int(mammal.call("get_food_smell_radius_cells"))
				var food_weights: Dictionary = {}
				if mammal.has_method("get_food_chemical_weights"):
					food_weights = mammal.call("get_food_chemical_weights")
				var food = _smell_field.strongest_weighted_chemical_position(mammal.global_position, food_weights, food_radius)
				if food != null and mammal.has_method("set_food_target"):
					mammal.set_food_target(food)
				elif mammal.has_method("clear_food_target"):
					mammal.clear_food_target()
		elif mammal.has_method("clear_food_target"):
			mammal.clear_food_target()

		if mammal.has_method("simulation_step"):
			mammal.simulation_step(delta)
		_try_eat_nearby_plant(mammal)
		if mammal.has_method("global_position"):
			_keep_inside_bounds(mammal)

func _try_eat_nearby_plant(rabbit: Node3D) -> void:
	if _smell_field == null:
		return
	var rabbit_voxel: Vector3i = _smell_field.world_to_voxel(rabbit.global_position)
	if rabbit_voxel == Vector3i(2147483647, 2147483647, 2147483647):
		return
	for z_offset in range(-1, 2):
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				var key := _voxel_key(Vector3i(rabbit_voxel.x + x_offset, rabbit_voxel.y + y_offset, rabbit_voxel.z + z_offset))
				if not _edible_plants_by_voxel.has(key):
					continue
				var bucket: Array = _edible_plants_by_voxel[key]
				for plant in bucket:
					if not is_instance_valid(plant):
						continue
					if not plant.has_method("is_edible") or not bool(plant.call("is_edible")):
						continue
					if rabbit.global_position.distance_to(plant.global_position) > rabbit_eat_distance:
						continue
					var seeds := int(plant.call("consume"))
					if seeds > 0 and rabbit.has_method("ingest_seeds"):
						rabbit.call("ingest_seeds", seeds)
					return

func _on_rabbit_seed_dropped(rabbit_id: String, count: int) -> void:
	var rabbit = _find_rabbit_by_id(rabbit_id)
	if rabbit == null:
		return
	for i in range(count):
		_seed_sequence += 1
		var spawn_angle := float(_seed_sequence) * 2.3999632
		var radius := 0.12 + (seed_spawn_radius * (float((_seed_sequence + i) % 7) / 7.0))
		var spawn_offset := Vector3(cos(spawn_angle) * radius, 0.14, sin(spawn_angle) * radius)
		spawn_plant_at(rabbit.global_position + spawn_offset, 0.0)
	_rebuild_edible_plant_index()

func _refresh_living_entity_profiles() -> void:
	_living_entity_profiles.clear()
	for node in _living_creatures:
		if not is_instance_valid(node):
			continue
		if not node.has_method("get_living_entity_profile"):
			continue
		var payload_variant = node.call("get_living_entity_profile")
		if not (payload_variant is Dictionary):
			continue
		var payload = payload_variant as Dictionary
		if payload.is_empty():
			continue
		_living_entity_profiles.append(payload.duplicate(true))

func _step_shelter_construction(delta: float) -> void:
	_shelter_step_accumulator += maxf(0.0, delta)
	var stepped := false
	while _shelter_step_accumulator >= shelter_step_seconds:
		_shelter_step_accumulator -= shelter_step_seconds
		stepped = true
		_apply_shelter_step(float(shelter_step_seconds))
	if not stepped:
		_apply_shelter_decay(delta)

func _apply_shelter_step(step_delta: float) -> void:
	_apply_shelter_decay(step_delta)
	for profile_variant in _living_entity_profiles:
		if not (profile_variant is Dictionary):
			continue
		var profile = profile_variant as Dictionary
		if not bool(profile.has("position")):
			continue
		var position = _position_from_profile(profile)
		var carry_channels = _normalized_carry_channels(profile)
		var build_channels = _normalized_build_channels(profile)
		var build_power = _build_power(carry_channels, build_channels)
		if build_power <= 0.01:
			continue
		var site_id = _find_or_create_shelter_site(profile, position, build_channels)
		if site_id == "":
			continue
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var required_work = maxf(1.0, float(site.get("required_work", 8.0)))
		var progress = clampf(float(site.get("progress", 0.0)), 0.0, required_work)
		var work_gain = build_power * shelter_work_scalar * step_delta
		progress = minf(required_work, progress + work_gain)
		var stability = clampf(float(site.get("stability", 0.0)) + build_power * 0.03, 0.0, 1.0)
		var carried_mass = _channel_total(carry_channels)
		site["material_mass"] = maxf(0.0, float(site.get("material_mass", 0.0)) + carried_mass * 0.08 * step_delta)
		site["dig_depth"] = maxf(0.0, float(site.get("dig_depth", 0.0)) + float(build_channels.get("dig", 0.0)) * 0.03 * step_delta)
		site["progress"] = progress
		site["stability"] = stability
		site["state"] = "complete" if progress >= required_work else "building"
		site["last_touched_time"] = _sim_time_seconds
		site["last_builder_id"] = String(profile.get("entity_id", ""))
		var builders: Array = site.get("builder_ids", [])
		var builder_id = String(profile.get("entity_id", ""))
		if builder_id != "" and not builders.has(builder_id):
			builders.append(builder_id)
		site["builder_ids"] = builders
		_shelter_sites[site_id] = site

func _apply_shelter_decay(delta: float) -> void:
	if delta <= 0.0 or _shelter_sites.is_empty():
		return
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var untouched_time = _sim_time_seconds - float(site.get("last_touched_time", _sim_time_seconds))
		if untouched_time <= 8.0:
			continue
		var state = String(site.get("state", "building"))
		var decay_scale = 0.35 if state == "complete" else 1.0
		var progress = maxf(0.0, float(site.get("progress", 0.0)) - shelter_decay_per_second * delta * decay_scale)
		site["progress"] = progress
		site["state"] = "complete" if progress >= float(site.get("required_work", 1.0)) else "building"
		_shelter_sites[site_id] = site

func _find_or_create_shelter_site(profile: Dictionary, position: Vector3, build_channels: Dictionary) -> String:
	var nearby_id = _nearest_shelter_site_id(position, String(profile.get("entity_id", "")))
	if nearby_id != "":
		return nearby_id
	_shelter_site_sequence += 1
	var site_id = "shelter_%d" % _shelter_site_sequence
	var preferences: Dictionary = profile.get("shelter_preferences", {})
	var shape = String(preferences.get("shape", _dominant_shelter_shape(build_channels)))
	var required_work = maxf(1.0, float(preferences.get("required_work", _default_required_work(carry_profile(profile), build_channels))))
	var taxonomy_path: Array = profile.get("taxonomy_path", [])
	_shelter_sites[site_id] = {
		"shelter_id": site_id,
		"x": position.x,
		"y": position.y,
		"z": position.z,
		"shape": shape,
		"required_work": required_work,
		"progress": 0.0,
		"stability": 0.0,
		"material_mass": 0.0,
		"dig_depth": 0.0,
		"state": "building",
		"builder_ids": [],
		"last_builder_id": "",
		"taxonomy_path": taxonomy_path.duplicate(true),
		"last_touched_time": _sim_time_seconds,
	}
	return site_id

func _nearest_shelter_site_id(position: Vector3, _builder_id: String) -> String:
	var best_id = ""
	var best_dist = shelter_builder_search_radius
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var site_pos = Vector3(float(site.get("x", 0.0)), float(site.get("y", 0.0)), float(site.get("z", 0.0)))
		var dist = position.distance_to(site_pos)
		if dist <= best_dist:
			best_dist = dist
			best_id = site_id
	return best_id

func _position_from_profile(profile: Dictionary) -> Vector3:
	var pos_variant = profile.get("position", {})
	if pos_variant is Dictionary:
		var row = pos_variant as Dictionary
		return Vector3(float(row.get("x", 0.0)), float(row.get("y", 0.0)), float(row.get("z", 0.0)))
	return Vector3.ZERO

func _normalized_carry_channels(profile: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var carry_variant = profile.get("carry_channels", {})
	if carry_variant is Dictionary:
		for key_variant in (carry_variant as Dictionary).keys():
			var key = String(key_variant).strip_edges().to_lower()
			out[key] = clampf(float((carry_variant as Dictionary).get(key_variant, 0.0)), 0.0, 4.0)
	if _is_animal_profile(profile):
		out["mouth"] = maxf(float(out.get("mouth", 0.0)), 0.18)
	if _is_hominid_profile(profile):
		out["hands"] = maxf(float(out.get("hands", 0.0)), 0.72)
	return out

func _normalized_build_channels(profile: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var build_variant = profile.get("build_channels", {})
	if build_variant is Dictionary:
		for key_variant in (build_variant as Dictionary).keys():
			var key = String(key_variant).strip_edges().to_lower()
			out[key] = clampf(float((build_variant as Dictionary).get(key_variant, 0.0)), 0.0, 4.0)
	var carry = _normalized_carry_channels(profile)
	var carry_power = _channel_total(carry)
	out["carry"] = maxf(float(out.get("carry", 0.0)), carry_power * 0.55)
	if _is_animal_profile(profile):
		out["dig"] = maxf(float(out.get("dig", 0.0)), float(carry.get("mouth", 0.0)) * 0.4)
	return out

func _build_power(carry_channels: Dictionary, build_channels: Dictionary) -> float:
	var carry_power = _channel_total(carry_channels)
	var build_total = _channel_total(build_channels)
	return maxf(0.0, carry_power * 0.5 + build_total * 0.7)

func _channel_total(channels: Dictionary) -> float:
	var total = 0.0
	var keys = channels.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		total += maxf(0.0, float(channels.get(String(key_variant), 0.0)))
	return total

func carry_profile(profile: Dictionary) -> Dictionary:
	return _normalized_carry_channels(profile)

func _dominant_shelter_shape(build_channels: Dictionary) -> String:
	var dig = float(build_channels.get("dig", 0.0))
	var carry = float(build_channels.get("carry", 0.0))
	var stack = float(build_channels.get("stack", 0.0))
	if dig >= carry and dig >= stack:
		return "burrow"
	if stack >= dig and stack >= carry:
		return "stacked"
	return "nest"

func _default_required_work(carry_channels: Dictionary, build_channels: Dictionary) -> float:
	var dexterity = float(carry_channels.get("hands", 0.0))
	var dig = float(build_channels.get("dig", 0.0))
	var base = 7.5 + dexterity * 6.0 + dig * 1.2
	return clampf(base, 4.0, 26.0)

func _is_animal_profile(profile: Dictionary) -> bool:
	var taxonomy: Array = profile.get("taxonomy_path", [])
	for token_variant in taxonomy:
		if String(token_variant).to_lower() == "animal":
			return true
	return false

func _is_hominid_profile(profile: Dictionary) -> bool:
	var tags: Array = profile.get("tags", [])
	for tag_variant in tags:
		var tag = String(tag_variant).to_lower()
		if tag == "hominid" or tag == "human":
			return true
	var meta: Dictionary = profile.get("metadata", {})
	return bool(meta.get("dexterous_grasp", false))

func _find_rabbit_by_id(rabbit_id: String) -> Node3D:
	for rabbit in rabbit_root.get_children():
		if String(rabbit.get("rabbit_id")) == rabbit_id:
			return rabbit
	return null

func _keep_inside_bounds(rabbit: Node3D) -> void:
	var planar := Vector2(rabbit.global_position.x, rabbit.global_position.z)
	if planar.length() <= world_bounds_radius:
		return
	var clamped := planar.normalized() * world_bounds_radius
	rabbit.global_position = Vector3(clamped.x, rabbit.global_position.y, clamped.y)

func _deterministic_spawn_point(sequence: int, max_radius: float) -> Vector3:
	var angle := float(sequence) * 2.3999632
	var radial_step := float((sequence % 11) + 1) / 11.0
	var radius := max_radius * radial_step
	return Vector3(cos(angle) * radius, 0.14, sin(angle) * radius)

func _clamp_to_field(world_position: Vector3, y: float) -> Vector3:
	var planar := Vector2(world_position.x, world_position.z)
	var clamped := planar
	if planar.length() > world_bounds_radius:
		clamped = planar.normalized() * world_bounds_radius
	return Vector3(clamped.x, y, clamped.y)

func _voxel_key(voxel: Vector3i) -> String:
	return "%d:%d:%d" % [voxel.x, voxel.y, voxel.z]

func _ensure_debug_resources() -> void:
	if _debug_voxel_mesh == null:
		_debug_voxel_mesh = BoxMesh.new()
		_debug_voxel_mesh.size = Vector3.ONE * (smell_voxel_size * 0.9 * debug_visual_scale)
	if _debug_arrow_mesh == null:
		_debug_arrow_mesh = BoxMesh.new()
		var arrow_scale = clampf(debug_visual_scale, 0.35, 1.0)
		_debug_arrow_mesh.size = Vector3(0.08, 0.08, 0.45) * arrow_scale
	if _debug_voxel_material == null:
		_debug_voxel_material = StandardMaterial3D.new()
		_debug_voxel_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_voxel_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_voxel_material.albedo_color = Color(1.0, 1.0, 1.0, 0.2)
	if _debug_arrow_material == null:
		_debug_arrow_material = StandardMaterial3D.new()
		_debug_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_arrow_material.albedo_color = Color(0.85, 0.92, 1.0, 0.35)

func _update_debug(delta: float) -> void:
	if _debug_overlay == null:
		return
	_ensure_debug_multimesh_instances()
	_debug_accumulator += delta
	if _debug_accumulator < debug_refresh_seconds:
		return
	_debug_accumulator = 0.0
	if _debug_smell_root != null and _debug_smell_root.visible:
		_render_smell_debug()
	if _debug_temperature_root != null and _debug_temperature_root.visible:
		_render_temperature_debug()
	if _debug_wind_root != null and _debug_wind_root.visible:
		_render_wind_debug()

func _render_smell_debug() -> void:
	if _debug_smell_mm_instance == null or _debug_smell_root == null:
		return
	var budget := maxi(24, debug_max_smell_voxels)
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	match _debug_smell_layer:
		"food":
			_append_voxel_cells(_smell_field.build_layer_cells("chem_cis_3_hexenol", 0.02, budget), Color(0.25, 0.95, 0.28, 0.2), 0.35, 0.12, transforms, colors)
		"floral":
			_append_voxel_cells(_smell_field.build_layer_cells("chem_linalool", 0.02, budget), Color(1.0, 0.86, 0.38, 0.2), 0.35, 0.16, transforms, colors)
		"danger":
			_append_voxel_cells(_smell_field.build_layer_cells("chem_ammonia", 0.02, budget), Color(1.0, 0.3, 0.3, 0.22), 0.35, 0.22, transforms, colors)
		"hexanal":
			_append_voxel_cells(_smell_field.build_layer_cells("chem_hexanal", 0.02, budget), Color(0.45, 0.95, 0.68, 0.2), 0.35, 0.14, transforms, colors)
		"methyl_salicylate":
			_append_voxel_cells(_smell_field.build_layer_cells("chem_methyl_salicylate", 0.02, budget), Color(0.95, 0.55, 0.95, 0.22), 0.35, 0.2, transforms, colors)
		_:
			var food_cells: Array = _smell_field.build_layer_cells("chem_cis_3_hexenol", 0.02, budget / 3)
			var floral_cells: Array = _smell_field.build_layer_cells("chem_linalool", 0.02, budget / 3)
			var danger_cells: Array = _smell_field.build_layer_cells("chem_ammonia", 0.02, budget / 3)
			_append_voxel_cells(food_cells, Color(0.25, 0.95, 0.28, 0.2), 0.35, 0.1, transforms, colors)
			_append_voxel_cells(floral_cells, Color(1.0, 0.86, 0.38, 0.2), 0.35, 0.16, transforms, colors)
			_append_voxel_cells(danger_cells, Color(1.0, 0.3, 0.3, 0.22), 0.35, 0.22, transforms, colors)
	_commit_multimesh_instances(_debug_smell_mm_instance, transforms, colors)

func _render_temperature_debug() -> void:
	if _debug_temperature_mm_instance == null or _debug_temperature_root == null:
		return
	var rows: Array = _wind_field.build_temperature_cells(debug_max_temp_voxels, 0.03)
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO))
		var temp := clampf(float(row.get("temperature", 0.0)), 0.0, 1.0)
		var color := Color(0.15, 0.35, 1.0, 0.16).lerp(Color(1.0, 0.2, 0.18, 0.3), temp)
		var world_lifted = world + Vector3(0.0, 0.35, 0.0)
		var local = _debug_temperature_root.to_local(world_lifted)
		transforms.append(Transform3D(Basis.IDENTITY, local))
		colors.append(color)
	_commit_multimesh_instances(_debug_temperature_mm_instance, transforms, colors)

func _render_wind_debug() -> void:
	if _debug_wind_mm_instance == null or _debug_wind_root == null:
		return
	var rows: Array = _wind_field.build_debug_vectors(debug_max_wind_vectors, 0.03)
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO)) + Vector3(0.0, 0.48, 0.0)
		var wind := Vector2(row.get("wind", Vector2.ZERO))
		var speed := float(row.get("speed", 0.0))
		if wind.length_squared() <= 0.00001:
			continue
		var forward = Vector3(wind.x, 0.0, wind.y).normalized()
		var right = Vector3.UP.cross(forward).normalized()
		if right.length_squared() < 0.00001:
			right = Vector3.RIGHT
		var basis := Basis(right, Vector3.UP, forward).scaled(Vector3(1.0, 1.0, clampf(0.6 + speed * 0.6, 0.6, 1.8)))
		var local = _debug_wind_root.to_local(world)
		transforms.append(Transform3D(basis, local))
		colors.append(Color(0.68, 0.92, 1.0, clampf(0.2 + speed * 0.28, 0.2, 0.55)))
	_commit_multimesh_instances(_debug_wind_mm_instance, transforms, colors)

func _append_voxel_cells(rows: Array[Dictionary], base_color: Color, alpha_scalar: float, y_lift: float, transforms: Array[Transform3D], colors: Array[Color]) -> void:
	if _debug_smell_root == null:
		return
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO)) + Vector3(0.0, y_lift, 0.0)
		var value := clampf(float(row.get("value", 0.0)), 0.0, 1.0)
		var color := base_color
		color.a = clampf(base_color.a + value * alpha_scalar, 0.12, 0.58)
		var local = _debug_smell_root.to_local(world)
		transforms.append(Transform3D(Basis.IDENTITY, local))
		colors.append(color)

func _commit_multimesh_instances(instance: MultiMeshInstance3D, transforms: Array[Transform3D], colors: Array[Color]) -> void:
	if instance == null:
		return
	var mm := instance.multimesh
	if mm == null:
		return
	var count = mini(transforms.size(), colors.size())
	mm.instance_count = count
	for i in range(count):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

func _ensure_debug_multimesh_instances() -> void:
	if _debug_smell_root != null and not is_instance_valid(_debug_smell_mm_instance):
		_debug_smell_mm_instance = _build_debug_mm_instance(_debug_voxel_mesh, _debug_voxel_material)
		_debug_smell_mm_instance.name = "SmellDebugMultiMesh"
		_debug_smell_root.add_child(_debug_smell_mm_instance)
	if _debug_temperature_root != null and not is_instance_valid(_debug_temperature_mm_instance):
		_debug_temperature_mm_instance = _build_debug_mm_instance(_debug_voxel_mesh, _debug_voxel_material)
		_debug_temperature_mm_instance.name = "TemperatureDebugMultiMesh"
		_debug_temperature_root.add_child(_debug_temperature_mm_instance)
	if _debug_wind_root != null and not is_instance_valid(_debug_wind_mm_instance):
		_debug_wind_mm_instance = _build_debug_mm_instance(_debug_arrow_mesh, _debug_arrow_material)
		_debug_wind_mm_instance.name = "WindDebugMultiMesh"
		_debug_wind_root.add_child(_debug_wind_mm_instance)

func _build_debug_mm_instance(mesh: Mesh, material: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 0
	mm.mesh = mesh
	var out := MultiMeshInstance3D.new()
	out.multimesh = mm
	out.material_override = material
	return out

func _reset_debug_multimesh() -> void:
	if _debug_smell_mm_instance != null and _debug_smell_mm_instance.multimesh != null:
		_debug_smell_mm_instance.multimesh.instance_count = 0
	if _debug_temperature_mm_instance != null and _debug_temperature_mm_instance.multimesh != null:
		_debug_temperature_mm_instance.multimesh.instance_count = 0
	if _debug_wind_mm_instance != null and _debug_wind_mm_instance.multimesh != null:
		_debug_wind_mm_instance.multimesh.instance_count = 0
