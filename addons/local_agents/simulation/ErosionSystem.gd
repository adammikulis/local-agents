extends RefCounted
class_name LocalAgentsErosionSystem
const ErosionComputeBackendScript = preload("res://addons/local_agents/simulation/ErosionComputeBackend.gd")
const ErosionVoxelWorldHelpersScript = preload("res://addons/local_agents/simulation/erosion/ErosionVoxelWorldHelpers.gd")
const CadencePolicyScript = preload("res://addons/local_agents/simulation/CadencePolicy.gd")
const VoxelEditDispatchScript = preload("res://addons/local_agents/simulation/VoxelEditDispatch.gd")
const MaterialFlowNativeStageHelpersScript = preload("res://addons/local_agents/simulation/material_flow/MaterialFlowNativeStageHelpers.gd")
const _NATIVE_STAGE_NAME := "erosion_step"
const _NATIVE_VOXEL_EDIT_STAGE_NAME := &"erosion_geomorph_ops"
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
var _native_environment_stage_dispatch_enabled: bool = false
var _native_view_metrics: Dictionary = {}
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
	var tick = int(options.get("tick", -1))
	var changed_ids: Dictionary = _normalize_erosion_delta(delta_by_tile)
	if changed_ids.is_empty():
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
		}
	if _native_environment_stage_dispatch_enabled:
		var native_result = VoxelEditDispatchScript.dispatch_geomorph_delta_ops(
			true,
			_NATIVE_VOXEL_EDIT_STAGE_NAME,
			tick,
			environment_snapshot,
			water_snapshot,
			changed_ids,
			options.get("column_overrides", {})
		)
		if not native_result.is_empty():
			return native_result
		return {
			"environment": environment_snapshot,
			"hydrology": water_snapshot,
			"voxel_changed": false,
			"changed_tiles": [],
			"status": "error",
			"error": "native_geomorph_stage_dispatch_failed",
			"details": "native geomorph stage dispatch returned no result",
		}
	var cpu_changed = ErosionVoxelWorldHelpersScript.apply_voxel_surface_erosion(environment_snapshot, changed_ids)
	var changed_tiles: Array = []
	if cpu_changed:
		for tile_id_variant in changed_ids.keys():
			changed_tiles.append(String(tile_id_variant))
		changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
		_refresh_erosion_tile_rows(environment_snapshot, changed_tiles)
	return {
		"environment": environment_snapshot,
		"hydrology": water_snapshot,
		"voxel_changed": bool(cpu_changed),
		"changed_tiles": changed_tiles,
	}

static func _normalize_erosion_delta(delta_by_tile: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	for key_variant in delta_by_tile.keys():
		var tile_id := String(key_variant)
		var value = float(delta_by_tile.get(key_variant, 0.0))
		var drop = absf(value)
		if drop <= 0.0:
			continue
		normalized[tile_id] = drop
	return normalized

func _refresh_erosion_tile_rows(environment_snapshot: Dictionary, changed_tiles: Array) -> void:
	if changed_tiles.is_empty():
		return
	var tile_index: Dictionary = environment_snapshot.get("tile_index", {})
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	if tile_index.is_empty():
		return
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		column_by_tile = ErosionVoxelWorldHelpersScript.build_column_index(columns)
	for tile_id_variant in changed_tiles:
		var tile_id := String(tile_id_variant)
		if not tile_index.has(tile_id):
			continue
		var row_index = column_by_tile.get(tile_id, -1)
		if row_index is String or row_index is float:
			row_index = int(row_index)
		if typeof(row_index) != TYPE_INT and typeof(row_index) != TYPE_FLOAT:
			continue
		var i = int(row_index)
		if i < 0 or i >= columns.size():
			continue
		var column_variant = columns[i]
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var tile_row = tile_index.get(tile_id, {})
		if tile_row is Dictionary:
			(tile_row as Dictionary)["surface_y"] = int(column.get("surface_y", 1))
			tile_index[tile_id] = tile_row as Dictionary
	ErosionVoxelWorldHelpersScript.update_tiles_array(environment_snapshot, tile_index)
func set_compute_enabled(enabled: bool) -> void:
	if enabled == _compute_requested:
		if not enabled or _compute_active:
			return
	_compute_requested = enabled
	if not enabled:
		_compute_backend.release()
		_compute_active = false
		return
	if not _configured:
		return
	_compute_active = _compute_backend.configure(_slope_buffer, _temp_base_buffer, _activity_buffer, _erosion_buffer, _frost_buffer, _temp_prev_buffer)
func is_compute_active() -> bool:
	return _compute_active
func set_native_environment_stage_dispatch_enabled(enabled: bool) -> void:
	_native_environment_stage_dispatch_enabled = enabled

func set_native_view_metrics(metrics: Dictionary) -> void:
	_native_view_metrics = MaterialFlowNativeStageHelpersScript.sanitize_native_view_metrics(metrics)
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
	var native_step = _step_native_environment_stage(tick, delta, environment_snapshot, water_snapshot, weather_snapshot, local_activity)
	if not native_step.is_empty():
		return native_step
	if _native_environment_stage_dispatch_enabled:
		return _fail_fast_step(
			environment_snapshot,
			water_snapshot,
			tick,
			"native_erosion_stage_dispatch_unavailable",
			"native erosion stage dispatch unavailable or failed"
		)
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
	if _compute_requested:
		return _step_cpu(
			tick,
			delta,
			environment_snapshot,
			water_snapshot,
			weather_snapshot,
			environment_snapshot.get("tile_index", {}),
			weather_snapshot.get("tile_index", {}),
			water_snapshot.get("water_tiles", {}),
			local_activity
		)
	return _fail_fast_step(
		environment_snapshot,
		water_snapshot,
		tick,
		"erosion_gpu_unavailable",
		"erosion GPU compute unavailable or weather buffers invalid"
	)
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
		var cadence = CadencePolicyScript.cadence_for_activity(activity, _idle_cadence)
		if cadence > 1 and not CadencePolicyScript.should_step_with_key(tile_id, tick, cadence, _seed):
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
	if String(geomorph_result.get("status", "")) == "error":
		return _fail_fast_step(
			environment_snapshot,
			water_snapshot,
			tick,
			String(geomorph_result.get("error", "native_geomorph_stage_dispatch_unavailable")),
			String(geomorph_result.get("details", "native geomorph stage dispatch unavailable or returned no result"))
		)
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
	var previous_activity := _activity_buffer.duplicate()
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
		_activity_buffer = previous_activity
		_compute_active = false
		return _fail_fast_step(
			environment_snapshot,
			water_snapshot,
			tick,
			"erosion_gpu_step_failed",
			"erosion GPU step returned empty result"
		)
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
	if String(geomorph_result.get("status", "")) == "error":
		return _fail_fast_step(
			environment_snapshot,
			water_snapshot,
			tick,
			String(geomorph_result.get("error", "native_geomorph_stage_dispatch_unavailable")),
			String(geomorph_result.get("details", "native geomorph stage dispatch unavailable or returned no result"))
		)
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

func _fail_fast_step(
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	tick: int,
	error_code: String,
	details: String = ""
) -> Dictionary:
	return {
		"environment": environment_snapshot,
		"hydrology": water_snapshot,
		"erosion": current_snapshot(tick),
		"changed": false,
		"changed_tiles": [],
		"status": "error",
		"error": error_code,
		"details": details,
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
	var geomorph_result = apply_geomorph_delta(environment_snapshot, water_snapshot, batch_delta, {"tick": tick})
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
func _step_native_environment_stage(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	water_snapshot: Dictionary,
	weather_snapshot: Dictionary,
	local_activity: Dictionary
) -> Dictionary:
	var physics_contacts: Array = []
	var physics_contacts_variant = local_activity.get("physics_contacts", null)
	if physics_contacts_variant is Array:
		physics_contacts = (physics_contacts_variant as Array).duplicate(true)
	var native_payload = MaterialFlowNativeStageHelpersScript.build_environment_stage_payload(
		tick,
		delta,
		environment_snapshot,
		water_snapshot,
		weather_snapshot,
		local_activity,
		_native_view_metrics,
		physics_contacts
	)
	var native_result = VoxelEditDispatchScript.dispatch_environment_stage_payload(_native_environment_stage_dispatch_enabled, tick, "erosion", _NATIVE_STAGE_NAME, native_payload)
	if native_result.is_empty():
		return {}
	var native_environment := native_result.get("environment", environment_snapshot)
	var native_hydrology := native_result.get("hydrology", water_snapshot)
	var native_erosion := native_result.get("erosion", current_snapshot(tick))
	if not (native_environment is Dictionary) or not (native_hydrology is Dictionary) or not (native_erosion is Dictionary):
		return {}
	var changed_tiles_variant = native_result.get("changed_tiles", [])
	if not (changed_tiles_variant is Array):
		changed_tiles_variant = []
	var normalized_changed_tiles: Array = (changed_tiles_variant as Array).duplicate(true)
	normalized_changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
	import_snapshot(native_erosion as Dictionary)
	_last_changed_tiles = normalized_changed_tiles.duplicate(true)
	return {
		"environment": native_environment as Dictionary,
		"hydrology": native_hydrology as Dictionary,
		"erosion": native_erosion as Dictionary,
		"changed": bool(native_result.get("changed", not normalized_changed_tiles.is_empty())),
		"changed_tiles": normalized_changed_tiles,
	}
