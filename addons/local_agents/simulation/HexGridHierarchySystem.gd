extends RefCounted
class_name LocalAgentsHexGridHierarchySystem

const GridConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GridConfigResource.gd")

var _grid_config: Resource = GridConfigResourceScript.new()
var _lod_levels: int = 3
var _subdivision_ratio: int = 2
var _subdivision_trigger_strength: float = 0.55
var _base_width: int = 0
var _base_height: int = 0
var _base_layers: Dictionary = {}
var _sparse_layers: Dictionary = {}

func setup(grid_config: Resource, lod_levels: int = 3, subdivision_ratio: int = 2, subdivision_trigger_strength: float = 0.55) -> void:
	if grid_config != null:
		_grid_config = grid_config
	_lod_levels = maxi(1, lod_levels)
	_subdivision_ratio = maxi(2, subdivision_ratio)
	_subdivision_trigger_strength = clampf(subdivision_trigger_strength, 0.01, 4.0)
	var layout = String(_grid_config.get("grid_layout"))
	if layout == "":
		_grid_config.set("grid_layout", "hex_pointy")
	elif layout != "hex_pointy":
		push_error("HexGridHierarchySystem requires grid_layout=hex_pointy")
	var base_hex_size = maxf(0.1, float(_grid_config.get("cell_size")))
	var half_extent = maxf(1.0, float(_grid_config.get("half_extent")))
	var horizontal_spacing: float = sqrt(3.0) * base_hex_size
	var vertical_spacing: float = 1.5 * base_hex_size
	_base_width = maxi(3, int(ceil((half_extent * 2.0) / horizontal_spacing)) + 4)
	_base_height = maxi(3, int(ceil((half_extent * 2.0) / vertical_spacing)) + 4)
	_base_layers.clear()
	_sparse_layers.clear()

func clear_all() -> void:
	_base_layers.clear()
	_sparse_layers.clear()

func clear_layer(layer: String) -> void:
	if _base_layers.has(layer):
		var dense: PackedFloat32Array = _base_layers[layer]
		for i in range(dense.size()):
			dense[i] = 0.0
		_base_layers[layer] = dense
	for level_key_variant in _sparse_layers.keys():
		var level_key = String(level_key_variant)
		var level_layers: Dictionary = _sparse_layers.get(level_key, {})
		if level_layers.has(layer):
			level_layers.erase(layer)
		_sparse_layers[level_key] = level_layers

func deposit(layer: String, world_position: Vector3, strength: float) -> void:
	if strength <= 0.0:
		return
	var base_cell = world_to_cell_level(world_position, 0)
	if base_cell.x < 0:
		return
	_add_to_base(layer, base_cell.x, base_cell.y, strength)
	if strength < _subdivision_trigger_strength:
		return
	for level in range(1, _lod_levels):
		var level_cell = world_to_cell_level(world_position, level)
		if level_cell.x < 0:
			continue
		var attenuation = pow(0.62, float(level))
		_add_to_sparse(level, layer, level_cell, strength * attenuation)

func advect_and_decay_layer(layer: String, delta: float, decay_factor: float, wind_world: Vector2) -> void:
	if delta <= 0.0:
		return
	_ensure_base_layer(layer)
	var dense_source: PackedFloat32Array = _base_layers[layer]
	var dense_out: PackedFloat32Array = PackedFloat32Array()
	dense_out.resize(dense_source.size())
	for y in range(_base_height):
		for x in range(_base_width):
			var world_target = cell_to_world_level(x, y, 0)
			var source_world = world_target - (wind_world * delta)
			var source_cell = world_to_cell_level(Vector3(source_world.x, 0.0, source_world.y), 0)
			var sampled = 0.0
			if source_cell.x >= 0:
				sampled = dense_source[_index(source_cell.x, source_cell.y)]
			dense_out[_index(x, y)] = maxf(0.0, sampled * decay_factor)
	_base_layers[layer] = dense_out
	_advect_sparse_layer(layer, delta, decay_factor, wind_world)

func strongest_layer_position(layer: String, origin: Vector3, sample_radius_cells: int = 8) -> Variant:
	var center = world_to_cell_level(origin, 0)
	if center.x < 0:
		return null
	var center_axial = _cell_to_axial(center.x, center.y, 0)
	var best_score = 0.0
	var best_world: Variant = null
	for y in range(maxi(0, center.y - sample_radius_cells), mini(_base_height, center.y + sample_radius_cells + 1)):
		for x in range(maxi(0, center.x - sample_radius_cells), mini(_base_width, center.x + sample_radius_cells + 1)):
			var axial = _cell_to_axial(x, y, 0)
			if _hex_distance(center_axial, axial) > sample_radius_cells:
				continue
			var world_pos = cell_to_world_level(x, y, 0)
			var strength = sample_layer_at_world(layer, Vector3(world_pos.x, 0.0, world_pos.y))
			if strength <= 0.0:
				continue
			var distance = maxf(1.0, float(_hex_distance(center_axial, axial)))
			var score = strength / distance
			if score > best_score:
				best_score = score
				best_world = Vector3(world_pos.x, 0.15, world_pos.y)
	return best_world

func strongest_layer_score(layer: String, origin: Vector3, sample_radius_cells: int = 4) -> Dictionary:
	var center = world_to_cell_level(origin, 0)
	if center.x < 0:
		return {"score": 0.0}
	var center_axial = _cell_to_axial(center.x, center.y, 0)
	var best_score = 0.0
	var best_world: Variant = null
	for y in range(maxi(0, center.y - sample_radius_cells), mini(_base_height, center.y + sample_radius_cells + 1)):
		for x in range(maxi(0, center.x - sample_radius_cells), mini(_base_width, center.x + sample_radius_cells + 1)):
			var axial = _cell_to_axial(x, y, 0)
			if _hex_distance(center_axial, axial) > sample_radius_cells:
				continue
			var world_pos = cell_to_world_level(x, y, 0)
			var strength = sample_layer_at_world(layer, Vector3(world_pos.x, 0.0, world_pos.y))
			if strength <= 0.0:
				continue
			var distance = maxf(1.0, float(_hex_distance(center_axial, axial)))
			var score = strength / distance
			if score > best_score:
				best_score = score
				best_world = Vector3(world_pos.x, 0.15, world_pos.y)
	if best_world == null:
		return {"score": 0.0}
	return {"score": best_score, "position": best_world}

func build_debug_cells(layers: Array[String], min_strength: float = 0.03, max_cells: int = 350) -> Array[Dictionary]:
	var cells: Array[Dictionary] = []
	for y in range(_base_height):
		for x in range(_base_width):
			var world_pos = cell_to_world_level(x, y, 0)
			var total = 0.0
			var row: Dictionary = {
				"key": "%d_%d" % [x, y],
				"world": Vector3(world_pos.x, 0.15, world_pos.y),
			}
			for layer_name_variant in layers:
				var layer_name = String(layer_name_variant)
				var strength = sample_layer_at_world(layer_name, Vector3(world_pos.x, 0.0, world_pos.y))
				row[layer_name] = strength
				total += strength
			row["total"] = total
			if total >= min_strength:
				cells.append(row)
	if cells.size() <= max_cells:
		return cells
	cells.sort_custom(func(a, b): return float(a.get("total", 0.0)) > float(b.get("total", 0.0)))
	cells.resize(max_cells)
	return cells

func snapshot() -> Dictionary:
	var base_layers_dict: Dictionary = {}
	var base_keys = _base_layers.keys()
	base_keys.sort()
	for key_variant in base_keys:
		var key = String(key_variant)
		base_layers_dict[key] = _base_layers[key]
	return {
		"grid": {
			"layout": String(_grid_config.get("grid_layout")),
			"half_extent": float(_grid_config.get("half_extent")),
			"cell_size": float(_grid_config.get("cell_size")),
			"width": _base_width,
			"height": _base_height,
			"lod_levels": _lod_levels,
			"subdivision_ratio": _subdivision_ratio,
			"subdivision_trigger_strength": _subdivision_trigger_strength,
		},
		"base_layers": base_layers_dict,
		"sparse_layers": _sparse_layers.duplicate(true),
	}

func world_to_cell_level(world_position: Vector3, level: int) -> Vector2i:
	var cell_size = _cell_size_for_level(level)
	var axial_float = _world_to_axial_float(Vector2(world_position.x, world_position.z), cell_size)
	var rounded = _axial_round(axial_float)
	var cell = _axial_to_cell(rounded.x, rounded.y, level)
	var dims = _dims_for_level(level)
	if cell.x < 0 or cell.y < 0 or cell.x >= dims.x or cell.y >= dims.y:
		return Vector2i(-1, -1)
	return cell

func cell_to_world_level(x: int, y: int, level: int) -> Vector2:
	var axial = _cell_to_axial(x, y, level)
	return _axial_to_world(axial.x, axial.y, _cell_size_for_level(level))

func sample_layer_at_world(layer: String, world_position: Vector3) -> float:
	_ensure_base_layer(layer)
	var base_cell = world_to_cell_level(world_position, 0)
	if base_cell.x < 0:
		return 0.0
	var total = float(_base_layers[layer][_index(base_cell.x, base_cell.y)])
	for level in range(1, _lod_levels):
		var level_cell = world_to_cell_level(world_position, level)
		if level_cell.x < 0:
			continue
		var layer_map = _layer_map_for_level(level, layer)
		total += float(layer_map.get(_cell_key(level_cell), 0.0))
	return total

func _ensure_base_layer(layer: String) -> void:
	if _base_layers.has(layer):
		return
	var dense := PackedFloat32Array()
	dense.resize(_base_width * _base_height)
	for i in range(dense.size()):
		dense[i] = 0.0
	_base_layers[layer] = dense

func _add_to_base(layer: String, x: int, y: int, amount: float) -> void:
	_ensure_base_layer(layer)
	var dense: PackedFloat32Array = _base_layers[layer]
	var idx = _index(x, y)
	dense[idx] = minf(4.0, dense[idx] + amount)
	_base_layers[layer] = dense

func _add_to_sparse(level: int, layer: String, cell: Vector2i, amount: float) -> void:
	var level_key = "level_%d" % level
	var level_layers: Dictionary = _sparse_layers.get(level_key, {})
	var layer_map: Dictionary = level_layers.get(layer, {})
	var key = _cell_key(cell)
	layer_map[key] = minf(4.0, float(layer_map.get(key, 0.0)) + amount)
	level_layers[layer] = layer_map
	_sparse_layers[level_key] = level_layers

func _advect_sparse_layer(layer: String, delta: float, decay_factor: float, wind_world: Vector2) -> void:
	for level in range(1, _lod_levels):
		var level_key = "level_%d" % level
		var level_layers: Dictionary = _sparse_layers.get(level_key, {})
		if not level_layers.has(layer):
			continue
		var layer_map: Dictionary = level_layers.get(layer, {})
		var out_map: Dictionary = {}
		for key_variant in layer_map.keys():
			var key = String(key_variant)
			var strength = float(layer_map[key]) * decay_factor
			if strength <= 0.02:
				continue
			var cell = _cell_from_key(key)
			var world_pos = cell_to_world_level(cell.x, cell.y, level)
			var advected_world = world_pos + (wind_world * delta)
			var next_cell = world_to_cell_level(Vector3(advected_world.x, 0.0, advected_world.y), level)
			if next_cell.x < 0:
				continue
			var out_key = _cell_key(next_cell)
			out_map[out_key] = minf(4.0, float(out_map.get(out_key, 0.0)) + strength)
		level_layers[layer] = out_map
		_sparse_layers[level_key] = level_layers

func _layer_map_for_level(level: int, layer: String) -> Dictionary:
	var level_key = "level_%d" % level
	var level_layers: Dictionary = _sparse_layers.get(level_key, {})
	return level_layers.get(layer, {})

func _dims_for_level(level: int) -> Vector2i:
	var scale = pow(float(_subdivision_ratio), float(level))
	return Vector2i(maxi(3, int(round(float(_base_width) * scale))), maxi(3, int(round(float(_base_height) * scale))))

func _cell_size_for_level(level: int) -> float:
	return maxf(0.05, float(_grid_config.get("cell_size")) / pow(float(_subdivision_ratio), float(level)))

func _index(x: int, y: int) -> int:
	return (y * _base_width) + x

func _world_to_axial_float(world: Vector2, cell_size: float) -> Vector2:
	var q = (sqrt(3.0) / 3.0 * world.x - 1.0 / 3.0 * world.y) / cell_size
	var r = (2.0 / 3.0 * world.y) / cell_size
	return Vector2(q, r)

func _axial_to_world(q: int, r: int, cell_size: float) -> Vector2:
	var x = cell_size * sqrt(3.0) * (float(q) + float(r) * 0.5)
	var y = cell_size * 1.5 * float(r)
	return Vector2(x, y)

func _axial_round(axial: Vector2) -> Vector2i:
	var x = axial.x
	var z = axial.y
	var y = -x - z
	var rx = round(x)
	var ry = round(y)
	var rz = round(z)
	var x_diff = absf(rx - x)
	var y_diff = absf(ry - y)
	var z_diff = absf(rz - z)
	if x_diff > y_diff and x_diff > z_diff:
		rx = -ry - rz
	elif y_diff > z_diff:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(int(rx), int(rz))

func _cell_to_axial(x: int, y: int, level: int) -> Vector2i:
	var dims = _dims_for_level(level)
	var center_x = int(floor(float(dims.x) / 2.0))
	var center_y = int(floor(float(dims.y) / 2.0))
	return Vector2i(x - center_x, y - center_y)

func _axial_to_cell(q: int, r: int, level: int) -> Vector2i:
	var dims = _dims_for_level(level)
	var center_x = int(floor(float(dims.x) / 2.0))
	var center_y = int(floor(float(dims.y) / 2.0))
	return Vector2i(q + center_x, r + center_y)

func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq = abs(a.x - b.x)
	var dr = abs(a.y - b.y)
	var ds = abs((a.x + a.y) - (b.x + b.y))
	return int((dq + dr + ds) / 2)

func _cell_key(cell: Vector2i) -> String:
	return "%d:%d" % [cell.x, cell.y]

func _cell_from_key(key: String) -> Vector2i:
	var parts = key.split(":")
	if parts.size() != 2:
		return Vector2i(-1, -1)
	return Vector2i(int(parts[0]), int(parts[1]))
