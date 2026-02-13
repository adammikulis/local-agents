extends RefCounted
class_name LocalAgentsVoxelVolcanicController

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const VoxelEditDispatchScript = preload("res://addons/local_agents/simulation/VoxelEditDispatch.gd")
const _NATIVE_VOXEL_EDIT_STAGE_NAME := &"volcanic_eruption_voxel_ops"

var _rng := RandomNumberGenerator.new()
var _eruption_accum: float = 0.0
var _pending_hydro_changed_tiles: Dictionary = {}
var _pending_hydro_rebake_events: int = 0
var _pending_hydro_rebake_seconds: float = 0.0

func set_seed(seed: int) -> void:
	_rng.seed = seed

func reset() -> void:
	_eruption_accum = 0.0
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0

func clear_pending_rebake() -> void:
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0

func pending_state() -> Dictionary:
	return {
		"events": _pending_hydro_rebake_events,
		"seconds": _pending_hydro_rebake_seconds,
		"tiles": _pending_hydro_changed_tiles.duplicate(true),
	}

func spawn_manual_vent_at(world_snapshot: Dictionary, tx: int, tz: int, sim_tick: int, island_growth: float) -> Dictionary:
	var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
	var existing = find_volcano_by_tile_id(world_snapshot, tile_id)
	if not existing.is_empty():
		return {
			"world": world_snapshot,
			"selected_tile_id": tile_id,
			"feature": existing,
			"created": false,
		}
	var tile_index: Dictionary = world_snapshot.get("tile_index", {})
	var tile = tile_index.get(tile_id, {})
	var geothermal = clampf(float((tile as Dictionary).get("geothermal_activity", 0.4)) if tile is Dictionary else 0.4, 0.0, 1.0)
	var continentalness = clampf(float((tile as Dictionary).get("continentalness", 0.5)) if tile is Dictionary else 0.5, 0.0, 1.0)
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	var feature = {
		"id": "manual_volcano:%d:%d:%d" % [tx, tz, sim_tick],
		"tile_id": tile_id,
		"x": tx,
		"y": tz,
		"radius": clampi(int(round(island_growth)) + 1, 1, 4),
		"cone_height": 3.2 + geothermal * 2.4,
		"crater_depth": 1.0 + geothermal * 1.2,
		"activity": clampf(maxf(0.55, geothermal), 0.0, 1.0),
		"oceanic": clampf((0.62 - continentalness) * 2.0, 0.0, 1.0),
	}
	volcanoes.append(feature)
	geology["volcanic_features"] = volcanoes
	world_snapshot["geology"] = geology
	return {
		"world": world_snapshot,
		"selected_tile_id": tile_id,
		"feature": feature.duplicate(true),
		"created": true,
	}

func try_spawn_new_vent(world_snapshot: Dictionary, sim_tick: int) -> Dictionary:
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	var by_id: Dictionary = {}
	for v_variant in volcanoes:
		if not (v_variant is Dictionary):
			continue
		var v = v_variant as Dictionary
		by_id[String(v.get("tile_id", ""))] = true
	var tiles: Array = world_snapshot.get("tiles", [])
	var best_tile: Dictionary = {}
	var best_score = -1.0
	for tile_variant in tiles:
		if not (tile_variant is Dictionary):
			continue
		var tile = tile_variant as Dictionary
		var tile_id = String(tile.get("tile_id", ""))
		if tile_id == "" or by_id.has(tile_id):
			continue
		var elev = clampf(float(tile.get("elevation", 0.0)), 0.0, 1.0)
		var geothermal = clampf(float(tile.get("geothermal_activity", 0.0)), 0.0, 1.0)
		var continentalness = clampf(float(tile.get("continentalness", 0.5)), 0.0, 1.0)
		var oceanic = clampf((0.62 - continentalness) * 2.0, 0.0, 1.0)
		var near_sea = clampf(1.0 - absf(elev - 0.34) * 2.0, 0.0, 1.0)
		var score = geothermal * 0.58 + oceanic * 0.26 + near_sea * 0.16 + _rng.randf() * 0.15
		if score > best_score:
			best_score = score
			best_tile = tile
	if best_tile.is_empty() or best_score < 0.56:
		return {"world": world_snapshot, "created": false}
	var tx = int(best_tile.get("x", 0))
	var tz = int(best_tile.get("y", 0))
	var feature = {
		"id": "volcano:%d:%d:%d" % [tx, tz, sim_tick],
		"tile_id": TileKeyUtilsScript.tile_id(tx, tz),
		"x": tx,
		"y": tz,
		"radius": _rng.randi_range(1, 3),
		"cone_height": 3.0 + _rng.randf() * 2.4,
		"crater_depth": 1.0 + _rng.randf() * 1.2,
		"activity": clampf(float(best_tile.get("geothermal_activity", 0.5)) * 0.9 + 0.1, 0.2, 1.0),
		"oceanic": clampf((0.62 - float(best_tile.get("continentalness", 0.5))) * 2.0, 0.0, 1.0),
	}
	volcanoes.append(feature)
	geology["volcanic_features"] = volcanoes
	world_snapshot["geology"] = geology
	return {"world": world_snapshot, "created": true, "feature": feature.duplicate(true)}

func step(
	world_snapshot: Dictionary,
	sim_tick: int,
	tick_duration: float,
	ticks_per_frame: int,
	eruption_interval: float,
	new_vent_chance: float,
	island_growth: float,
	manual_eruption_active: bool,
	manual_selected_vent_tile_id: String,
	hydrology_rebake_every_events: int,
	hydrology_rebake_max_seconds: float,
	spawn_lava_plume: Callable
) -> Dictionary:
	if world_snapshot.is_empty():
		return {"world": world_snapshot, "changed": false, "changed_tiles": [], "rebake_due": false, "selected_tile_id": manual_selected_vent_tile_id}
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	if volcanoes.is_empty() and not manual_eruption_active:
		return {"world": world_snapshot, "changed": false, "changed_tiles": [], "rebake_due": false, "selected_tile_id": manual_selected_vent_tile_id}
	var changed_tiles_map: Dictionary = {}
	var selected_tile_id = manual_selected_vent_tile_id
	if manual_eruption_active:
		var manual_volcano = find_volcano_by_tile_id(world_snapshot, selected_tile_id)
		if manual_volcano.is_empty() and selected_tile_id != "":
			var coords = TileKeyUtilsScript.parse_tile_id(selected_tile_id)
			if coords.x != 2147483647 and coords.y != 2147483647:
				var spawned = spawn_manual_vent_at(world_snapshot, coords.x, coords.y, sim_tick, island_growth)
				world_snapshot = spawned.get("world", world_snapshot)
				geology = world_snapshot.get("geology", {})
				volcanoes = geology.get("volcanic_features", [])
				manual_volcano = find_volcano_by_tile_id(world_snapshot, selected_tile_id)
		if manual_volcano.is_empty() and not volcanoes.is_empty():
			manual_volcano = _pick_eruption_volcano(volcanoes)
			selected_tile_id = String(manual_volcano.get("tile_id", selected_tile_id))
		if not manual_volcano.is_empty():
			var bursts = maxi(1, int(round(float(ticks_per_frame) * 0.75)))
			for _i in range(bursts):
				var changed_manual = _apply_eruption_to_world(world_snapshot, manual_volcano, island_growth)
				world_snapshot = changed_manual.get("world", world_snapshot)
				for tile_variant in changed_manual.get("changed_tiles", []):
					changed_tiles_map[String(tile_variant)] = true
				if spawn_lava_plume.is_valid():
					spawn_lava_plume.call(manual_volcano)
	_pending_hydro_rebake_seconds += maxf(0.0, tick_duration)
	_eruption_accum += maxf(0.0, tick_duration)
	if _eruption_accum >= maxf(0.1, eruption_interval):
		_eruption_accum = 0.0
		if _rng.randf() <= clampf(new_vent_chance, 0.0, 1.0):
			var spawned_random = try_spawn_new_vent(world_snapshot, sim_tick)
			world_snapshot = spawned_random.get("world", world_snapshot)
			geology = world_snapshot.get("geology", {})
			volcanoes = geology.get("volcanic_features", [])
		var eruption_count = mini(2, maxi(1, int(round(float(ticks_per_frame) * 0.5))))
		for _i in range(eruption_count):
			var volcano = _pick_eruption_volcano(volcanoes)
			if volcano.is_empty():
				continue
			var changed = _apply_eruption_to_world(world_snapshot, volcano, island_growth)
			world_snapshot = changed.get("world", world_snapshot)
			for tile_variant in changed.get("changed_tiles", []):
				changed_tiles_map[String(tile_variant)] = true
			if spawn_lava_plume.is_valid():
				spawn_lava_plume.call(volcano)
	if changed_tiles_map.is_empty():
		var rebake_due_no_changes = _pending_hydro_rebake_events > 0 and _pending_hydro_rebake_seconds >= hydrology_rebake_max_seconds
		return {"world": world_snapshot, "changed": false, "changed_tiles": [], "rebake_due": rebake_due_no_changes, "selected_tile_id": selected_tile_id}
	_pending_hydro_rebake_events += 1
	for tile_variant in changed_tiles_map.keys():
		_pending_hydro_changed_tiles[String(tile_variant)] = true
	var rebake_due = _pending_hydro_rebake_events >= maxi(1, hydrology_rebake_every_events) or _pending_hydro_rebake_seconds >= hydrology_rebake_max_seconds
	return {
		"world": world_snapshot,
		"changed": true,
		"changed_tiles": changed_tiles_map.keys(),
		"rebake_due": rebake_due,
		"selected_tile_id": selected_tile_id,
	}

func find_volcano_by_tile_id(world_snapshot: Dictionary, tile_id: String) -> Dictionary:
	if tile_id == "":
		return {}
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		if String(volcano.get("tile_id", "")) == tile_id:
			return volcano
	return {}

func _pick_eruption_volcano(volcanoes: Array) -> Dictionary:
	if volcanoes.is_empty():
		return {}
	var best_score = -1.0
	var best: Dictionary = {}
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		var activity = clampf(float(volcano.get("activity", 0.0)), 0.0, 1.0)
		var oceanic = clampf(float(volcano.get("oceanic", 0.0)), 0.0, 1.0)
		var jitter = _rng.randf() * 0.45
		var score = activity * 0.85 + oceanic * 0.25 + jitter
		if score > best_score:
			best_score = score
			best = volcano
	return best

func _apply_eruption_to_world(world_snapshot: Dictionary, volcano: Dictionary, island_growth: float) -> Dictionary:
	var operation_plan = _build_eruption_voxel_edit_ops(world_snapshot, volcano, island_growth)
	var native_result = _dispatch_native_eruption_voxel_ops(world_snapshot, volcano, island_growth, operation_plan)
	if not native_result.is_empty():
		return native_result
	var changed: Array = []
	var voxel_world: Dictionary = world_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var tile_index: Dictionary = world_snapshot.get("tile_index", {})
	var tiles: Array = world_snapshot.get("tiles", [])
	var sea_level = int(voxel_world.get("sea_level", 1))
	var world_height = int(voxel_world.get("height", 36))
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var vx = int(volcano.get("x", 0))
	var vz = int(volcano.get("y", 0))
	var radius = maxi(1, int(volcano.get("radius", 2)))
	var lava_yield = maxf(0.0, island_growth)
	var growth_base = maxf(0.2, lava_yield * (0.7 + float(volcano.get("activity", 0.5))))
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = i
	var affected_chunks: Dictionary = {}
	for dz in range(-radius - 1, radius + 2):
		for dx in range(-radius - 1, radius + 2):
			var tx = vx + dx
			var tz = vz + dz
			if tx < 0 or tz < 0 or tx >= int(world_snapshot.get("width", 0)) or tz >= int(world_snapshot.get("height", 0)):
				continue
			var dist = sqrt(float(dx * dx + dz * dz))
			if dist > float(radius) + 1.0:
				continue
			var falloff = clampf(1.0 - dist / (float(radius) + 1.0), 0.0, 1.0)
			var growth = int(round(growth_base * falloff * 2.2))
			if growth <= 0:
				continue
			var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
			if not column_by_tile.has(tile_id):
				continue
			affected_chunks["%d:%d" % [int(floor(float(tx) / float(chunk_size))), int(floor(float(tz) / float(chunk_size)))]] = true
			var col_idx = int(column_by_tile[tile_id])
			var col = columns[col_idx] as Dictionary
			var surface_y = int(col.get("surface_y", sea_level))
			var next_surface = clampi(surface_y + growth, 1, world_height - 2)
			col["surface_y"] = next_surface
			col["top_block"] = "basalt" if falloff > 0.34 else "obsidian"
			col["subsoil_block"] = "basalt"
			columns[col_idx] = col
			var tile = tile_index.get(tile_id, {})
			if tile is Dictionary:
				var row = tile as Dictionary
				row["elevation"] = clampf(float(next_surface) / float(maxi(1, world_height - 1)), 0.0, 1.0)
				row["geothermal_activity"] = clampf(float(row.get("geothermal_activity", 0.0)) + 0.06 + falloff * 0.12, 0.0, 1.0)
				row["temperature"] = clampf(float(row.get("temperature", 0.0)) + 0.03 + falloff * 0.08, 0.0, 1.0)
				row["water_table_depth"] = maxf(0.0, float(row.get("water_table_depth", 8.0)) + float(growth) * 0.35 - falloff * 1.3)
				row["hydraulic_pressure"] = clampf(float(row.get("hydraulic_pressure", 0.0)) + falloff * 0.08, 0.0, 1.0)
				row["groundwater_recharge"] = clampf(float(row.get("groundwater_recharge", 0.0)) + falloff * 0.03, 0.0, 1.0)
				row["biome"] = "highland" if next_surface > sea_level + 8 else String(row.get("biome", "plains"))
				tile_index[tile_id] = row
			changed.append(tile_id)
	for i in range(tiles.size()):
		var tile_variant = tiles[i]
		if not (tile_variant is Dictionary):
			continue
		var tile = tile_variant as Dictionary
		var tile_id = String(tile.get("tile_id", ""))
		if tile_id == "" or not tile_index.has(tile_id):
			continue
		tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)
	var chunk_rows_by_chunk: Dictionary = voxel_world.get("block_rows_by_chunk", {})
	_rebuild_chunk_rows_from_columns(columns, chunk_rows_by_chunk, chunk_size, sea_level, affected_chunks.keys())
	var block_rows: Array = []
	var counts: Dictionary = {}
	var keys = chunk_rows_by_chunk.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
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
			counts[block_type] = int(counts.get(block_type, 0)) + 1
	voxel_world["columns"] = columns
	voxel_world["column_index_by_tile"] = column_by_tile
	voxel_world["block_rows"] = block_rows
	voxel_world["block_rows_by_chunk"] = chunk_rows_by_chunk
	voxel_world["block_rows_chunk_size"] = chunk_size
	voxel_world["block_type_counts"] = counts
	voxel_world["surface_y_buffer"] = _pack_surface_y_buffer(columns, int(world_snapshot.get("width", 0)), int(world_snapshot.get("height", 0)))
	world_snapshot["voxel_world"] = voxel_world
	world_snapshot["tile_index"] = tile_index
	world_snapshot["tiles"] = tiles
	return {"world": world_snapshot, "changed_tiles": changed}

func _build_eruption_voxel_edit_ops(world_snapshot: Dictionary, volcano: Dictionary, island_growth: float) -> Dictionary:
	var operations: Array = []
	var changed_tiles_map: Dictionary = {}
	var vx = int(volcano.get("x", 0))
	var vz = int(volcano.get("y", 0))
	var radius = maxi(1, int(volcano.get("radius", 2)))
	var crater_depth = maxf(0.0, float(volcano.get("crater_depth", 1.0)))
	var lava_yield = maxf(0.0, island_growth)
	var growth_base = maxf(0.2, lava_yield * (0.7 + float(volcano.get("activity", 0.5))))
	var width = int(world_snapshot.get("width", 0))
	var height = int(world_snapshot.get("height", 0))
	for dz in range(-radius - 1, radius + 2):
		for dx in range(-radius - 1, radius + 2):
			var tx = vx + dx
			var tz = vz + dz
			if tx < 0 or tz < 0 or tx >= width or tz >= height:
				continue
			var dist = sqrt(float(dx * dx + dz * dz))
			if dist > float(radius) + 1.0:
				continue
			var falloff = clampf(1.0 - dist / (float(radius) + 1.0), 0.0, 1.0)
			var growth = int(round(growth_base * falloff * 2.2))
			if growth <= 0:
				continue
			var op_type = "deposit"
			var level_delta = growth
			if dist <= maxf(1.0, float(radius) * 0.35):
				op_type = "crater"
				level_delta = -maxi(1, int(round(crater_depth * clampf(1.0 - dist / maxf(1.0, float(radius)), 0.0, 1.0))))
			elif dist <= maxf(1.0, float(radius) * 0.72):
				op_type = "carve"
				var carve_depth = int(round(maxf(1.0, crater_depth * 0.45) * falloff))
				level_delta = -maxi(1, carve_depth)
			var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
			operations.append({
				"type": op_type,
				"tile_id": tile_id,
				"x": tx,
				"z": tz,
				"delta_levels": level_delta,
				"falloff": falloff,
				"radius": radius,
				"center_x": vx,
				"center_z": vz,
				"top_block": "basalt" if falloff > 0.34 else "obsidian",
				"subsoil_block": "basalt",
			})
			changed_tiles_map[tile_id] = true
	var changed_tiles: Array = changed_tiles_map.keys()
	changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
	return {"operations": operations, "changed_tiles": changed_tiles}

func _dispatch_native_eruption_voxel_ops(world_snapshot: Dictionary, volcano: Dictionary, island_growth: float, operation_plan: Dictionary) -> Dictionary:
	var operations: Array = operation_plan.get("operations", [])
	if operations.is_empty():
		return {}
	var stage_result = VoxelEditDispatchScript.dispatch_operations(
		NativeComputeBridgeScript.is_native_sim_core_enabled(),
		_NATIVE_VOXEL_EDIT_STAGE_NAME,
		{
			"world": world_snapshot.duplicate(true),
			"volcano": volcano.duplicate(true),
			"island_growth": island_growth,
			"operations": operations.duplicate(true),
		}
	)
	if stage_result.is_empty():
		return {}
	var world_variant = stage_result.get("world", world_snapshot)
	if not (world_variant is Dictionary):
		return {}
	var changed_tiles = VoxelEditDispatchScript.normalize_changed_tiles(stage_result.get("changed_tiles", operation_plan.get("changed_tiles", [])))
	return {"world": world_variant as Dictionary, "changed_tiles": changed_tiles}

func _rebuild_chunk_rows_from_columns(
	columns: Array,
	chunk_rows_by_chunk: Dictionary,
	chunk_size: int,
	sea_level: int,
	target_chunk_keys: Array
) -> void:
	var target: Dictionary = {}
	for key_variant in target_chunk_keys:
		var key = String(key_variant)
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

func _pack_surface_y_buffer(columns: Array, width: int, height: int) -> PackedInt32Array:
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
