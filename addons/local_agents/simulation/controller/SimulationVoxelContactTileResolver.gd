extends RefCounted
class_name LocalAgentsSimulationVoxelContactTileResolver

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

static func resolve_existing_contact_tile(env_snapshot: Dictionary, contact_point: Vector3, preferred_tiles: Array = []) -> Dictionary:
	var voxel_world: Dictionary = env_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return {}
	var column_by_tile := _column_index_by_tile(voxel_world, columns)
	if column_by_tile.is_empty():
		return {}
	var width := int(env_snapshot.get("width", int(voxel_world.get("width", 0))))
	var height := int(env_snapshot.get("height", int(voxel_world.get("depth", 0))))
	if width <= 0 or height <= 0:
		return {}

	var candidates: Dictionary = {}
	for tile_variant in preferred_tiles:
		var tile_id := String(tile_variant).strip_edges()
		if tile_id != "" and column_by_tile.has(tile_id):
			candidates[tile_id] = true

	var direct_x := clampi(int(round(contact_point.x)), 0, width - 1)
	var direct_z := clampi(int(round(contact_point.z)), 0, height - 1)
	var direct_id := TileKeyUtilsScript.tile_id(direct_x, direct_z)
	if column_by_tile.has(direct_id):
		candidates[direct_id] = true

	for radius in range(1, 3):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var nx := clampi(direct_x + dx, 0, width - 1)
				var nz := clampi(direct_z + dz, 0, height - 1)
				var neighbor_id := TileKeyUtilsScript.tile_id(nx, nz)
				if column_by_tile.has(neighbor_id):
					candidates[neighbor_id] = true

	if candidates.is_empty():
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			candidates[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = true

	var best_tile_id := ""
	var best_score := INF
	for tile_variant in candidates.keys():
		var tile_id := String(tile_variant)
		var parsed := TileKeyUtilsScript.parse_tile_id(tile_id)
		if parsed.x == 2147483647:
			continue
		var column_index := int(column_by_tile.get(tile_id, -1))
		if column_index < 0 or column_index >= columns.size():
			continue
		var column_variant = columns[column_index]
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var surface := int(column.get("surface_y", 0))
		var dx := float(parsed.x) - contact_point.x
		var dz := float(parsed.y) - contact_point.z
		var score := dx * dx + dz * dz
		if surface <= 0:
			score += 1000000.0
		if score < best_score:
			best_score = score
			best_tile_id = tile_id

	if best_tile_id == "":
		return {}
	var resolved := TileKeyUtilsScript.parse_tile_id(best_tile_id)
	if resolved.x == 2147483647:
		return {}
	return {"x": resolved.x, "z": resolved.y, "tile_id": best_tile_id}

static func _column_index_by_tile(voxel_world: Dictionary, columns: Array) -> Dictionary:
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = i
	return column_by_tile
