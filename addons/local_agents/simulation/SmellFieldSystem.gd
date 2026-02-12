extends RefCounted
class_name LocalAgentsSmellFieldSystem

const SmellFieldResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SmellFieldResource.gd")
const GridConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GridConfigResource.gd")
const HexGridHierarchySystemScript = preload("res://addons/local_agents/simulation/HexGridHierarchySystem.gd")

var _field: Resource = SmellFieldResourceScript.new()
var _grid_config: Resource = GridConfigResourceScript.new()
var _grid_system = HexGridHierarchySystemScript.new()

func configure(half_extent: float, hex_size: float) -> void:
	_grid_config.set("grid_layout", "hex_pointy")
	_grid_config.set("half_extent", maxf(1.0, half_extent))
	_grid_config.set("cell_size", maxf(0.1, hex_size))
	_grid_system.setup(
		_grid_config,
		int(_field.get("lod_levels")),
		int(_field.get("subdivision_ratio")),
		float(_field.get("subdivision_trigger_strength"))
	)
	_field.call("setup_from_grid_config", _grid_config)
	_sync_field_snapshot()

func configure_from_grid(grid_config: Resource) -> void:
	if grid_config == null:
		return
	_grid_config = grid_config
	_grid_system.setup(
		_grid_config,
		int(_field.get("lod_levels")),
		int(_field.get("subdivision_ratio")),
		float(_field.get("subdivision_trigger_strength"))
	)
	_field.call("setup_from_grid_config", _grid_config)
	_sync_field_snapshot()

func clear() -> void:
	_grid_system.clear_all()
	_field.call("clear_channels")

func field() -> Resource:
	_sync_field_snapshot()
	return _field

func hierarchy_snapshot() -> Dictionary:
	return _grid_system.snapshot()

func deposit(kind: String, world_position: Vector3, strength: float) -> void:
	var channel = _channel_for_kind(kind)
	_grid_system.deposit(channel, world_position, maxf(0.0, strength))

func step(delta: float, wind_world: Vector2, base_decay_per_second: float, rain_intensity: float, rain_decay_multiplier: float) -> void:
	if delta <= 0.0:
		return
	var decay = base_decay_per_second * (1.0 + rain_intensity * rain_decay_multiplier)
	var decay_factor = clampf(1.0 - decay * delta, 0.0, 1.0)
	for channel in ["food", "rabbit", "danger"]:
		_grid_system.advect_and_decay_layer(String(channel), delta, decay_factor, wind_world)
	_sync_field_snapshot()

func strongest_food_position(origin: Vector3, sample_radius_cells: int = 8) -> Variant:
	return _grid_system.strongest_layer_position("food", origin, sample_radius_cells)

func perceived_danger(origin: Vector3, sample_radius_cells: int = 4) -> Dictionary:
	return _grid_system.strongest_layer_score("danger", origin, sample_radius_cells)

func world_to_cell(world_position: Vector3) -> Vector2i:
	return _grid_system.world_to_cell_level(world_position, 0)

func cell_to_world(x: int, y: int) -> Vector3:
	var world = _grid_system.cell_to_world_level(x, y, 0)
	return Vector3(world.x, 0.15, world.y)

func build_debug_cells(min_strength: float = 0.03, max_cells: int = 350) -> Array[Dictionary]:
	var cells = _grid_system.build_debug_cells(["food", "rabbit", "danger"], min_strength, max_cells)
	for i in range(cells.size()):
		var cell: Dictionary = cells[i]
		cell["food"] = float(cell.get("food", 0.0))
		cell["rabbit"] = float(cell.get("rabbit", 0.0))
		cell["danger"] = float(cell.get("danger", 0.0))
		cells[i] = cell
	return cells

func to_image() -> Image:
	_sync_field_snapshot()
	var width = int(_field.get("width"))
	var height = int(_field.get("height"))
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var food_channel: PackedFloat32Array = _field.get("food_channel")
	var rabbit_channel: PackedFloat32Array = _field.get("rabbit_channel")
	var danger_channel: PackedFloat32Array = _field.get("danger_channel")
	for y in range(height):
		for x in range(width):
			var index = (y * width) + x
			var danger = clampf(float(danger_channel[index]) / 1.5, 0.0, 1.0)
			var food = clampf(float(food_channel[index]) / 1.5, 0.0, 1.0)
			var rabbit = clampf(float(rabbit_channel[index]) / 1.5, 0.0, 1.0)
			var alpha = clampf(maxf(maxf(danger, food), rabbit), 0.0, 1.0)
			image.set_pixel(x, y, Color(danger, food, rabbit, alpha))
	return image

func _channel_for_kind(kind: String) -> String:
	match kind:
		"plant_food":
			return "food"
		"rabbit":
			return "rabbit"
		_:
			return "danger"

func _sync_field_snapshot() -> void:
	var snapshot: Dictionary = _grid_system.snapshot()
	var grid: Dictionary = snapshot.get("grid", {})
	var base_layers: Dictionary = snapshot.get("base_layers", {})
	_field.set("grid_layout", String(grid.get("layout", "hex_pointy")))
	_field.set("half_extent", float(grid.get("half_extent", 10.0)))
	_field.set("hex_size", float(grid.get("cell_size", 0.45)))
	_field.set("width", int(grid.get("width", 0)))
	_field.set("height", int(grid.get("height", 0)))
	_field.set("lod_levels", int(grid.get("lod_levels", 1)))
	_field.set("subdivision_ratio", int(grid.get("subdivision_ratio", 2)))
	_field.set("subdivision_trigger_strength", float(grid.get("subdivision_trigger_strength", 0.55)))
	_field.set("food_channel", base_layers.get("food", PackedFloat32Array()))
	_field.set("rabbit_channel", base_layers.get("rabbit", PackedFloat32Array()))
	_field.set("danger_channel", base_layers.get("danger", PackedFloat32Array()))
	_field.set("sparse_layers", snapshot.get("sparse_layers", {}).duplicate(true))
