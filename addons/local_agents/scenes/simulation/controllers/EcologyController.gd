extends Node3D

const PlantScene = preload("res://addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.tscn")
const RabbitScene = preload("res://addons/local_agents/scenes/simulation/actors/RabbitSphere.tscn")
const SmellFieldSystemScript = preload("res://addons/local_agents/simulation/SmellFieldSystem.gd")

@export var initial_plant_count: int = 14
@export var initial_rabbit_count: int = 4
@export var world_bounds_radius: float = 8.0
@export var smell_hex_size: float = 0.55
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
var _smell_emit_accumulator: float = 0.0
var _seed_sequence: int = 0
var _smell_field
var _smell_debug_nodes: Dictionary = {}
var _smell_field_texture: ImageTexture = null

func _ready() -> void:
	_smell_field = SmellFieldSystemScript.new()
	_smell_field.configure(world_bounds_radius, smell_hex_size)
	_spawn_initial_plants(initial_plant_count)
	_spawn_initial_rabbits(initial_rabbit_count)
	_update_smell_field_texture()

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_step_plants(delta)
	_emit_smell(delta)
	_step_smell_field(delta)
	_step_rabbits(delta)
	_sync_debug_visibility()
	_refresh_smell_debug()
	_update_smell_field_texture()

func set_debug_overlay(overlay: Node3D) -> void:
	_debug_overlay = overlay
	if overlay != null and overlay.has_node("SmellDebug"):
		_smell_debug_root = overlay.get_node("SmellDebug")

func set_rain_intensity(next_rain_intensity: float) -> void:
	rain_intensity = clampf(next_rain_intensity, 0.0, 1.0)

func set_wind(next_direction: Vector3, next_intensity: float, enabled: bool = true) -> void:
	wind_direction = next_direction
	wind_intensity = clampf(next_intensity, 0.0, 1.0)
	wind_enabled = enabled

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
	if _smell_field != null:
		_smell_field.clear()
	_update_smell_field_texture()

func _spawn_initial_plants(count: int) -> void:
	for i in range(count):
		var plant = PlantScene.instantiate()
		var angle := TAU * float(i) / float(maxi(1, count))
		var ring := 2.4 + 1.8 * float(i % 3)
		plant.global_position = Vector3(cos(angle) * ring, 0.14, sin(angle) * ring)
		if plant.has_method("set_initial_growth_ratio"):
			plant.call("set_initial_growth_ratio", float(i % 5) / 5.0)
		plant_root.add_child(plant)

func _spawn_initial_rabbits(count: int) -> void:
	for i in range(count):
		var rabbit = RabbitScene.instantiate()
		rabbit.rabbit_id = "rabbit_%d" % i
		var angle := TAU * float(i) / float(maxi(1, count))
		rabbit.global_position = Vector3(cos(angle) * 1.8, 0.18, sin(angle) * 1.8)
		rabbit.seed_dropped.connect(_on_rabbit_seed_dropped)
		rabbit_root.add_child(rabbit)

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
	var wind_vec := Vector2.ZERO
	if wind_enabled and wind_intensity > 0.0:
		var norm := wind_direction.normalized()
		wind_vec = Vector2(norm.x, norm.z) * wind_intensity * wind_speed
	_smell_field.step(delta, wind_vec, smell_base_decay_per_second, rain_intensity, rain_decay_multiplier)

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
		var plant = PlantScene.instantiate()
		plant.global_position = rabbit.global_position + spawn_offset
		plant_root.add_child(plant)

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

func _update_smell_field_texture() -> void:
	if _smell_field == null:
		return
	var image: Image = _smell_field.to_image()
	if _smell_field_texture == null:
		_smell_field_texture = ImageTexture.create_from_image(image)
		return
	_smell_field_texture.update(image)
