extends RefCounted
class_name LocalAgentsErosionSystem

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")

var _configured: bool = false
var _seed: int = 0
var _erosion_by_tile: Dictionary = {}
var _frost_damage_by_tile: Dictionary = {}
var _previous_temperature_by_tile: Dictionary = {}
var _landslide_events: Array = []
var _last_changed_tiles: Array = []

func configure_environment(environment_snapshot: Dictionary, _water_snapshot: Dictionary, seed: int) -> void:
	_configured = true
	_seed = seed
	_erosion_by_tile.clear()
	_frost_damage_by_tile.clear()
	_previous_temperature_by_tile.clear()
	_landslide_events = []
	_last_changed_tiles = []
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	for tile_id_variant in tile_index.keys():
		var tile_id = String(tile_id_variant)
		var tile = tile_index.get(tile_id_variant, {})
		var temperature = clampf(float((tile as Dictionary).get("temperature", 0.5)) if tile is Dictionary else 0.5, 0.0, 1.0)
		_erosion_by_tile[tile_id] = 0.0
		_frost_damage_by_tile[tile_id] = 0.0
		_previous_temperature_by_tile[tile_id] = temperature

func step(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	weather_snapshot: Dictionary
) -> Dictionary:
	if not _configured:
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"erosion": current_snapshot(tick),
			"changed": false,
			"changed_tiles": [],
		}

	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	if tile_index.is_empty():
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"erosion": current_snapshot(tick),
			"changed": false,
			"changed_tiles": [],
		}

	var weather_tiles: Dictionary = weather_snapshot.get("tile_index", {})
	var water_tiles: Dictionary = water_snapshot.get("water_tiles", {})
	var changed_ids: Dictionary = {}
	var landslide_rows: Array = []
	var flow_scale = _max_flow(water_tiles)
	var step_scale = clampf(delta, 0.1, 2.0)

	for tile_id_variant in tile_index.keys():
		var tile_id = String(tile_id_variant)
		var tile = tile_index.get(tile_id, {})
		if not (tile is Dictionary):
			continue
		var tile_row = tile as Dictionary
		var weather_row = weather_tiles.get(tile_id, {})
		var water_row = water_tiles.get(tile_id, {})
		var rain = clampf(float((weather_row as Dictionary).get("rain", weather_snapshot.get("avg_rain_intensity", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
		var cloud = clampf(float((weather_row as Dictionary).get("cloud", weather_snapshot.get("avg_cloud_cover", 0.0)) if weather_row is Dictionary else weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
		var wetness = clampf(float((weather_row as Dictionary).get("wetness", rain)) if weather_row is Dictionary else rain, 0.0, 1.0)
		var slope = clampf(float(tile_row.get("slope", 0.0)), 0.0, 1.0)
		var base_temperature = clampf(float(tile_row.get("temperature", 0.5)), 0.0, 1.0)
		var thermal_phase = float(tick) * 0.073 + _deterministic_noise(tile_id, 0) * TAU
		var seasonal_swing = sin(thermal_phase) * 0.065
		var weather_cooling = rain * 0.038 + cloud * 0.024
		var temperature = clampf(base_temperature + seasonal_swing - weather_cooling, 0.0, 1.0)
		var prev_temperature = clampf(float(_previous_temperature_by_tile.get(tile_id, temperature)), 0.0, 1.0)
		var flow = clampf(float((water_row as Dictionary).get("flow", 0.0)) if water_row is Dictionary else 0.0, 0.0, flow_scale)
		var water_reliability = clampf(float((water_row as Dictionary).get("water_reliability", 0.0)) if water_row is Dictionary else 0.0, 0.0, 1.0)
		var flow_norm = 0.0 if flow_scale <= 0.0001 else clampf(flow / flow_scale, 0.0, 1.0)
		var freeze_thresh = 0.34
		var prev_freezing = prev_temperature <= freeze_thresh
		var now_freezing = temperature <= freeze_thresh
		var crossed_freeze = prev_freezing != now_freezing
		var freeze_band = 1.0 - clampf(absf(temperature - freeze_thresh) / 0.22, 0.0, 1.0)
		var freeze_water = clampf(wetness * 0.56 + water_reliability * 0.44, 0.0, 1.0)
		var crack_factor = clampf(slope * 0.72 + flow_norm * 0.28, 0.0, 1.0)
		var frost_impulse = 0.0
		if crossed_freeze:
			# Water freezing and thawing around cracks drives shattering.
			frost_impulse = freeze_band * freeze_water * (0.32 + crack_factor * 0.68)
		var frost_damage = clampf(float(_frost_damage_by_tile.get(tile_id, 0.0)) * 0.982 + frost_impulse * 0.12, 0.0, 1.0)
		_frost_damage_by_tile[tile_id] = frost_damage
		var base_erosion = maxf(0.0, (slope * 0.62 + flow_norm * 0.38) * rain * 0.028 * step_scale)
		var frost_erosion = frost_damage * (0.004 + crack_factor * 0.006) * step_scale
		base_erosion += frost_erosion
		var cumulative = float(_erosion_by_tile.get(tile_id, 0.0)) + base_erosion
		_erosion_by_tile[tile_id] = cumulative
		_previous_temperature_by_tile[tile_id] = temperature

		var elev_drop = 0.0
		if cumulative >= 0.12:
			var cycles = int(floor(cumulative / 0.12))
			_erosion_by_tile[tile_id] = cumulative - float(cycles) * 0.12
			elev_drop = 0.004 * float(cycles)

		var freeze_slide_risk = frost_damage * (0.5 + freeze_water * 0.5)
		var landslide_trigger = (
			(slope > 0.68 and rain > 0.58 and flow_norm > 0.35)
			or (slope > 0.6 and freeze_slide_risk > 0.42 and crossed_freeze)
		)
		if landslide_trigger and _deterministic_noise(tile_id, tick) > 0.72:
			elev_drop += 0.012 + slope * 0.01 + freeze_slide_risk * 0.006
			landslide_rows.append({
				"tick": tick,
				"tile_id": tile_id,
				"severity": clampf(elev_drop * 48.0, 0.0, 1.0),
				"rain": rain,
				"slope": slope,
				"freeze_thaw": freeze_slide_risk,
			})

		if elev_drop <= 0.0:
			continue
		changed_ids[tile_id] = elev_drop
		tile_row["elevation"] = clampf(float(tile_row.get("elevation", 0.0)) - elev_drop, 0.0, 1.0)
		tile_row["slope"] = clampf(float(tile_row.get("slope", 0.0)) * (0.985 + rain * 0.01 + frost_damage * 0.012), 0.0, 1.0)
		tile_row["moisture"] = clampf(float(tile_row.get("moisture", 0.0)) + rain * 0.01, 0.0, 1.0)
		tile_row["freeze_thaw_damage"] = frost_damage
		tile_index[tile_id] = tile_row

		var hydro = water_tiles.get(tile_id, {})
		if hydro is Dictionary:
			var h = (hydro as Dictionary).duplicate(true)
			h["flood_risk"] = clampf(float(h.get("flood_risk", 0.0)) + rain * 0.05 + slope * 0.04, 0.0, 1.0)
			h["water_reliability"] = clampf(float(h.get("water_reliability", 0.0)) - elev_drop * 3.5 + rain * 0.01, 0.0, 1.0)
			water_tiles[tile_id] = h

	_update_tiles_array(environment_snapshot, tile_index)
	water_snapshot["water_tiles"] = water_tiles
	var voxel_changed = _apply_voxel_surface_erosion(environment_snapshot, changed_ids)
	var changed_tiles: Array = changed_ids.keys()
	changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
	_last_changed_tiles = changed_tiles.duplicate(true)
	if not landslide_rows.is_empty():
		_landslide_events.append_array(landslide_rows)
	if _landslide_events.size() > 128:
		_landslide_events = _landslide_events.slice(_landslide_events.size() - 128, _landslide_events.size())

	return {
		"environment": environment_snapshot,
		"hydrology": water_snapshot,
		"erosion": current_snapshot(tick),
		"changed": (not changed_ids.is_empty()) or voxel_changed or (not landslide_rows.is_empty()),
		"changed_tiles": _last_changed_tiles.duplicate(true),
	}

func current_snapshot(tick: int) -> Dictionary:
	var rows: Array = []
	var keys = _erosion_by_tile.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for tile_id_variant in keys:
		var tile_id = String(tile_id_variant)
		rows.append({
			"tile_id": tile_id,
			"erosion_budget": float(_erosion_by_tile.get(tile_id, 0.0)),
			"frost_damage": float(_frost_damage_by_tile.get(tile_id, 0.0)),
			"temperature_prev": float(_previous_temperature_by_tile.get(tile_id, 0.5)),
		})
	return {
		"schema_version": 1,
		"tick": tick,
		"rows": rows,
		"recent_landslides": _landslide_events.duplicate(true),
		"changed_tiles": _last_changed_tiles.duplicate(true),
	}

func import_snapshot(snapshot: Dictionary) -> void:
	_erosion_by_tile.clear()
	_frost_damage_by_tile.clear()
	_previous_temperature_by_tile.clear()
	var rows: Array = snapshot.get("rows", [])
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var tile_id = String(row.get("tile_id", ""))
		if tile_id == "":
			continue
		_erosion_by_tile[tile_id] = maxf(0.0, float(row.get("erosion_budget", 0.0)))
		_frost_damage_by_tile[tile_id] = clampf(float(row.get("frost_damage", 0.0)), 0.0, 1.0)
		_previous_temperature_by_tile[tile_id] = clampf(float(row.get("temperature_prev", 0.5)), 0.0, 1.0)
	_landslide_events = (snapshot.get("recent_landslides", []) as Array).duplicate(true)
	_last_changed_tiles = (snapshot.get("changed_tiles", []) as Array).duplicate(true)

func _update_tiles_array(environment_snapshot: Dictionary, tile_index: Dictionary) -> void:
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

func _apply_voxel_surface_erosion(environment_snapshot: Dictionary, changed_ids: Dictionary) -> bool:
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
		voxel_world["block_rows"] = _rebuild_block_rows(voxel_world)
		voxel_world["block_type_counts"] = _recount_block_types(voxel_world.get("block_rows", []))
		environment_snapshot["voxel_world"] = voxel_world
	return changed

func _rebuild_block_rows(voxel_world: Dictionary) -> Array:
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

func _recount_block_types(block_rows: Array) -> Dictionary:
	var counts: Dictionary = {}
	for row_variant in block_rows:
		if not (row_variant is Dictionary):
			continue
		var block = row_variant as Dictionary
		var block_type = String(block.get("type", "air"))
		counts[block_type] = int(counts.get(block_type, 0)) + 1
	return counts

func _max_flow(water_tiles: Dictionary) -> float:
	var m = 0.0
	for tile_id_variant in water_tiles.keys():
		var row = water_tiles.get(tile_id_variant, {})
		if row is Dictionary:
			m = maxf(m, float((row as Dictionary).get("flow", 0.0)))
	return maxf(1.0, m)

func _deterministic_noise(tile_id: String, tick: int) -> float:
	var h = hash("%s|%d|%d" % [tile_id, tick, _seed])
	var n = abs(int(h) % 10000)
	return float(n) / 10000.0
