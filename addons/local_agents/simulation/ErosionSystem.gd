extends RefCounted
class_name LocalAgentsErosionSystem

const ErosionComputeBackendScript = preload("res://addons/local_agents/simulation/ErosionComputeBackend.gd")
const ErosionVoxelWorldHelpersScript = preload("res://addons/local_agents/simulation/erosion/ErosionVoxelWorldHelpers.gd")

var _configured: bool = false
var _emit_rows: bool = true
var _seed: int = 0
var _erosion_by_tile: Dictionary = {}
var _frost_damage_by_tile: Dictionary = {}
var _previous_temperature_by_tile: Dictionary = {}
var _landslide_events: Array = []
var _last_changed_tiles: Array = []
var _ordered_tile_ids: Array[String] = []
var _slope_buffer := PackedFloat32Array()
var _temp_base_buffer := PackedFloat32Array()
var _activity_buffer := PackedFloat32Array()
var _erosion_buffer := PackedFloat32Array()
var _frost_buffer := PackedFloat32Array()
var _temp_prev_buffer := PackedFloat32Array()
var _compute_requested: bool = false
var _compute_active: bool = false
var _compute_backend = ErosionComputeBackendScript.new()
var _idle_cadence: int = 8
var _geomorph_apply_interval_ticks: int = 6
var _geomorph_last_apply_tick: int = -1
var _pending_geomorph_delta_by_tile: Dictionary = {}

func set_emit_rows(enabled: bool) -> void:
	_emit_rows = enabled

func set_geomorph_apply_interval_ticks(interval_ticks: int) -> void:
	_geomorph_apply_interval_ticks = maxi(1, interval_ticks)

func apply_geomorph_delta(
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	delta_by_tile: Dictionary,
	options: Dictionary = {}
) -> Dictionary:
	if delta_by_tile.is_empty():
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if tile_index.is_empty() or columns.is_empty():
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	var world_height = maxi(8, int(voxel_world.get("height", 8)))
	var column_index: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_index.is_empty():
		column_index = ErosionVoxelWorldHelpersScript.build_column_index(columns)
	var column_overrides: Dictionary = options.get("column_overrides", {})
	var water_tiles: Dictionary = water_snapshot.get("water_tiles", {})
	var changed_tiles: Array = []
	var changed_map: Dictionary = {}
	for tile_id_variant in delta_by_tile.keys():
		var tile_id = String(tile_id_variant)
		var delta = float(delta_by_tile.get(tile_id, 0.0))
		if absf(delta) <= 0.000001:
			continue
		if not tile_index.has(tile_id):
			continue
		var tile = tile_index.get(tile_id, {})
		if not (tile is Dictionary):
			continue
		var tile_row = tile as Dictionary
		var old_elev = clampf(float(tile_row.get("elevation", 0.0)), 0.0, 1.0)
		var next_elev = clampf(old_elev + delta, 0.0, 1.0)
		if absf(next_elev - old_elev) <= 0.000001:
			continue
		tile_row["elevation"] = next_elev
		tile_index[tile_id] = tile_row
		if not column_index.has(tile_id):
			continue
		var idx = int(column_index.get(tile_id, -1))
		if idx < 0 or idx >= columns.size() or not (columns[idx] is Dictionary):
			continue
		var col = columns[idx] as Dictionary
		var old_surface = int(col.get("surface_y", 0))
		var delta_levels = int(round((next_elev - old_elev) * float(maxi(1, world_height - 1))))
		if delta_levels == 0:
			delta_levels = 1 if next_elev > old_elev else -1
		var new_surface = clampi(old_surface + delta_levels, 1, world_height - 2)
		if new_surface == old_surface:
			continue
		col["surface_y"] = new_surface
		if column_overrides.has(tile_id) and column_overrides.get(tile_id, {}) is Dictionary:
			var ov = column_overrides.get(tile_id, {}) as Dictionary
			if ov.has("top_block"):
				col["top_block"] = String(ov.get("top_block", col.get("top_block", "stone")))
			if ov.has("subsoil_block"):
				col["subsoil_block"] = String(ov.get("subsoil_block", col.get("subsoil_block", "stone")))
		columns[idx] = col
		changed_map[tile_id] = true
		var hydro = water_tiles.get(tile_id, {})
		if hydro is Dictionary:
			var h = (hydro as Dictionary).duplicate(true)
			var wet_adj = -delta * 0.35
			h["water_reliability"] = clampf(float(h.get("water_reliability", 0.0)) + wet_adj, 0.0, 1.0)
			h["flood_risk"] = clampf(float(h.get("flood_risk", 0.0)) + maxf(0.0, -delta) * 0.08, 0.0, 1.0)
			water_tiles[tile_id] = h
	for tile_id_variant in changed_map.keys():
		changed_tiles.append(String(tile_id_variant))
	changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
	if changed_tiles.is_empty():
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	ErosionVoxelWorldHelpersScript.update_tiles_array(environment_snapshot, tile_index)
	voxel_world["columns"] = columns
	voxel_world["column_index_by_tile"] = ErosionVoxelWorldHelpersScript.build_column_index(columns)
	voxel_world["block_rows"] = ErosionVoxelWorldHelpersScript.rebuild_block_rows(voxel_world)
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	voxel_world["block_rows_chunk_size"] = chunk_size
	voxel_world["block_rows_by_chunk"] = ErosionVoxelWorldHelpersScript.build_chunk_row_index(voxel_world.get("block_rows", []), chunk_size)
	voxel_world["block_type_counts"] = ErosionVoxelWorldHelpersScript.recount_block_types(voxel_world.get("block_rows", []))
	var width = int(environment_snapshot.get("width", 0))
	var height = int(environment_snapshot.get("height", 0))
	voxel_world["surface_y_buffer"] = ErosionVoxelWorldHelpersScript.build_surface_y_buffer(columns, width, height)
	environment_snapshot["voxel_world"] = voxel_world
	water_snapshot["water_tiles"] = water_tiles
	return {
		"environment": environment_snapshot,
		"hydrology": water_snapshot,
		"voxel_changed": true,
		"changed_tiles": changed_tiles,
	}

func set_compute_enabled(enabled: bool) -> void:
	_compute_requested = enabled
	if not enabled:
		_compute_active = false
		return
	if not _configured:
		return
	_compute_active = _compute_backend.configure(_slope_buffer, _temp_base_buffer, _activity_buffer, _erosion_buffer, _frost_buffer, _temp_prev_buffer)

func is_compute_active() -> bool:
	return _compute_active

func configure_environment(environment_snapshot: Dictionary, _water_snapshot: Dictionary, seed: int) -> void:
	_configured = true
	_seed = seed
	_erosion_by_tile.clear()
	_frost_damage_by_tile.clear()
	_previous_temperature_by_tile.clear()
	_landslide_events = []
	_last_changed_tiles = []
	_ordered_tile_ids.clear()
	_geomorph_last_apply_tick = -1
	_pending_geomorph_delta_by_tile.clear()
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var keys = tile_index.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	_slope_buffer.resize(keys.size())
	_temp_base_buffer.resize(keys.size())
	_activity_buffer.resize(keys.size())
	_erosion_buffer.resize(keys.size())
	_frost_buffer.resize(keys.size())
	_temp_prev_buffer.resize(keys.size())
	for i in range(keys.size()):
		var tile_id_variant = keys[i]
		var tile_id = String(tile_id_variant)
		var tile = tile_index.get(tile_id_variant, {})
		var slope = clampf(float((tile as Dictionary).get("slope", 0.0)) if tile is Dictionary else 0.0, 0.0, 1.0)
		var temperature = clampf(float((tile as Dictionary).get("temperature", 0.5)) if tile is Dictionary else 0.5, 0.0, 1.0)
		_ordered_tile_ids.append(tile_id)
		_erosion_by_tile[tile_id] = 0.0
		_frost_damage_by_tile[tile_id] = 0.0
		_previous_temperature_by_tile[tile_id] = temperature
		_slope_buffer[i] = slope
		_temp_base_buffer[i] = temperature
		_activity_buffer[i] = 0.0
		_erosion_buffer[i] = 0.0
		_frost_buffer[i] = 0.0
		_temp_prev_buffer[i] = temperature
	_compute_active = false
	if _compute_requested:
		_compute_active = _compute_backend.configure(_slope_buffer, _temp_base_buffer, _activity_buffer, _erosion_buffer, _frost_buffer, _temp_prev_buffer)

func step(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	weather_snapshot: Dictionary,
	local_activity: Dictionary = {}
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
	var weather_buffers: Dictionary = weather_snapshot.get("buffers", {})
	var weather_rain: PackedFloat32Array = weather_buffers.get("rain", PackedFloat32Array())
	var weather_cloud: PackedFloat32Array = weather_buffers.get("cloud", PackedFloat32Array())
	var weather_wetness: PackedFloat32Array = weather_buffers.get("wetness", PackedFloat32Array())
	var can_compute = _compute_active and weather_rain.size() == _ordered_tile_ids.size() and weather_cloud.size() == _ordered_tile_ids.size() and weather_wetness.size() == _ordered_tile_ids.size()
	if can_compute:
		return _step_compute(
			tick,
			delta,
			environment_snapshot,
			water_snapshot,
			water_tiles,
			weather_rain,
			weather_cloud,
			weather_wetness,
			local_activity
		)
	return _step_cpu(tick, delta, environment_snapshot, water_snapshot, weather_snapshot, tile_index, weather_tiles, water_tiles, local_activity)

func _step_cpu(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	weather_snapshot: Dictionary,
	tile_index: Dictionary,
	weather_tiles: Dictionary,
	water_tiles: Dictionary,
	local_activity: Dictionary
) -> Dictionary:
	var changed_ids: Dictionary = {}
	var landslide_rows: Array = []
	var flow_scale = _max_flow(water_tiles)
	var step_scale = clampf(delta, 0.1, 2.0)

	for tile_id_variant in tile_index.keys():
		var tile_id = String(tile_id_variant)
		var activity = _activity_value(local_activity, tile_id)
		var cadence = _cadence_for_activity(activity)
		if cadence > 1 and not _should_step_tile(tile_id, tick, cadence):
			continue
		var local_step_scale = step_scale * float(cadence)
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
		var base_erosion = maxf(0.0, (slope * 0.62 + flow_norm * 0.38) * rain * 0.028 * local_step_scale)
		var frost_erosion = frost_damage * (0.004 + crack_factor * 0.006) * local_step_scale
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

	var delta_by_tile: Dictionary = {}
	for tile_id_variant in changed_ids.keys():
		var tile_id = String(tile_id_variant)
		delta_by_tile[tile_id] = -absf(float(changed_ids.get(tile_id, 0.0)))
	var geomorph_result = _apply_batched_geomorph_delta(tick, environment_snapshot, water_snapshot, delta_by_tile)
	environment_snapshot = geomorph_result.get("environment", environment_snapshot)
	water_snapshot = geomorph_result.get("hydrology", water_snapshot)
	var voxel_changed = bool(geomorph_result.get("voxel_changed", false))
	var changed_tiles: Array = geomorph_result.get("changed_tiles", [])
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

func _step_compute(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	water_tiles: Dictionary,
	weather_rain: PackedFloat32Array,
	weather_cloud: PackedFloat32Array,
	weather_wetness: PackedFloat32Array,
	local_activity: Dictionary
) -> Dictionary:
	var count = _ordered_tile_ids.size()
	if count <= 0:
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"erosion": current_snapshot(tick),
			"changed": false,
			"changed_tiles": [],
		}
	var flow_norm := PackedFloat32Array()
	var water_rel := PackedFloat32Array()
	flow_norm.resize(count)
	water_rel.resize(count)
	var flow_scale = _max_flow(water_tiles)
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	for i in range(count):
		var tile_id = _ordered_tile_ids[i]
		var w = water_tiles.get(tile_id, {})
		var flow = 0.0
		var reliability = 0.0
		if w is Dictionary:
			flow = clampf(float((w as Dictionary).get("flow", 0.0)), 0.0, flow_scale)
			reliability = clampf(float((w as Dictionary).get("water_reliability", 0.0)), 0.0, 1.0)
		flow_norm[i] = 0.0 if flow_scale <= 0.0001 else clampf(flow / flow_scale, 0.0, 1.0)
		water_rel[i] = reliability
		_activity_buffer[i] = _activity_value(local_activity, tile_id)
	var gpu = _compute_backend.step(
		weather_rain,
		weather_cloud,
		weather_wetness,
		flow_norm,
		water_rel,
		_activity_buffer,
		tick,
		delta,
		float(abs(_seed % 1024)) * 0.013,
		_idle_cadence
	)
	if gpu.is_empty():
		_compute_active = false
		var weather_tiles: Dictionary = {}
		var weather_snapshot := {
			"tile_index": weather_tiles,
			"avg_rain_intensity": 0.0,
			"avg_cloud_cover": 0.0,
		}
		return _step_cpu(tick, delta, environment_snapshot, water_snapshot, weather_snapshot, tile_index, weather_tiles, water_tiles, local_activity)
	var budget: PackedFloat32Array = gpu.get("erosion_budget", _erosion_buffer)
	var frost: PackedFloat32Array = gpu.get("frost_damage", _frost_buffer)
	var temp_prev: PackedFloat32Array = gpu.get("temp_prev", _temp_prev_buffer)
	var elev_drop: PackedFloat32Array = gpu.get("elev_drop", PackedFloat32Array())
	var delta_by_tile: Dictionary = {}
	for i in range(mini(count, elev_drop.size())):
		var tile_id = _ordered_tile_ids[i]
		var drop = maxf(0.0, float(elev_drop[i]))
		_erosion_buffer[i] = float(budget[i]) if i < budget.size() else _erosion_buffer[i]
		_frost_buffer[i] = float(frost[i]) if i < frost.size() else _frost_buffer[i]
		_temp_prev_buffer[i] = float(temp_prev[i]) if i < temp_prev.size() else _temp_prev_buffer[i]
		_erosion_by_tile[tile_id] = _erosion_buffer[i]
		_frost_damage_by_tile[tile_id] = _frost_buffer[i]
		_previous_temperature_by_tile[tile_id] = _temp_prev_buffer[i]
		if drop <= 0.0:
			continue
		delta_by_tile[tile_id] = -drop
		if tile_index.has(tile_id) and tile_index.get(tile_id, {}) is Dictionary:
			var row = (tile_index.get(tile_id, {}) as Dictionary).duplicate(true)
			row["freeze_thaw_damage"] = _frost_buffer[i]
			tile_index[tile_id] = row
	var geomorph_result = _apply_batched_geomorph_delta(tick, environment_snapshot, water_snapshot, delta_by_tile)
	environment_snapshot = geomorph_result.get("environment", environment_snapshot)
	water_snapshot = geomorph_result.get("hydrology", water_snapshot)
	var changed_tiles: Array = geomorph_result.get("changed_tiles", [])
	return {
		"environment": environment_snapshot,
		"hydrology": water_snapshot,
		"erosion": current_snapshot(tick),
		"changed": not changed_tiles.is_empty(),
		"changed_tiles": changed_tiles.duplicate(true),
	}

func _apply_batched_geomorph_delta(tick: int, environment_snapshot: Dictionary, water_snapshot: Dictionary, delta_by_tile: Dictionary) -> Dictionary:
	_accumulate_geomorph_delta(delta_by_tile)
	if _pending_geomorph_delta_by_tile.is_empty():
		_last_changed_tiles = []
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	var elapsed = tick - _geomorph_last_apply_tick
	if _geomorph_last_apply_tick >= 0 and elapsed < _geomorph_apply_interval_ticks:
		_last_changed_tiles = []
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	var batch_delta = _pending_geomorph_delta_by_tile.duplicate(true)
	_pending_geomorph_delta_by_tile.clear()
	_geomorph_last_apply_tick = tick
	var geomorph_result = apply_geomorph_delta(environment_snapshot, water_snapshot, batch_delta)
	_last_changed_tiles = (geomorph_result.get("changed_tiles", []) as Array).duplicate(true)
	return geomorph_result

func _accumulate_geomorph_delta(delta_by_tile: Dictionary) -> void:
	if delta_by_tile.is_empty():
		return
	for tile_id_variant in delta_by_tile.keys():
		var tile_id = String(tile_id_variant)
		var delta = float(delta_by_tile.get(tile_id, 0.0))
		if absf(delta) <= 0.000001:
			continue
		var prev = float(_pending_geomorph_delta_by_tile.get(tile_id, 0.0))
		_pending_geomorph_delta_by_tile[tile_id] = prev + delta

func current_snapshot(tick: int) -> Dictionary:
	var rows: Array = []
	if _emit_rows:
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

func _activity_value(local_activity: Dictionary, tile_id: String) -> float:
	if not local_activity.has(tile_id):
		return 0.0
	return clampf(float(local_activity.get(tile_id, 0.0)), 0.0, 1.0)

func _cadence_for_activity(activity: float) -> int:
	var a = clampf(activity, 0.0, 1.0)
	return clampi(int(round(lerpf(float(_idle_cadence), 1.0, a))), 1, maxi(1, _idle_cadence))

func _should_step_tile(tile_id: String, tick: int, cadence: int) -> bool:
	if cadence <= 1:
		return true
	var phase = abs(int(hash("%s|%d" % [tile_id, _seed]))) % cadence
	return (tick + phase) % cadence == 0
