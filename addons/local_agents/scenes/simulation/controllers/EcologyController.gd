extends Node3D

const PlantScene = preload("res://addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.tscn")
const RabbitScene = preload("res://addons/local_agents/scenes/simulation/actors/RabbitSphere.tscn")
const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")
const WindFieldSystemScript = preload("res://addons/local_agents/simulation/WindFieldSystem.gd")
const GridConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GridConfigResource.gd")

@export var initial_plant_count: int = 14
@export var initial_rabbit_count: int = 4
@export var world_bounds_radius: float = 8.0
@export var smell_hex_size: float = 0.55
@export var grid_config: Resource
@export var smell_debug_enabled: bool = true
@export var smell_emit_interval_seconds: float = 0.65
@export var smell_base_decay_per_second: float = 0.12
@export var rain_decay_multiplier: float = 1.9
@export var rain_intensity: float = 0.0
@export var wind_enabled: bool = true
@export var wind_direction: Vector3 = Vector3(1.0, 0.0, 0.0)
@export_range(0.0, 1.0, 0.01) var wind_intensity: float = 0.0
@export var wind_speed: float = 1.25
@export var rabbit_perceived_danger_threshold: float = 0.14
@export var rabbit_flee_duration_seconds: float = 3.4
@export var rabbit_eat_distance: float = 0.24
@export var seed_spawn_radius: float = 0.42

@onready var plant_root: Node3D = $PlantRoot
@onready var rabbit_root: Node3D = $RabbitRoot

var _debug_overlay: Node3D = null
var _smell_debug_root: Node3D = null
var _wind_debug_root: Node3D = null
var _temperature_debug_root: Node3D = null
var _smell_emit_accumulator: float = 0.0
var _seed_sequence: int = 0
var _smell_field
var _wind_field
var _smell_debug_nodes: Dictionary = {}
var _wind_debug_nodes: Dictionary = {}
var _temperature_debug_nodes: Dictionary = {}
var _smell_field_texture: ImageTexture = null
var _sim_time_seconds: float = 0.0

func _ready() -> void:
	_smell_field = SmellFieldSystemScript.new()
	_wind_field = WindFieldSystemScript.new()
	if grid_config == null:
		grid_config = GridConfigResourceScript.new()
		grid_config.set("grid_layout", "hex_pointy")
		grid_config.set("half_extent", world_bounds_radius)
		grid_config.set("cell_size", smell_hex_size)
	_smell_field.configure_from_grid(grid_config)
	_wind_field.configure_from_grid(grid_config)
	_wind_field.set_global_wind(wind_direction, wind_intensity, wind_speed)
	_spawn_initial_plants(initial_plant_count)
	_spawn_initial_rabbits(initial_rabbit_count)
	_update_smell_field_texture()

func spawn_plant_at(world_position: Vector3, initial_growth_ratio: float = 0.0) -> Node3D:
	var plant = PlantScene.instantiate()
	plant_root.add_child(plant)
	plant.global_position = _clamp_to_field(world_position, 0.14)
	if plant.has_method("set_initial_growth_ratio"):
		plant.call("set_initial_growth_ratio", initial_growth_ratio)
	return plant

func spawn_rabbit_at(world_position: Vector3) -> Node3D:
	var rabbit = RabbitScene.instantiate()
	rabbit.rabbit_id = "rabbit_%d" % int(Time.get_ticks_usec() % 10000000)
	rabbit_root.add_child(rabbit)
	rabbit.global_position = _clamp_to_field(world_position, 0.18)
	rabbit.seed_dropped.connect(_on_rabbit_seed_dropped)
	return rabbit

func spawn_random(plants: int, rabbits: int) -> void:
	for i in range(maxi(0, plants)):
		_seed_sequence += 1
		spawn_plant_at(_deterministic_spawn_point(_seed_sequence, world_bounds_radius * 0.95), float((_seed_sequence + i) % 6) / 6.0)
	for j in range(maxi(0, rabbits)):
		_seed_sequence += 1
		spawn_rabbit_at(_deterministic_spawn_point(_seed_sequence * 2, world_bounds_radius * 0.75))

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_sim_time_seconds += delta
	_step_plants(delta)
	_emit_smell(delta)
	_step_smell_field(delta)
	_step_rabbits(delta)
	_sync_debug_visibility()
	_refresh_smell_debug()
	_refresh_wind_temperature_debug()
	_update_smell_field_texture()

func set_debug_overlay(overlay: Node3D) -> void:
	_debug_overlay = overlay
	if overlay != null and overlay.has_node("SmellDebug"):
		_smell_debug_root = overlay.get_node("SmellDebug")
	if overlay != null and overlay.has_node("WindDebug"):
		_wind_debug_root = overlay.get_node("WindDebug")
	if overlay != null and overlay.has_node("TemperatureDebug"):
		_temperature_debug_root = overlay.get_node("TemperatureDebug")

func set_rain_intensity(next_rain_intensity: float) -> void:
	rain_intensity = clampf(next_rain_intensity, 0.0, 1.0)

func set_wind(next_direction: Vector3, next_intensity: float, enabled: bool = true) -> void:
	wind_direction = next_direction
	wind_intensity = clampf(next_intensity, 0.0, 1.0)
	wind_enabled = enabled
	if _wind_field != null:
		_wind_field.set_global_wind(wind_direction, wind_intensity if wind_enabled else 0.0, wind_speed)

func smell_field_texture() -> ImageTexture:
	return _smell_field_texture

func clear_generated() -> void:
	for child in plant_root.get_children():
		child.queue_free()
	for child in rabbit_root.get_children():
		child.queue_free()
	for key in _smell_debug_nodes.keys():
		var node = _smell_debug_nodes[key]
		if is_instance_valid(node):
			node.queue_free()
	_smell_debug_nodes.clear()
	for key in _wind_debug_nodes.keys():
		var wind_node = _wind_debug_nodes[key]
		if is_instance_valid(wind_node):
			wind_node.queue_free()
	_wind_debug_nodes.clear()
	for key in _temperature_debug_nodes.keys():
		var temp_node = _temperature_debug_nodes[key]
		if is_instance_valid(temp_node):
			temp_node.queue_free()
	_temperature_debug_nodes.clear()
	if _smell_field != null:
		_smell_field.clear()
	_update_smell_field_texture()

func _spawn_initial_plants(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		var ring := 2.4 + 1.8 * float(i % 3)
		spawn_plant_at(Vector3(cos(angle) * ring, 0.14, sin(angle) * ring), float(i % 5) / 5.0)

func _spawn_initial_rabbits(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		var rabbit = spawn_rabbit_at(Vector3(cos(angle) * 1.8, 0.18, sin(angle) * 1.8))
		rabbit.rabbit_id = "rabbit_%d" % i

func _step_plants(delta: float) -> void:
	for plant in plant_root.get_children():
		if is_instance_valid(plant) and plant.has_method("simulation_step"):
			plant.call("simulation_step", delta)

func _emit_smell(delta: float) -> void:
	_smell_emit_accumulator += delta
	if _smell_emit_accumulator < smell_emit_interval_seconds:
		return
	_smell_emit_accumulator = 0.0
	for source in get_tree().get_nodes_in_group("living_smell_source"):
		if not is_instance_valid(source) or not source.has_method("get_smell_source_payload"):
			continue
		var payload: Dictionary = source.call("get_smell_source_payload")
		if payload.is_empty():
			continue
		_smell_field.deposit(
			String(payload.get("kind", "")),
			Vector3(payload.get("position", Vector3.ZERO)),
			float(payload.get("strength", 0.0))
		)

func _step_smell_field(delta: float) -> void:
	var wind_source: Variant = Vector2.ZERO
	if wind_enabled and wind_intensity > 0.0 and _wind_field != null:
		_wind_field.set_global_wind(wind_direction, wind_intensity, wind_speed)
		var diurnal_phase = fmod(_sim_time_seconds / 24.0, TAU)
		_wind_field.step(delta, 0.52, diurnal_phase, rain_intensity)
		wind_source = Callable(_wind_field, "sample_wind")
	_smell_field.step(delta, wind_source, smell_base_decay_per_second, rain_intensity, rain_decay_multiplier)

func _step_rabbits(delta: float) -> void:
	for rabbit in rabbit_root.get_children():
		if not is_instance_valid(rabbit):
			continue
		var danger: Dictionary = _smell_field.perceived_danger(rabbit.global_position)
		if float(danger.get("score", 0.0)) >= rabbit_perceived_danger_threshold:
			var danger_pos = danger.get("position", null)
			if danger_pos != null:
				rabbit.trigger_flee(danger_pos, rabbit_flee_duration_seconds)
		elif not rabbit.is_fleeing():
			var food = _smell_field.strongest_food_position(rabbit.global_position)
			if food != null:
				rabbit.set_food_target(food)
			else:
				rabbit.clear_food_target()
		rabbit.simulation_step(delta)
		_try_eat_nearby_plant(rabbit)
		_keep_inside_bounds(rabbit)

func _try_eat_nearby_plant(rabbit: Node3D) -> void:
	for plant in plant_root.get_children():
		if not is_instance_valid(plant) or not plant.has_method("is_edible"):
			continue
		if not bool(plant.call("is_edible")):
			continue
		var distance := rabbit.global_position.distance_to(plant.global_position)
		if distance > rabbit_eat_distance:
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

func _find_rabbit_by_id(rabbit_id: String) -> Node3D:
	for rabbit in rabbit_root.get_children():
		if String(rabbit.get("rabbit_id")) == rabbit_id:
			return rabbit
	return null

func _keep_inside_bounds(rabbit: Node3D) -> void:
	var planar := Vector2(rabbit.global_position.x, rabbit.global_position.z)
	var distance := planar.length()
	if distance <= world_bounds_radius:
		return
	var clamped := planar.normalized() * world_bounds_radius
	rabbit.global_position = Vector3(clamped.x, rabbit.global_position.y, clamped.y)

func _refresh_smell_debug() -> void:
	if _smell_debug_root == null:
		return
	var cells: Array = _smell_field.build_debug_cells()
	var active: Dictionary = {}
	for cell_variant in cells:
		var cell: Dictionary = cell_variant
		var key := String(cell.get("key", ""))
		active[key] = true
		var node = _smell_debug_nodes.get(key, null)
		if node == null or not is_instance_valid(node):
			node = MeshInstance3D.new()
			var mesh := SphereMesh.new()
			mesh.radius = 0.055
			mesh.height = 0.11
			node.mesh = mesh
			var material := StandardMaterial3D.new()
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			node.material_override = material
			_smell_debug_root.add_child(node)
			_smell_debug_nodes[key] = node
		var total := clampf(float(cell.get("total", 0.0)) / 1.5, 0.0, 1.0)
		var color := Color(
			clampf(float(cell.get("danger", 0.0)) / 1.2, 0.0, 1.0),
			clampf(float(cell.get("food", 0.0)) / 1.2, 0.0, 1.0),
			clampf(float(cell.get("rabbit", 0.0)) / 1.2, 0.0, 1.0),
			clampf(0.18 + total * 0.45, 0.0, 0.75)
		)
		if node.material_override is StandardMaterial3D:
			node.material_override.albedo_color = color
		node.position = Vector3(cell.get("world", Vector3.ZERO))
	for key in _smell_debug_nodes.keys():
		if active.has(String(key)):
			continue
		var stale = _smell_debug_nodes[key]
		if is_instance_valid(stale):
			stale.queue_free()
		_smell_debug_nodes.erase(key)

func _sync_debug_visibility() -> void:
	if _smell_debug_root == null:
		return
	var visible := smell_debug_enabled
	if _debug_overlay != null:
		visible = visible and bool(_debug_overlay.get("show_smell"))
	_smell_debug_root.visible = visible
	if _wind_debug_root != null:
		var show_wind = _debug_overlay == null or bool(_debug_overlay.get("show_wind"))
		_wind_debug_root.visible = smell_debug_enabled and show_wind
	if _temperature_debug_root != null:
		var show_temp = _debug_overlay == null or bool(_debug_overlay.get("show_temperature"))
		_temperature_debug_root.visible = smell_debug_enabled and show_temp

func _refresh_wind_temperature_debug() -> void:
	if _wind_field == null:
		return
	if _wind_debug_root == null and _temperature_debug_root == null:
		return
	var vectors: Array = _wind_field.build_debug_vectors()
	var active: Dictionary = {}
	for row_variant in vectors:
		var row: Dictionary = row_variant
		var key = String(row.get("key", ""))
		active[key] = true
		var world = Vector3(row.get("world", Vector3.ZERO))
		var wind_vec = Vector2(row.get("wind", Vector2.ZERO))
		var speed = float(row.get("speed", 0.0))
		var temp = clampf(float(row.get("temperature", 0.0)), 0.0, 1.0)
		if _wind_debug_root != null:
			var wind_node = _wind_debug_nodes.get(key, null)
			if wind_node == null or not is_instance_valid(wind_node):
				wind_node = MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(0.06, 0.06, 0.52)
				wind_node.mesh = box
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				wind_node.material_override = mat
				_wind_debug_root.add_child(wind_node)
				_wind_debug_nodes[key] = wind_node
			wind_node.position = world
			var dir = Vector3(wind_vec.x, 0.0, wind_vec.y)
			if dir.length_squared() > 0.000001:
				wind_node.look_at(world + dir, Vector3.UP, true)
			var wind_len = clampf(0.14 + speed * 0.3, 0.14, 0.9)
			wind_node.scale = Vector3(1.0, 1.0, wind_len)
			if wind_node.material_override is StandardMaterial3D:
				wind_node.material_override.albedo_color = Color(0.2, 0.65 + minf(0.35, speed * 0.2), 0.95, 0.9)
		if _temperature_debug_root != null:
			var temp_node = _temperature_debug_nodes.get(key, null)
			if temp_node == null or not is_instance_valid(temp_node):
				temp_node = MeshInstance3D.new()
				var sphere := SphereMesh.new()
				sphere.radius = 0.04
				sphere.height = 0.08
				temp_node.mesh = sphere
				var tmat := StandardMaterial3D.new()
				tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				temp_node.material_override = tmat
				_temperature_debug_root.add_child(temp_node)
				_temperature_debug_nodes[key] = temp_node
			temp_node.position = world + Vector3(0.0, 0.12, 0.0)
			if temp_node.material_override is StandardMaterial3D:
				temp_node.material_override.albedo_color = Color(temp, 0.15 + (1.0 - temp) * 0.35, 1.0 - temp, 0.68)
	for key in _wind_debug_nodes.keys():
		if active.has(String(key)):
			continue
		var node = _wind_debug_nodes[key]
		if is_instance_valid(node):
			node.queue_free()
		_wind_debug_nodes.erase(key)
	for key in _temperature_debug_nodes.keys():
		if active.has(String(key)):
			continue
		var tnode = _temperature_debug_nodes[key]
		if is_instance_valid(tnode):
			tnode.queue_free()
		_temperature_debug_nodes.erase(key)

func _update_smell_field_texture() -> void:
	if _smell_field == null:
		return
	var image: Image = _smell_field.to_image()
	if _smell_field_texture == null:
		_smell_field_texture = ImageTexture.create_from_image(image)
		return
	_smell_field_texture.update(image)

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
