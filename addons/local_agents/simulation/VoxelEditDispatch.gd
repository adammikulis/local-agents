extends RefCounted
class_name LocalAgentsVoxelEditDispatch

const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")

static func dispatch_operations(enabled: bool, stage_name: StringName, payload: Dictionary = {}) -> Dictionary:
	if not enabled:
		return {}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_stage(stage_name, payload)
	if not bool(dispatch.get("dispatched", false)):
		return {}
	var stage_result = _extract_stage_result(dispatch.get("result", {}))
	if stage_result.is_empty():
		return {}
	stage_result["dispatched"] = true
	return stage_result

static func dispatch_environment_stage_payload(enabled: bool, tick: int, phase: String, stage_name: String, payload: Dictionary = {}) -> Dictionary:
	if not enabled:
		return {}
	var dispatch = NativeComputeBridgeScript.dispatch_environment_stage_call(null, tick, phase, stage_name, payload, false)
	if not NativeComputeBridgeScript.is_environment_stage_dispatched(dispatch):
		return {}
	return NativeComputeBridgeScript.environment_stage_result(dispatch)

static func dispatch_geomorph_delta_ops(enabled: bool, stage_name: StringName, tick: int, environment_snapshot: Dictionary, water_snapshot: Dictionary, delta_by_tile: Dictionary, column_overrides: Dictionary = {}) -> Dictionary:
	var operations: Array = []
	for tile_id_variant in delta_by_tile.keys():
		var tile_id = String(tile_id_variant)
		var delta = float(delta_by_tile.get(tile_id, 0.0))
		if absf(delta) <= 0.000001:
			continue
		operations.append({"type": "terrain_delta", "tile_id": tile_id, "delta_elevation": delta, "column_override": column_overrides.get(tile_id, {})})
	if operations.is_empty():
		return {}
	var stage_result = dispatch_operations(enabled, stage_name, {"tick": tick, "environment": environment_snapshot.duplicate(true), "hydrology": water_snapshot.duplicate(true), "operations": operations})
	if stage_result.is_empty():
		return {}
	var env_variant = stage_result.get("environment", environment_snapshot)
	var hydro_variant = stage_result.get("hydrology", water_snapshot)
	if not (env_variant is Dictionary) or not (hydro_variant is Dictionary):
		return {}
	var changed_tiles = normalize_changed_tiles(stage_result.get("changed_tiles", []))
	return {
		"environment": env_variant as Dictionary,
		"hydrology": hydro_variant as Dictionary,
		"voxel_changed": bool(stage_result.get("voxel_changed", stage_result.get("changed", not changed_tiles.is_empty()))),
		"changed_tiles": changed_tiles,
	}

static func normalize_changed_tiles(value) -> Array:
	if not (value is Array):
		return []
	var changed_tiles: Array = (value as Array).duplicate(true)
	changed_tiles.sort_custom(func(a, b): return String(a) < String(b))
	return changed_tiles

static func _extract_stage_result(raw_result) -> Dictionary:
	if not (raw_result is Dictionary):
		return {}
	var root = raw_result as Dictionary
	var result_fields = root.get("result_fields", {})
	if result_fields is Dictionary:
		return result_fields as Dictionary
	var nested_result = root.get("result", {})
	if nested_result is Dictionary:
		var nested = nested_result as Dictionary
		var nested_fields = nested.get("result_fields", {})
		if nested_fields is Dictionary:
			return nested_fields as Dictionary
		return nested
	var step_result = root.get("step_result", {})
	if step_result is Dictionary:
		return step_result as Dictionary
	var payload = root.get("payload", {})
	if payload is Dictionary:
		return payload as Dictionary
	return root
