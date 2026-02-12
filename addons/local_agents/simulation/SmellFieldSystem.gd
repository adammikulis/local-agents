extends RefCounted
class_name LocalAgentsSmellFieldSystem

const VoxelGridSystemScript = preload("res://addons/local_agents/simulation/VoxelGridSystem.gd")

var _grid = VoxelGridSystemScript.new()
var _layers: Dictionary = {}

func configure(half_extent: float, voxel_size: float, vertical_half_extent: float = 3.0) -> void:
	_grid.configure(half_extent, voxel_size, vertical_half_extent)
	_layers.clear()

func clear() -> void:
	_layers.clear()

func hierarchy_snapshot() -> Dictionary:
	return snapshot()

func snapshot() -> Dictionary:
	var payload := {
		"mode": "sparse_voxel",
		"half_extent": _grid.half_extent(),
		"voxel_size": _grid.voxel_size(),
		"vertical_half_extent": _grid.vertical_half_extent(),
		"layers": {},
	}
	var layers_payload: Dictionary = payload["layers"]
	for layer_name_variant in _sorted_layer_names():
		var layer_name := String(layer_name_variant)
		layers_payload[layer_name] = _serialize_layer(_get_layer(layer_name))
	return payload

func deposit(kind: String, world_position: Vector3, strength: float) -> void:
	_deposit_into_layer(_channel_for_kind(kind), world_position, strength)

func deposit_chemical(chemical: String, world_position: Vector3, strength: float) -> void:
	if chemical.strip_edges() == "":
		return
	_deposit_into_layer(_chemical_layer(chemical), world_position, strength)

func step(delta: float, wind_source: Variant, base_decay_per_second: float, rain_intensity: float, rain_decay_multiplier: float) -> void:
	if delta <= 0.0:
		return
	var decay := base_decay_per_second * (1.0 + rain_intensity * rain_decay_multiplier)
	var decay_factor := clampf(1.0 - decay * delta, 0.0, 1.0)
	for layer_name_variant in _sorted_layer_names():
		var layer_name := String(layer_name_variant)
		_step_layer(layer_name, delta, decay_factor, wind_source)

func strongest_weighted_chemical_position(origin: Vector3, chemical_weights: Dictionary, sample_radius_voxels: int = 8) -> Variant:
	var scored := _strongest_weighted_chemical(origin, chemical_weights, sample_radius_voxels)
	return scored.get("position", null)

func strongest_weighted_chemical_score(origin: Vector3, chemical_weights: Dictionary, sample_radius_voxels: int = 4) -> Dictionary:
	return _strongest_weighted_chemical(origin, chemical_weights, sample_radius_voxels)

func perceived_danger(origin: Vector3, sample_radius_voxels: int = 4) -> Dictionary:
	return strongest_weighted_chemical_score(origin, {
		"ammonia": 1.0,
		"butyric_acid": 1.0,
		"methyl_salicylate": 0.7,
		"alkaloids": 0.8,
		"tannins": 0.7,
	}, sample_radius_voxels)

func world_to_voxel(world_position: Vector3) -> Vector3i:
	return _grid.world_to_voxel(world_position)

func voxel_to_world(voxel: Vector3i) -> Vector3:
	return _grid.voxel_to_world(voxel)

func sample_layer_at_world(layer_name: String, world_position: Vector3) -> float:
	var voxel := _grid.world_to_voxel(world_position)
	if voxel == _grid.invalid_voxel():
		return 0.0
	return float(_get_layer(layer_name).get(voxel, 0.0))

func build_debug_cells(min_strength: float = 0.03, max_cells: int = 500) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var food_layer := _get_layer("food")
	var rabbit_layer := _get_layer("rabbit")
	var danger_layer := _get_layer("danger")
	var touched := {}
	for key_variant in food_layer.keys():
		touched[key_variant] = true
	for key_variant in rabbit_layer.keys():
		touched[key_variant] = true
	for key_variant in danger_layer.keys():
		touched[key_variant] = true
	for voxel_variant in _grid.sort_voxel_keys(touched.keys()):
		var voxel: Vector3i = voxel_variant
		var food := float(food_layer.get(voxel, 0.0))
		var rabbit := float(rabbit_layer.get(voxel, 0.0))
		var danger := float(danger_layer.get(voxel, 0.0))
		var peak := maxf(maxf(food, rabbit), danger)
		if peak < min_strength:
			continue
		rows.append({
			"voxel": voxel,
			"world": _grid.voxel_to_world(voxel),
			"food": food,
			"rabbit": rabbit,
			"danger": danger,
		})
	if rows.size() <= max_cells:
		return rows
	rows.sort_custom(func(a, b): return _row_peak(a) > _row_peak(b))
	rows.resize(max_cells)
	return rows

func build_layer_cells(layer_name: String, min_strength: float = 0.02, max_cells: int = 500) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var layer := _get_layer(layer_name)
	for voxel_variant in _grid.sort_voxel_keys(layer.keys()):
		var voxel: Vector3i = voxel_variant
		var value := float(layer.get(voxel, 0.0))
		if value < min_strength:
			continue
		rows.append({
			"voxel": voxel,
			"world": _grid.voxel_to_world(voxel),
			"value": value,
		})
	if rows.size() <= max_cells:
		return rows
	rows.sort_custom(func(a, b): return float(a.get("value", 0.0)) > float(b.get("value", 0.0)))
	rows.resize(max_cells)
	return rows

func to_image() -> Image:
	var voxel_size := _grid.voxel_size()
	var half_extent := _grid.half_extent()
	var width := maxi(1, int(ceil((half_extent * 2.0) / voxel_size)) + 1)
	var image := Image.create(width, width, false, Image.FORMAT_RGBA8)
	var half_cells := int(floor(float(width) * 0.5))
	var food_layer := _get_layer("food")
	var rabbit_layer := _get_layer("rabbit")
	var danger_layer := _get_layer("danger")
	for z in range(width):
		for x in range(width):
			var vx := x - half_cells
			var vz := z - half_cells
			var food := _max_vertical(food_layer, vx, vz)
			var rabbit := _max_vertical(rabbit_layer, vx, vz)
			var danger := _max_vertical(danger_layer, vx, vz)
			var alpha := clampf(maxf(maxf(food, rabbit), danger), 0.0, 1.0)
			image.set_pixel(x, z, Color(clampf(danger, 0.0, 1.0), clampf(food, 0.0, 1.0), clampf(rabbit, 0.0, 1.0), alpha))
	return image

func _max_vertical(layer: Dictionary, vx: int, vz: int) -> float:
	var best := 0.0
	var y_radius := int(ceil(_grid.vertical_half_extent() / _grid.voxel_size()))
	for vy in range(-y_radius, y_radius + 1):
		best = maxf(best, float(layer.get(Vector3i(vx, vy, vz), 0.0)))
	return best

func _strongest_weighted_chemical(origin: Vector3, chemical_weights: Dictionary, sample_radius_voxels: int) -> Dictionary:
	var center := _grid.world_to_voxel(origin)
	if center == _grid.invalid_voxel():
		return {"score": 0.0}
	var radius := maxi(1, sample_radius_voxels)
	var best_score := 0.0
	var best_pos: Variant = null
	for dz in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var voxel := Vector3i(center.x + dx, center.y + dy, center.z + dz)
				if not _grid.is_inside(voxel):
					continue
				var dist := sqrt(float(dx * dx + dy * dy + dz * dz))
				if dist > float(radius):
					continue
				var score := _weighted_chemical_score(voxel, chemical_weights)
				if score <= 0.0:
					continue
				score /= maxf(1.0, dist)
				if score > best_score:
					best_score = score
					best_pos = _grid.voxel_to_world(voxel)
	if best_pos == null:
		return {"score": 0.0}
	return {"score": best_score, "position": best_pos}

func _weighted_chemical_score(voxel: Vector3i, chemical_weights: Dictionary) -> float:
	var total := 0.0
	for chem_name_variant in chemical_weights.keys():
		var chem_name := String(chem_name_variant)
		var weight := float(chemical_weights[chem_name_variant])
		if absf(weight) <= 0.000001:
			continue
		total += float(_get_layer(_chemical_layer(chem_name)).get(voxel, 0.0)) * weight
	return total

func _chemical_layer(chemical: String) -> String:
	return "chem_%s" % chemical.to_lower().strip_edges()

func _channel_for_kind(kind: String) -> String:
	match kind:
		"plant_food":
			return "food"
		"rabbit":
			return "rabbit"
		_:
			return "danger"

func _deposit_into_layer(layer_name: String, world_position: Vector3, strength: float) -> void:
	var amount := maxf(0.0, strength)
	if amount <= 0.0:
		return
	var voxel := _grid.world_to_voxel(world_position)
	if voxel == _grid.invalid_voxel():
		return
	var layer := _get_layer(layer_name)
	layer[voxel] = float(layer.get(voxel, 0.0)) + amount

func _get_layer(layer_name: String) -> Dictionary:
	if not _layers.has(layer_name):
		_layers[layer_name] = {}
	return _layers[layer_name]

func _step_layer(layer_name: String, delta: float, decay_factor: float, wind_source: Variant) -> void:
	var source := _get_layer(layer_name)
	if source.is_empty():
		return
	var dest: Dictionary = {}
	for voxel_variant in _grid.sort_voxel_keys(source.keys()):
		var voxel: Vector3i = voxel_variant
		var value := float(source.get(voxel, 0.0))
		if value <= 0.00001:
			continue
		var remaining := value * decay_factor
		if remaining <= 0.00001:
			continue
		var world := _grid.voxel_to_world(voxel)
		var wind := _resolve_wind(wind_source, world)
		var drift := wind * (delta / _grid.voxel_size()) * 0.75
		var advected := Vector3i(
			voxel.x + int(clampi(int(round(drift.x)), -1, 1)),
			voxel.y,
			voxel.z + int(clampi(int(round(drift.y)), -1, 1))
		)
		if not _grid.is_inside(advected):
			advected = voxel
		var retained := remaining * 0.76
		_accumulate(dest, advected, retained)
		var spread := remaining - retained
		if spread > 0.00001:
			var neighbors := _grid.neighbors_6(advected)
			var per := spread / float(maxi(1, neighbors.size()))
			for neighbor in neighbors:
				_accumulate(dest, neighbor, per)
	_layers[layer_name] = _prune_layer(dest)

func _prune_layer(layer: Dictionary) -> Dictionary:
	var pruned := {}
	for voxel_variant in layer.keys():
		var value := float(layer[voxel_variant])
		if value >= 0.0005:
			pruned[voxel_variant] = value
	return pruned

func _accumulate(target: Dictionary, voxel: Vector3i, amount: float) -> void:
	if amount <= 0.0:
		return
	if not _grid.is_inside(voxel):
		return
	target[voxel] = float(target.get(voxel, 0.0)) + amount

func _resolve_wind(wind_source: Variant, world_position: Vector3) -> Vector2:
	if wind_source is Callable:
		var callable: Callable = wind_source
		if callable.is_valid():
			var value = callable.call(world_position)
			if value is Vector2:
				return value
	elif wind_source is Vector2:
		return wind_source
	return Vector2.ZERO

func _row_peak(row: Dictionary) -> float:
	return maxf(maxf(float(row.get("food", 0.0)), float(row.get("rabbit", 0.0))), float(row.get("danger", 0.0)))

func _sorted_layer_names() -> Array:
	var names := _layers.keys()
	names.sort_custom(func(a, b): return String(a) < String(b))
	return names

func _serialize_layer(layer: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for voxel_variant in _grid.sort_voxel_keys(layer.keys()):
		var voxel: Vector3i = voxel_variant
		rows.append({
			"x": voxel.x,
			"y": voxel.y,
			"z": voxel.z,
			"value": float(layer[voxel]),
		})
	return rows
