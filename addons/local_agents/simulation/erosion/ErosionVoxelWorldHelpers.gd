extends RefCounted
class_name LocalAgentsErosionVoxelWorldHelpers

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

static func update_tiles_array(environment_snapshot: Dictionary, tile_index: Dictionary) -> void:
	var tiles: Array = environment_snapshot.get("tiles", [])
	for i in range(tiles.size()):
		if not (tiles[i] is Dictionary):
			continue
		var row = tiles[i] as Dictionary
		var tile_id = String(row.get("tile_id", "%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]))
		if tile_index.has(tile_id):
			tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)
	environment_snapshot["tiles"] = tiles
	environment_snapshot["tile_index"] = tile_index

static func apply_voxel_surface_erosion(environment_snapshot: Dictionary, changed_ids: Dictionary) -> bool:
	if changed_ids.is_empty():
		return false
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	if voxel_world.is_empty():
		return false
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return false
	var world_height = int(voxel_world.get("height", 0))
	var changed = false
	for i in range(columns.size()):
		if not (columns[i] is Dictionary):
			continue
		var c = columns[i] as Dictionary
		var tile_id = TileKeyUtilsScript.tile_id(int(c.get("x", 0)), int(c.get("z", 0)))
		var elev_drop = float(changed_ids.get(tile_id, 0.0))
		if elev_drop <= 0.0:
			continue
		var levels = maxi(0, int(round(elev_drop * float(maxi(8, world_height)))))
		if levels <= 0:
			continue
		var old_surface = int(c.get("surface_y", 0))
		var new_surface = maxi(1, old_surface - levels)
		if new_surface == old_surface:
			continue
		c["surface_y"] = new_surface
		columns[i] = c
		changed = true
	if changed:
		voxel_world["columns"] = columns
		voxel_world["block_rows"] = rebuild_block_rows(voxel_world)
		voxel_world["column_index_by_tile"] = build_column_index(columns)
		var width = int(environment_snapshot.get("width", 0))
		var height = int(environment_snapshot.get("height", 0))
		voxel_world["surface_y_buffer"] = build_surface_y_buffer(columns, width, height)
		var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
		voxel_world["block_rows_chunk_size"] = chunk_size
		voxel_world["block_rows_by_chunk"] = build_chunk_row_index(voxel_world.get("block_rows", []), chunk_size)
		voxel_world["block_type_counts"] = recount_block_types(voxel_world.get("block_rows", []))
		environment_snapshot["voxel_world"] = voxel_world
	return changed

static func rebuild_block_rows(voxel_world: Dictionary) -> Array:
	var rows: Array = []
	var columns: Array = voxel_world.get("columns", [])
	var sea_level = int(voxel_world.get("sea_level", 0))
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var c = column_variant as Dictionary
		var x = int(c.get("x", 0))
		var z = int(c.get("z", 0))
		var surface = int(c.get("surface_y", 1))
		var top_block = String(c.get("top_block", "grass"))
		var subsoil = String(c.get("subsoil_block", "dirt"))
		for y in range(surface + 1):
			var block_type = "stone"
			if y == surface:
				block_type = top_block
			elif y >= surface - 2:
				block_type = subsoil
			rows.append({"x": x, "y": y, "z": z, "type": block_type})
		if surface < sea_level:
			for y in range(surface + 1, sea_level + 1):
				rows.append({"x": x, "y": y, "z": z, "type": "water"})
	return rows

static func recount_block_types(block_rows: Array) -> Dictionary:
	var counts: Dictionary = {}
	for row_variant in block_rows:
		if not (row_variant is Dictionary):
			continue
		var block = row_variant as Dictionary
		var block_type = String(block.get("type", "air"))
		counts[block_type] = int(counts.get(block_type, 0)) + 1
	return counts

static func build_column_index(columns: Array) -> Dictionary:
	var index: Dictionary = {}
	for i in range(columns.size()):
		if not (columns[i] is Dictionary):
			continue
		var c = columns[i] as Dictionary
		index[TileKeyUtilsScript.tile_id(int(c.get("x", 0)), int(c.get("z", 0)))] = i
	return index

static func build_chunk_row_index(block_rows: Array, chunk_size: int) -> Dictionary:
	var size = maxi(4, chunk_size)
	var by_chunk: Dictionary = {}
	for row_variant in block_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var x = int(row.get("x", 0))
		var z = int(row.get("z", 0))
		var cx = int(floor(float(x) / float(size)))
		var cz = int(floor(float(z) / float(size)))
		var key = "%d:%d" % [cx, cz]
		var rows: Array = by_chunk.get(key, [])
		rows.append(row)
		by_chunk[key] = rows
	return by_chunk

static func build_surface_y_buffer(columns: Array, width: int, height: int) -> PackedInt32Array:
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
