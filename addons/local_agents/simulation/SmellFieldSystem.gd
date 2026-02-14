extends RefCounted
class_name LocalAgentsSmellFieldSystem
const VoxelGridSystemScript = preload("res://addons/local_agents/simulation/VoxelGridSystem.gd")
const SmellComputeBackendScript = preload("res://addons/local_agents/simulation/SmellComputeBackend.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
var _grid = VoxelGridSystemScript.new()
var _layers: Dictionary = {}
var _compute_requested: bool = false
var _compute_active: bool = false
var _compute_backend = SmellComputeBackendScript.new()
var _last_step_status: Dictionary = {"ok": true}
var _query_acceleration_enabled: bool = true
var _query_top_k_per_layer: int = 48
var _query_cache_refresh_interval_seconds: float = 0.25
var _query_cache_last_refresh_time_seconds: float = -1.0
var _query_cache_dirty: bool = true
var _query_layer_top_voxels: Dictionary = {}
func configure(half_extent: float, voxel_size: float, vertical_half_extent: float = 3.0) -> void:
	_grid.configure(half_extent, voxel_size, vertical_half_extent)
	_layers.clear()
	_refresh_compute_state()
	_mark_query_cache_dirty()
func clear() -> void:
	_layers.clear()
	_mark_query_cache_dirty()
func set_compute_enabled(enabled: bool) -> void:
	_compute_requested = enabled
	_refresh_compute_state()
func is_compute_active() -> bool:
	return _compute_active

func last_step_status() -> Dictionary:
	return _last_step_status.duplicate(true)
func set_query_acceleration(enabled: bool, top_k_per_layer: int, cache_refresh_interval_seconds: float) -> void:
	var next_enabled := enabled
	var next_top_k := maxi(4, mini(1024, top_k_per_layer))
	var next_refresh := clampf(cache_refresh_interval_seconds, 0.01, 2.0)
	var changed := _query_acceleration_enabled != next_enabled
	changed = changed or _query_top_k_per_layer != next_top_k
	changed = changed or not is_equal_approx(_query_cache_refresh_interval_seconds, next_refresh)
	_query_acceleration_enabled = next_enabled
	_query_top_k_per_layer = next_top_k
	_query_cache_refresh_interval_seconds = next_refresh
	if changed:
		_mark_query_cache_dirty()
func query_acceleration_config() -> Dictionary:
	return {
		"enabled": _query_acceleration_enabled,
		"top_k_per_layer": _query_top_k_per_layer,
		"cache_refresh_interval_seconds": _query_cache_refresh_interval_seconds,
	}
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
		_set_step_status(true)
		return
	if _compute_requested and not _compute_active:
		_refresh_compute_state()
	var decay := base_decay_per_second * (1.0 + rain_intensity * rain_decay_multiplier)
	var decay_factor := clampf(1.0 - decay * delta, 0.0, 1.0)
	var native_dispatch := NativeComputeBridgeScript.dispatch_voxel_stage("smell_step", {"delta": delta, "decay_factor": decay_factor, "layer_count": _layers.size()})
	if not bool(native_dispatch.get("dispatched", false)):
		_set_step_status(false, "native_smell_step_dispatch_failed", "smell_step dispatch unavailable or failed")
		push_error("SmellFieldSystem: smell_step dispatch unavailable or failed")
		return
	_set_step_status(true)

func step_local(delta: float, active_voxels: Array[Vector3i], radius_cells: int, wind_source: Variant, base_decay_per_second: float, rain_intensity: float, rain_decay_multiplier: float) -> void:
	if delta <= 0.0 or active_voxels.is_empty():
		_set_step_status(true)
		return
	if _compute_requested and not _compute_active:
		_refresh_compute_state()
	var decay := base_decay_per_second * (1.0 + rain_intensity * rain_decay_multiplier)
	var decay_factor := clampf(1.0 - decay * delta, 0.0, 1.0)
	var touched: Dictionary = _build_touched_voxels(active_voxels, maxi(1, radius_cells))
	var native_dispatch := NativeComputeBridgeScript.dispatch_voxel_stage("smell_step_local", {"delta": delta, "decay_factor": decay_factor, "layer_count": _layers.size(), "active_voxel_count": active_voxels.size(), "touched_count": touched.size()})
	if not bool(native_dispatch.get("dispatched", false)):
		_set_step_status(false, "native_smell_step_local_dispatch_failed", "smell_step_local dispatch unavailable or failed")
		push_error("SmellFieldSystem: smell_step_local dispatch unavailable or failed")
		return
	_set_step_status(true)
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
	if _query_acceleration_enabled:
		var accelerated := _strongest_weighted_chemical_accelerated(center, chemical_weights, radius)
		if float(accelerated.get("score", 0.0)) > 0.0:
			return accelerated
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
func _strongest_weighted_chemical_accelerated(center: Vector3i, chemical_weights: Dictionary, radius: int) -> Dictionary:
	var candidates := _collect_accelerated_candidates(center, chemical_weights, radius)
	if candidates.is_empty():
		return {"score": 0.0}
	var best_score := 0.0
	var best_pos: Variant = null
	for voxel in candidates:
		var diff := voxel - center
		var dist := sqrt(float(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z))
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
func _collect_accelerated_candidates(center: Vector3i, chemical_weights: Dictionary, radius: int) -> Array[Vector3i]:
	_refresh_query_cache_if_needed()
	var candidates: Dictionary = {}
	_add_local_candidates(center, mini(2, radius), candidates)
	for chem_name_variant in chemical_weights.keys():
		var weight := absf(float(chemical_weights[chem_name_variant]))
		if weight <= 0.000001:
			continue
		var layer_name := _chemical_layer(String(chem_name_variant))
		var layer_top_variant = _query_layer_top_voxels.get(layer_name, [])
		if not (layer_top_variant is Array):
			continue
		var layer_top: Array = layer_top_variant
		if layer_top.is_empty():
			continue
		var scaled_limit := int(round(float(_query_top_k_per_layer) * (0.5 + clampf(weight, 0.0, 2.0))))
		var limit := mini(layer_top.size(), maxi(1, scaled_limit))
		for i in range(limit):
			var voxel: Vector3i = layer_top[i]
			var diff := voxel - center
			if absi(diff.x) > radius or absi(diff.y) > radius or absi(diff.z) > radius:
				continue
			if (diff.x * diff.x + diff.y * diff.y + diff.z * diff.z) > (radius * radius):
				continue
			candidates[voxel] = true
	if not candidates.has(center):
		candidates[center] = true
	var out: Array[Vector3i] = []
	for voxel_variant in candidates.keys():
		out.append(voxel_variant as Vector3i)
	return out
func _add_local_candidates(center: Vector3i, radius: int, candidates: Dictionary) -> void:
	var local_radius := maxi(0, radius)
	for dz in range(-local_radius, local_radius + 1):
		for dy in range(-local_radius, local_radius + 1):
			for dx in range(-local_radius, local_radius + 1):
				var voxel := Vector3i(center.x + dx, center.y + dy, center.z + dz)
				if not _grid.is_inside(voxel):
					continue
				candidates[voxel] = true
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
	_mark_query_cache_dirty()
func _get_layer(layer_name: String) -> Dictionary:
	if not _layers.has(layer_name):
		_layers[layer_name] = {}
	return _layers[layer_name]
func _step_layer(layer_name: String, delta: float, decay_factor: float, wind_source: Variant) -> void:
	var source := _get_layer(layer_name)
	if source.is_empty():
		return
	if _compute_active and _step_layer_compute(layer_name, delta, decay_factor, wind_source, false, {}):
		_mark_query_cache_dirty()
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
	_mark_query_cache_dirty()
func _step_layer_local(layer_name: String, delta: float, decay_factor: float, wind_source: Variant, touched: Dictionary) -> void:
	var source := _get_layer(layer_name)
	if source.is_empty():
		return
	if _compute_active and _step_layer_compute(layer_name, delta, decay_factor, wind_source, true, touched):
		_mark_query_cache_dirty()
		return
	var untouched: Dictionary = {}
	var processed: Dictionary = {}
	for voxel_variant in _grid.sort_voxel_keys(source.keys()):
		var voxel: Vector3i = voxel_variant
		if not touched.has(voxel):
			untouched[voxel] = float(source.get(voxel, 0.0))
			continue
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
		if not touched.has(advected):
			advected = voxel
		var retained := remaining * 0.76
		_accumulate(processed, advected, retained)
		var spread := remaining - retained
		if spread > 0.00001:
			var neighbors := _grid.neighbors_6(advected)
			var valid_neighbors: Array[Vector3i] = []
			for neighbor in neighbors:
				if touched.has(neighbor):
					valid_neighbors.append(neighbor)
			var per := spread / float(maxi(1, valid_neighbors.size()))
			for neighbor in valid_neighbors:
				_accumulate(processed, neighbor, per)
	var merged := untouched.duplicate(true)
	for voxel_variant in processed.keys():
		var voxel: Vector3i = voxel_variant
		merged[voxel] = float(merged.get(voxel, 0.0)) + float(processed.get(voxel, 0.0))
	_layers[layer_name] = _prune_layer(merged)
	_mark_query_cache_dirty()
func _step_layer_compute(layer_name: String, delta: float, decay_factor: float, wind_source: Variant, local_mode: bool, touched: Dictionary) -> bool:
	var source := _get_layer(layer_name)
	var untouched: Dictionary = {}
	var source_voxels: Array[Vector3i] = []
	var source_values := PackedFloat32Array()
	var wind_x := PackedFloat32Array()
	var wind_y := PackedFloat32Array()
	for voxel_variant in _grid.sort_voxel_keys(source.keys()):
		var voxel: Vector3i = voxel_variant
		var value := float(source.get(voxel, 0.0))
		if local_mode and not touched.has(voxel):
			untouched[voxel] = value
			continue
		if value <= 0.00001:
			continue
		var world := _grid.voxel_to_world(voxel)
		var wind := _resolve_wind(wind_source, world)
		source_voxels.append(voxel)
		source_values.append(value)
		wind_x.append(wind.x)
		wind_y.append(wind.y)
	if source_voxels.is_empty():
		_layers[layer_name] = _prune_layer(untouched if local_mode else {})
		return true
	var radius_cells := _grid_radius_cells()
	var vertical_cells := _grid_vertical_cells()
	var touched_mask := PackedInt32Array()
	if local_mode:
		touched_mask = _build_dense_touched_mask(touched, radius_cells, vertical_cells)
	var gpu := _compute_backend.step(
		source_voxels,
		source_values,
		wind_x,
		wind_y,
		touched_mask,
		radius_cells,
		vertical_cells,
		local_mode,
		delta,
		decay_factor,
		_grid.voxel_size(),
		_grid.half_extent(),
		_grid.vertical_half_extent()
	)
	if gpu.is_empty():
		_compute_active = false
		return false
	var out_x_variant = gpu.get("out_x", PackedInt32Array())
	var out_y_variant = gpu.get("out_y", PackedInt32Array())
	var out_z_variant = gpu.get("out_z", PackedInt32Array())
	var out_value_variant = gpu.get("out_value", PackedFloat32Array())
	if not (out_x_variant is PackedInt32Array and out_y_variant is PackedInt32Array and out_z_variant is PackedInt32Array and out_value_variant is PackedFloat32Array):
		_compute_active = false
		return false
	var out_x: PackedInt32Array = out_x_variant
	var out_y: PackedInt32Array = out_y_variant
	var out_z: PackedInt32Array = out_z_variant
	var out_value: PackedFloat32Array = out_value_variant
	if out_x.size() != out_y.size() or out_x.size() != out_z.size() or out_x.size() != out_value.size():
		_compute_active = false
		return false
	var merged := untouched.duplicate(true) if local_mode else {}
	for i in range(out_value.size()):
		var amount := float(out_value[i])
		if amount <= 0.0:
			continue
		var voxel := Vector3i(out_x[i], out_y[i], out_z[i])
		if local_mode and not touched.has(voxel):
			continue
		_accumulate(merged, voxel, amount)
	_layers[layer_name] = _prune_layer(merged)
	return true
func _refresh_compute_state() -> void:
	if not _compute_requested:
		_compute_backend.release()
		_compute_active = false
		return
	_compute_active = _compute_backend.initialize()
func _grid_radius_cells() -> int:
	return int(ceil(_grid.half_extent() / _grid.voxel_size()))
func _grid_vertical_cells() -> int:
	return int(ceil(_grid.vertical_half_extent() / _grid.voxel_size()))
func _dense_voxel_index(voxel: Vector3i, radius_cells: int, vertical_cells: int) -> int:
	var dim := radius_cells * 2 + 1
	var y_dim := vertical_cells * 2 + 1
	var sx := voxel.x + radius_cells
	var sy := voxel.y + vertical_cells
	var sz := voxel.z + radius_cells
	if sx < 0 or sy < 0 or sz < 0 or sx >= dim or sy >= y_dim or sz >= dim:
		return -1
	return sx + sz * dim + sy * dim * dim
func _build_dense_touched_mask(touched: Dictionary, radius_cells: int, vertical_cells: int) -> PackedInt32Array:
	var dim := radius_cells * 2 + 1
	var y_dim := vertical_cells * 2 + 1
	var mask := PackedInt32Array()
	mask.resize(maxi(1, dim * dim * y_dim))
	for voxel_variant in touched.keys():
		var voxel: Vector3i = voxel_variant
		var idx := _dense_voxel_index(voxel, radius_cells, vertical_cells)
		if idx >= 0 and idx < mask.size():
			mask[idx] = 1
	return mask
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_compute_backend.release()
func _refresh_query_cache_if_needed() -> void:
	if _query_cache_dirty:
		_rebuild_query_cache()
		return
	var now_seconds := Time.get_ticks_msec() * 0.001
	if _query_cache_last_refresh_time_seconds < 0.0:
		_rebuild_query_cache()
		return
	if (now_seconds - _query_cache_last_refresh_time_seconds) >= _query_cache_refresh_interval_seconds:
		_rebuild_query_cache()
func _rebuild_query_cache() -> void:
	_query_layer_top_voxels.clear()
	for layer_name_variant in _sorted_layer_names():
		var layer_name := String(layer_name_variant)
		var layer := _get_layer(layer_name)
		if layer.is_empty():
			continue
		var ranked: Array = []
		for voxel_variant in layer.keys():
			var value := float(layer.get(voxel_variant, 0.0))
			if value <= 0.00001:
				continue
			ranked.append({"voxel": voxel_variant, "value": value})
		if ranked.is_empty():
			continue
		ranked.sort_custom(func(a, b): return float(a.get("value", 0.0)) > float(b.get("value", 0.0)))
		var limit := mini(ranked.size(), _query_top_k_per_layer)
		var top: Array[Vector3i] = []
		top.resize(limit)
		for i in range(limit):
			top[i] = ranked[i]["voxel"]
		_query_layer_top_voxels[layer_name] = top
	_query_cache_last_refresh_time_seconds = Time.get_ticks_msec() * 0.001
	_query_cache_dirty = false
func _mark_query_cache_dirty() -> void:
	_query_cache_dirty = true

func _set_step_status(ok: bool, error_code: String = "", details: String = "") -> void:
	_last_step_status = {"ok": ok}
	if not ok:
		_last_step_status["error"] = error_code
		if details != "":
			_last_step_status["details"] = details
func _build_touched_voxels(active_voxels: Array[Vector3i], radius_cells: int) -> Dictionary:
	var touched: Dictionary = {}
	var radius := maxi(1, radius_cells)
	for center in active_voxels:
		for dz in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					var voxel := Vector3i(center.x + dx, center.y + dy, center.z + dz)
					if not _grid.is_inside(voxel):
						continue
					touched[voxel] = true
	return touched
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
