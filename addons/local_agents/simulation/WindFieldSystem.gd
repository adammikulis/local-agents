extends RefCounted
class_name LocalAgentsWindFieldSystem

const VoxelGridSystemScript = preload("res://addons/local_agents/simulation/VoxelGridSystem.gd")

var _grid = VoxelGridSystemScript.new()
var _base_direction: Vector2 = Vector2(1.0, 0.0)
var _base_intensity: float = 0.0
var _base_speed: float = 1.0
var _terrain_seed: float = 37.0

var _temperature: Dictionary = {}
var _wind: Dictionary = {}

func configure(half_extent: float, voxel_size: float, vertical_half_extent: float = 3.0) -> void:
	_grid.configure(half_extent, voxel_size, vertical_half_extent)
	_temperature.clear()
	_wind.clear()
	for voxel in _grid.all_voxels():
		_temperature[voxel] = _initial_temp(voxel)
		_wind[voxel] = _base_direction * (_base_intensity * _base_speed)

func set_global_wind(direction: Vector3, intensity: float, speed: float) -> void:
	var planar := Vector2(direction.x, direction.z)
	if planar.length_squared() <= 0.000001:
		planar = Vector2(1.0, 0.0)
	_base_direction = planar.normalized()
	_base_intensity = clampf(intensity, 0.0, 1.0)
	_base_speed = maxf(0.0, speed)

func step(
	delta: float,
	ambient_temp: float = 0.5,
	diurnal_phase: float = 0.0,
	rain_intensity: float = 0.0,
	solar_context: Dictionary = {}
) -> void:
	if delta <= 0.0:
		return
	if _temperature.is_empty():
		configure(_grid.half_extent(), _grid.voxel_size(), _grid.vertical_half_extent())
	var next_temp := {}
	var next_wind := {}
	var keys := _grid.sort_voxel_keys(_temperature.keys())
	var sun_altitude = clampf(float(solar_context.get("sun_altitude", 0.0)), 0.0, 1.0)
	var avg_insolation = clampf(float(solar_context.get("avg_insolation", 0.0)), 0.0, 1.0)
	var avg_uv = clampf(float(solar_context.get("avg_uv_index", 0.0)), 0.0, 2.0)
	var avg_heat = clampf(float(solar_context.get("avg_heat_load", 0.0)), 0.0, 1.5)
	var air_heating_scalar = clampf(float(solar_context.get("air_heating_scalar", 1.0)), 0.2, 2.0)
	var vertical_extent = maxf(_grid.voxel_size(), _grid.vertical_half_extent())
	var uv_norm = clampf(avg_uv / 1.6, 0.0, 1.0)
	for voxel_variant in keys:
		var voxel: Vector3i = voxel_variant
		var temp := float(_temperature.get(voxel, 0.5))
		var terrain := _terrain_height(voxel)
		var y_world = float(voxel.y) * _grid.voxel_size()
		var y_norm = clampf((y_world + vertical_extent) / (vertical_extent * 2.0), 0.0, 1.0)
		var near_ground = clampf(1.0 - y_norm * 0.72, 0.0, 1.0)
		var lapse = (y_norm - 0.5) * 0.24
		var diurnal = 0.1 * sin(diurnal_phase + float(voxel.x) * 0.07)
		var solar_ground_heat = sun_altitude * avg_insolation * (0.12 + avg_heat * 0.08) * near_ground * air_heating_scalar
		var uv_air_heat = sun_altitude * uv_norm * 0.05 * clampf(y_norm * 1.2, 0.1, 1.0) * air_heating_scalar
		var evaporative_cooling = rain_intensity * 0.1 * near_ground
		var target_temp := clampf(
			ambient_temp + diurnal - terrain * 0.2 - lapse + solar_ground_heat + uv_air_heat - evaporative_cooling,
			0.0,
			1.2
		)
		var relaxation := clampf(0.1 * delta * (1.0 - rain_intensity * 0.35), 0.01, 0.35)
		var updated_temp := lerpf(temp, target_temp, relaxation)
		var below = float(_temperature.get(Vector3i(voxel.x, voxel.y - 1, voxel.z), updated_temp))
		var above = float(_temperature.get(Vector3i(voxel.x, voxel.y + 1, voxel.z), updated_temp))
		var vertical_mix = (below + above - updated_temp * 2.0) * 0.08 * delta
		updated_temp = clampf(updated_temp + vertical_mix, 0.0, 1.2)
		next_temp[voxel] = updated_temp

	for voxel_variant in keys:
		var voxel: Vector3i = voxel_variant
		var gradient := _temperature_gradient(voxel, next_temp)
		var terrain_channel := _valley_axis(voxel)
		var base := _base_direction * (_base_intensity * _base_speed)
		var thermals := gradient * (0.65 + (1.0 - rain_intensity) * 0.25)
		var channeling := terrain_channel * terrain_channel.dot(_base_direction) * 0.22
		var drag := clampf(0.18 + absf(_terrain_height(voxel)) * 0.3 + rain_intensity * 0.22, 0.1, 0.85)
		var computed := (base + thermals + channeling) * (1.0 - drag * 0.4)
		var prev: Vector2 = _wind.get(voxel, Vector2.ZERO)
		next_wind[voxel] = prev.lerp(computed, clampf(0.12 + delta * 0.2, 0.08, 0.5))

	_temperature = next_temp
	_wind = next_wind

func sample_wind(world_position: Vector3) -> Vector2:
	var voxel := _grid.world_to_voxel(world_position)
	if voxel == _grid.invalid_voxel():
		return Vector2.ZERO
	var base: Vector2 = _wind.get(Vector3i(voxel.x, 0, voxel.z), Vector2.ZERO)
	return base

func sample_temperature(world_position: Vector3) -> float:
	var voxel := _grid.world_to_voxel(world_position)
	if voxel == _grid.invalid_voxel():
		return 0.0
	return float(_temperature.get(Vector3i(voxel.x, 0, voxel.z), 0.0))

func build_debug_vectors(max_cells: int = 260, min_speed: float = 0.03) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for voxel_variant in _grid.sort_voxel_keys(_wind.keys()):
		var voxel: Vector3i = voxel_variant
		var wind: Vector2 = _wind.get(voxel, Vector2.ZERO)
		var speed := wind.length()
		if speed < min_speed:
			continue
		rows.append({
			"voxel": voxel,
			"world": _grid.voxel_to_world(voxel),
			"wind": wind,
			"speed": speed,
			"temperature": float(_temperature.get(voxel, 0.0)),
		})
	if rows.size() <= max_cells:
		return rows
	rows.sort_custom(func(a, b): return float(a.get("speed", 0.0)) > float(b.get("speed", 0.0)))
	rows.resize(max_cells)
	return rows

func build_temperature_cells(max_cells: int = 520, min_temperature: float = 0.02) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for voxel_variant in _grid.sort_voxel_keys(_temperature.keys()):
		var voxel: Vector3i = voxel_variant
		var temp := float(_temperature.get(voxel, 0.0))
		if temp < min_temperature:
			continue
		rows.append({
			"voxel": voxel,
			"world": _grid.voxel_to_world(voxel),
			"temperature": temp,
		})
	if rows.size() <= max_cells:
		return rows
	rows.sort_custom(func(a, b): return float(a.get("temperature", 0.0)) > float(b.get("temperature", 0.0)))
	rows.resize(max_cells)
	return rows

func snapshot() -> Dictionary:
	var temp_rows: Array[Dictionary] = []
	for voxel_variant in _grid.sort_voxel_keys(_temperature.keys()):
		var voxel: Vector3i = voxel_variant
		temp_rows.append({"x": voxel.x, "y": voxel.y, "z": voxel.z, "t": float(_temperature[voxel])})
	var wind_rows: Array[Dictionary] = []
	for voxel_variant in _grid.sort_voxel_keys(_wind.keys()):
		var voxel: Vector3i = voxel_variant
		var w: Vector2 = _wind[voxel]
		wind_rows.append({"x": voxel.x, "y": voxel.y, "z": voxel.z, "wx": w.x, "wz": w.y})
	return {
		"mode": "sparse_voxel",
		"half_extent": _grid.half_extent(),
		"voxel_size": _grid.voxel_size(),
		"temperature": temp_rows,
		"wind": wind_rows,
	}

func _temperature_gradient(voxel: Vector3i, temperature_map: Dictionary) -> Vector2:
	var east := float(temperature_map.get(Vector3i(voxel.x + 1, 0, voxel.z), temperature_map.get(voxel, 0.0)))
	var west := float(temperature_map.get(Vector3i(voxel.x - 1, 0, voxel.z), temperature_map.get(voxel, 0.0)))
	var north := float(temperature_map.get(Vector3i(voxel.x, 0, voxel.z + 1), temperature_map.get(voxel, 0.0)))
	var south := float(temperature_map.get(Vector3i(voxel.x, 0, voxel.z - 1), temperature_map.get(voxel, 0.0)))
	return Vector2((east - west) * 0.5, (north - south) * 0.5)

func _initial_temp(voxel: Vector3i) -> float:
	var p := Vector2(float(voxel.x), float(voxel.z))
	var large_scale := 0.5 + 0.16 * sin((p.x + _terrain_seed) * 0.11)
	var small_scale := 0.12 * cos((p.y - _terrain_seed) * 0.14)
	return clampf(large_scale + small_scale - _terrain_height(voxel) * 0.2, 0.05, 1.0)

func _terrain_height(voxel: Vector3i) -> float:
	var x := float(voxel.x)
	var z := float(voxel.z)
	return sin((x + _terrain_seed) * 0.15) * 0.55 + cos((z - _terrain_seed) * 0.17) * 0.45

func _valley_axis(voxel: Vector3i) -> Vector2:
	var x := float(voxel.x)
	var z := float(voxel.z)
	var angle := sin((x + _terrain_seed) * 0.12) * 1.15 + cos((z - _terrain_seed) * 0.1) * 0.85
	return Vector2(cos(angle), sin(angle)).normalized()
