extends RefCounted
class_name LocalAgentsSimulationVoxelTerrainMutator

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

const _WALL_FORWARD_DISTANCE_METERS := 9.0
const _WALL_HALF_SPAN_TILES := 4
const _WALL_HEIGHT_LEVELS := 6
const _WALL_THICKNESS_TILES := 1
const _CONTACT_IMPULSE_SCALE := 0.09
const _CONTACT_VELOCITY_SCALE := 0.05
const _CONTACT_DAMAGE_MAX_LEVELS := 4

static func stamp_default_target_wall(controller, tick: int, camera_transform: Transform3D) -> Dictionary:
	if controller == null:
		return {"ok": false, "changed": false, "error": "invalid_controller", "tick": tick}
	var env_snapshot = controller._environment_snapshot.duplicate(true)
	if env_snapshot.is_empty():
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var width := int(env_snapshot.get("width", 0))
	var height := int(env_snapshot.get("height", 0))
	if width <= 0 or height <= 0:
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var forward := -camera_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		forward = Vector3(0.0, 0.0, -1.0)
	forward = forward.normalized()
	var anchor_x := clampi(int(round(camera_transform.origin.x + forward.x * _WALL_FORWARD_DISTANCE_METERS)), 0, width - 1)
	var anchor_z := clampi(int(round(camera_transform.origin.z + forward.z * _WALL_FORWARD_DISTANCE_METERS)), 0, height - 1)
	var axis_z_dominant := absf(forward.z) >= absf(forward.x)
	var changed_tiles_map: Dictionary = {}
	var tile_height_overrides: Dictionary = {}
	for span in range(-_WALL_HALF_SPAN_TILES, _WALL_HALF_SPAN_TILES + 1):
		for depth in range(0, _WALL_THICKNESS_TILES):
			var tx := anchor_x
			var tz := anchor_z
			if axis_z_dominant:
				tx += span
				tz += depth
			else:
				tx += depth
				tz += span
			if tx < 0 or tx >= width or tz < 0 or tz >= height:
				continue
			var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
			changed_tiles_map[tile_id] = true
			tile_height_overrides[tile_id] = _WALL_HEIGHT_LEVELS
	var result = _apply_column_surface_delta(controller, env_snapshot, changed_tiles_map.keys(), tile_height_overrides, true)
	result["tick"] = tick
	return result

static func apply_projectile_contact_damage(controller, tick: int, rows: Array) -> Dictionary:
	if controller == null or rows.is_empty():
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var env_snapshot = controller._environment_snapshot.duplicate(true)
	if env_snapshot.is_empty():
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var width := int(env_snapshot.get("width", 0))
	var height := int(env_snapshot.get("height", 0))
	if width <= 0 or height <= 0:
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var changed_tiles_map: Dictionary = {}
	var tile_height_overrides: Dictionary = {}
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var point_variant = row.get("contact_point", Vector3.ZERO)
		if not (point_variant is Vector3):
			continue
		var point = point_variant as Vector3
		var tx := clampi(int(floor(point.x)), 0, width - 1)
		var tz := clampi(int(floor(point.z)), 0, height - 1)
		var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
		var impulse = maxf(0.0, float(row.get("contact_impulse", 0.0)))
		var velocity = maxf(0.0, float(row.get("contact_velocity", 0.0)))
		var damage = int(round(impulse * _CONTACT_IMPULSE_SCALE + velocity * _CONTACT_VELOCITY_SCALE))
		damage = clampi(damage, 1, _CONTACT_DAMAGE_MAX_LEVELS)
		if damage <= 0:
			continue
		changed_tiles_map[tile_id] = true
		var prior_damage = int(tile_height_overrides.get(tile_id, 0))
		tile_height_overrides[tile_id] = max(prior_damage, damage)
	if changed_tiles_map.is_empty():
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var result = _apply_column_surface_delta(controller, env_snapshot, changed_tiles_map.keys(), tile_height_overrides, false)
	result["tick"] = tick
	return result

static func _apply_column_surface_delta(
	controller,
	env_snapshot: Dictionary,
	changed_tiles: Array,
	height_overrides: Dictionary,
	raise_surface: bool
) -> Dictionary:
	var voxel_world: Dictionary = env_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return {"ok": true, "changed": false, "error": ""}
	var sea_level = int(voxel_world.get("sea_level", 1))
	var world_height = int(voxel_world.get("height", 36))
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = i
	var tile_index: Dictionary = env_snapshot.get("tile_index", {})
	var touched_chunks: Dictionary = {}
	var changed_tiles_sorted: Array = []
	for tile_variant in changed_tiles:
		var tile_id = String(tile_variant).strip_edges()
		if tile_id == "" or not column_by_tile.has(tile_id):
			continue
		var column_index = int(column_by_tile.get(tile_id, -1))
		if column_index < 0 or column_index >= columns.size():
			continue
		var column_variant = columns[column_index]
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var x := int(column.get("x", 0))
		var z := int(column.get("z", 0))
		var current_surface := int(column.get("surface_y", sea_level))
		var delta_levels := maxi(1, int(height_overrides.get(tile_id, 1)))
		var next_surface := current_surface
		if raise_surface:
			next_surface = clampi(current_surface + delta_levels, 1, world_height - 2)
		else:
			next_surface = clampi(current_surface - delta_levels, 0, world_height - 2)
		if next_surface == current_surface:
			continue
		column["surface_y"] = next_surface
		if raise_surface:
			column["top_block"] = "stone"
			column["subsoil_block"] = "stone"
		columns[column_index] = column
		touched_chunks["%d:%d" % [int(floor(float(x) / float(chunk_size))), int(floor(float(z) / float(chunk_size)))]] = true
		changed_tiles_sorted.append(tile_id)
		if tile_index.has(tile_id):
			var tile_variant_row = tile_index.get(tile_id, {})
			if tile_variant_row is Dictionary:
				var tile_row = tile_variant_row as Dictionary
				tile_row["elevation"] = clampf(float(next_surface) / float(maxi(1, world_height - 1)), 0.0, 1.0)
				tile_index[tile_id] = tile_row
	if changed_tiles_sorted.is_empty():
		return {"ok": true, "changed": false, "error": ""}
	changed_tiles_sorted.sort_custom(func(a, b): return String(a) < String(b))
	var chunk_rows_by_chunk: Dictionary = voxel_world.get("block_rows_by_chunk", {})
	if chunk_rows_by_chunk.is_empty():
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var cx := int(floor(float(int(column.get("x", 0))) / float(chunk_size)))
			var cz := int(floor(float(int(column.get("z", 0))) / float(chunk_size)))
			touched_chunks["%d:%d" % [cx, cz]] = true
	_rebuild_chunk_rows_from_columns(columns, chunk_rows_by_chunk, chunk_size, sea_level, touched_chunks.keys())
	var block_rows: Array = []
	var block_counts: Dictionary = {}
	var chunk_keys = chunk_rows_by_chunk.keys()
	chunk_keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in chunk_keys:
		var rows_variant = chunk_rows_by_chunk.get(key_variant, [])
		if not (rows_variant is Array):
			continue
		var rows = rows_variant as Array
		block_rows.append_array(rows)
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var block_type = String(row.get("type", "air"))
			block_counts[block_type] = int(block_counts.get(block_type, 0)) + 1
	voxel_world["columns"] = columns
	voxel_world["column_index_by_tile"] = column_by_tile
	voxel_world["block_rows_by_chunk"] = chunk_rows_by_chunk
	voxel_world["block_rows_chunk_size"] = chunk_size
	voxel_world["block_rows"] = block_rows
	voxel_world["block_type_counts"] = block_counts
	voxel_world["surface_y_buffer"] = _pack_surface_y_buffer(columns, int(env_snapshot.get("width", 0)), int(env_snapshot.get("height", 0)))
	env_snapshot["voxel_world"] = voxel_world
	env_snapshot["tile_index"] = tile_index
	var tiles: Array = env_snapshot.get("tiles", [])
	if not tiles.is_empty():
		for i in range(tiles.size()):
			var tile_variant = tiles[i]
			if not (tile_variant is Dictionary):
				continue
			var tile_row = tile_variant as Dictionary
			var tile_id = String(tile_row.get("tile_id", ""))
			if tile_id == "" or not tile_index.has(tile_id):
				continue
			tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)
		env_snapshot["tiles"] = tiles
	controller._environment_snapshot = env_snapshot
	controller._erosion_changed_last_tick = true
	controller._erosion_changed_tiles_last_tick = changed_tiles_sorted.duplicate(true)
	return {
		"ok": true,
		"changed": true,
		"error": "",
		"changed_tiles": changed_tiles_sorted,
		"environment_snapshot": env_snapshot.duplicate(true),
		"water_network_snapshot": controller._water_network_snapshot.duplicate(true),
	}

static func _rebuild_chunk_rows_from_columns(
	columns: Array,
	chunk_rows_by_chunk: Dictionary,
	chunk_size: int,
	sea_level: int,
	target_chunk_keys: Array
) -> void:
	var target: Dictionary = {}
	for key_variant in target_chunk_keys:
		var key = String(key_variant).strip_edges()
		if key == "":
			continue
		target[key] = true
	for key_variant in target.keys():
		var key = String(key_variant)
		var parts = key.split(":")
		if parts.size() != 2:
			continue
		var cx = int(parts[0])
		var cz = int(parts[1])
		var rows: Array = []
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x = int(column.get("x", 0))
			var z = int(column.get("z", 0))
			if int(floor(float(x) / float(chunk_size))) != cx or int(floor(float(z) / float(chunk_size))) != cz:
				continue
			var surface_y = int(column.get("surface_y", sea_level))
			var top_block = String(column.get("top_block", "stone"))
			var subsoil = String(column.get("subsoil_block", "stone"))
			for y in range(surface_y + 1):
				var block_type = "stone"
				if y == surface_y:
					block_type = top_block
				elif y >= surface_y - 2:
					block_type = subsoil
				rows.append({"x": x, "y": y, "z": z, "type": block_type})
			if surface_y < sea_level:
				for wy in range(surface_y + 1, sea_level + 1):
					rows.append({"x": x, "y": wy, "z": z, "type": "water"})
		chunk_rows_by_chunk[key] = rows

static func _pack_surface_y_buffer(columns: Array, width: int, height: int) -> PackedInt32Array:
	var packed := PackedInt32Array()
	if width <= 0 or height <= 0:
		return packed
	packed.resize(width * height)
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var x = int(column.get("x", 0))
		var z = int(column.get("z", 0))
		if x < 0 or x >= width or z < 0 or z >= height:
			continue
		packed[z * width + x] = int(column.get("surface_y", 0))
	return packed
