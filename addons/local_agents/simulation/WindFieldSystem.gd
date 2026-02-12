extends RefCounted
class_name LocalAgentsWindFieldSystem

const GridConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GridConfigResource.gd")
const HexGridHierarchySystemScript = preload("res://addons/local_agents/simulation/HexGridHierarchySystem.gd")

var _grid_config: Resource = GridConfigResourceScript.new()
var _grid_system = HexGridHierarchySystemScript.new()
var _base_direction: Vector2 = Vector2(1.0, 0.0)
var _base_intensity: float = 0.0
var _base_speed: float = 1.0
var _terrain_seed: float = 37.0
var _temperature_layers: Dictionary = {}
var _current_wind_layers: Dictionary = {}

const TEMP_LAYER_PREFIX = "temperature_l"
const WIND_X_LAYER_PREFIX = "wind_x_l"
const WIND_Y_LAYER_PREFIX = "wind_y_l"

func configure_from_grid(grid_config: Resource) -> void:
	if grid_config != null:
		_grid_config = grid_config
	_grid_system.setup(_grid_config, 3, 2, 0.55)
	_temperature_layers.clear()
	_current_wind_layers.clear()
	_initialize_temperature_layers()
	_step_wind_from_temperature(1.0)

func set_global_wind(direction: Vector3, intensity: float, speed: float) -> void:
	var d2 = Vector2(direction.x, direction.z)
	if d2.length_squared() <= 0.000001:
		d2 = Vector2(1.0, 0.0)
	_base_direction = d2.normalized()
	_base_intensity = clampf(intensity, 0.0, 1.0)
	_base_speed = maxf(0.0, speed)

func step(delta: float, ambient_temp: float = 0.5, diurnal_phase: float = 0.0, rain_intensity: float = 0.0) -> void:
	if delta <= 0.0:
		return
	_update_temperature_layers(delta, ambient_temp, diurnal_phase, rain_intensity)
	_step_wind_from_temperature(delta)

func sample_wind(world_position: Vector3) -> Vector2:
	var level = _detail_level_for_position(world_position)
	var wx = _grid_system.sample_layer_at_world(_wind_x_layer(level), world_position)
	var wy = _grid_system.sample_layer_at_world(_wind_y_layer(level), world_position)
	return Vector2(wx, wy)

func sample_temperature(world_position: Vector3) -> float:
	var level = _detail_level_for_position(world_position)
	return _grid_system.sample_layer_at_world(_temp_layer(level), world_position)

func snapshot() -> Dictionary:
	return {
		"grid": _grid_system.snapshot(),
		"temperature_layers": _temperature_layers.duplicate(true),
		"wind_layers": _current_wind_layers.duplicate(true),
	}

func _initialize_temperature_layers() -> void:
	for level in range(3):
		var temp_layer = _temp_layer(level)
		_temperature_layers[temp_layer] = true
		for y in range(0, 18):
			for x in range(0, 18):
				var world = _grid_system.cell_to_world_level(x, y, 0)
				var world_pos = Vector3(world.x, 0.0, world.y)
				var base_temp = _initial_temp(world_pos)
				_grid_system.deposit(temp_layer, world_pos, base_temp)

func _update_temperature_layers(delta: float, ambient_temp: float, diurnal_phase: float, rain_intensity: float) -> void:
	for level in range(3):
		var layer = _temp_layer(level)
		var relaxed_ambient = clampf(ambient_temp + 0.12 * sin(diurnal_phase + float(level) * 0.5), 0.05, 1.0)
		_grid_system.advect_and_decay_layer(layer, delta, clampf(1.0 - (0.02 + rain_intensity * 0.03) * delta, 0.90, 1.0), Vector2.ZERO)
		for y in range(0, 18):
			for x in range(0, 18):
				var world = _grid_system.cell_to_world_level(x, y, 0)
				var world_pos = Vector3(world.x, 0.0, world.y)
				var current = _grid_system.sample_layer_at_world(layer, world_pos)
				var terrain = _terrain_height(world)
				var terrain_temp_shift = -0.18 * terrain
				var target = clampf(relaxed_ambient + terrain_temp_shift, 0.0, 1.0)
				var delta_t = (target - current) * (0.06 + float(level) * 0.015)
				if absf(delta_t) > 0.0001:
					_grid_system.deposit(layer, world_pos, maxf(0.0, delta_t))

func _step_wind_from_temperature(delta: float) -> void:
	for level in range(3):
		var wind_x = _wind_x_layer(level)
		var wind_y = _wind_y_layer(level)
		_current_wind_layers[wind_x] = true
		_current_wind_layers[wind_y] = true
		_grid_system.clear_layer(wind_x)
		_grid_system.clear_layer(wind_y)
		for y in range(0, 18):
			for x in range(0, 18):
				var world = _grid_system.cell_to_world_level(x, y, 0)
				var world_pos = Vector3(world.x, 0.0, world.y)
				var pressure_gradient = _pressure_gradient(world_pos, level)
				var pg_force = pressure_gradient * (0.85 + float(level) * 0.1)
				var valley_dir = _valley_axis(world)
				var valley_align = valley_dir.dot(_base_direction)
				var valley_channel_force = valley_dir * valley_align * (0.2 + float(level) * 0.05)
				var terrain_drag = clampf(0.25 + absf(_terrain_height(world)) * 0.35, 0.2, 0.8)
				var base = _base_direction * (_base_intensity * _base_speed)
				var wind = (base + pg_force + valley_channel_force) * (1.0 - terrain_drag * 0.35)
				var prev = Vector2(
					_grid_system.sample_layer_at_world(wind_x, world_pos),
					_grid_system.sample_layer_at_world(wind_y, world_pos)
				)
				var relaxed = prev.lerp(wind, clampf(0.15 * delta + 0.08, 0.05, 0.35))
				if relaxed.x > 0.0:
					_grid_system.deposit(wind_x, world_pos, relaxed.x)
				if relaxed.y > 0.0:
					_grid_system.deposit(wind_y, world_pos, relaxed.y)

func _pressure_gradient(world_position: Vector3, level: int) -> Vector2:
	var offset = maxf(0.2, float(_grid_config.get("cell_size")) * (1.0 + float(level) * 0.4))
	var east = _grid_system.sample_layer_at_world(_temp_layer(level), world_position + Vector3(offset, 0.0, 0.0))
	var west = _grid_system.sample_layer_at_world(_temp_layer(level), world_position - Vector3(offset, 0.0, 0.0))
	var north = _grid_system.sample_layer_at_world(_temp_layer(level), world_position + Vector3(0.0, 0.0, offset))
	var south = _grid_system.sample_layer_at_world(_temp_layer(level), world_position - Vector3(0.0, 0.0, offset))
	var dtx = east - west
	var dty = north - south
	# Warm air lowers pressure: wind accelerates toward lower pressure (toward warmer gradient).
	return Vector2(dtx, dty) * 0.5

func _detail_level_for_position(world_position: Vector3) -> int:
	var ridge = absf(_ridge_signal(Vector2(world_position.x, world_position.z)))
	var valley = 1.0 - ridge
	if valley > 0.72:
		return 2
	if valley > 0.45:
		return 1
	return 0

func _initial_temp(world_position: Vector3) -> float:
	var world2 = Vector2(world_position.x, world_position.z)
	var large_scale = 0.5 + 0.18 * sin((world2.x + _terrain_seed) * 0.045)
	var small_scale = 0.14 * cos((world2.y - _terrain_seed) * 0.08)
	var terrain = _terrain_height(world2)
	return clampf(large_scale + small_scale - 0.22 * terrain, 0.05, 1.0)

func _terrain_height(world: Vector2) -> float:
	return sin((world.x + _terrain_seed) * 0.11) * 0.55 + cos((world.y - _terrain_seed) * 0.13) * 0.45

func _valley_axis(world: Vector2) -> Vector2:
	var angle = sin((world.x + _terrain_seed) * 0.09) * 1.3 + cos((world.y - _terrain_seed) * 0.07) * 0.9
	return Vector2(cos(angle), sin(angle)).normalized()

func _ridge_signal(world: Vector2) -> float:
	return sin((world.x + _terrain_seed) * 0.11) * 0.55 + cos((world.y - _terrain_seed) * 0.13) * 0.45

func _temp_layer(level: int) -> String:
	return "%s%d" % [TEMP_LAYER_PREFIX, level]

func _wind_x_layer(level: int) -> String:
	return "%s%d" % [WIND_X_LAYER_PREFIX, level]

func _wind_y_layer(level: int) -> String:
	return "%s%d" % [WIND_Y_LAYER_PREFIX, level]
