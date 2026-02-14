extends RefCounted
class_name LocalAgentsVoxelEditDispatch

const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")

static func dispatch_operations(enabled: bool, stage_name: StringName, payload: Dictionary = {}) -> Dictionary:
	if not enabled:
		return {}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_stage(stage_name, payload)
	if not bool(dispatch.get("ok", false)):
		return {
			"ok": false,
			"executed": bool(dispatch.get("executed", true)),
			"dispatched": false,
			"status": "failed",
			"error": String(dispatch.get("error", "voxel_stage_dispatch_failed")),
		}
	if not bool(dispatch.get("dispatched", false)):
		return {
			"ok": false,
			"executed": bool(dispatch.get("executed", true)),
			"dispatched": false,
			"status": "failed",
			"error": String(dispatch.get("error", "gpu_dispatch_not_confirmed")),
		}
	var stage_result = _extract_stage_result(dispatch.get("result", {}))
	if stage_result.is_empty():
		return {"ok": true, "executed": bool(dispatch.get("executed", true)), "dispatched": true, "status": "executed"}
	stage_result["ok"] = true
	stage_result["executed"] = bool(dispatch.get("executed", true))
	stage_result["dispatched"] = true
	if not stage_result.has("status"):
		stage_result["status"] = "executed"
	return stage_result

static func dispatch_environment_stage_payload(enabled: bool, tick: int, phase: String, stage_name: String, payload: Dictionary = {}) -> Dictionary:
	if not enabled:
		return {"ok": false, "executed": false, "dispatched": false, "status": "disabled", "error": "environment_stage_dispatch_disabled"}
	var dispatch = NativeComputeBridgeScript.dispatch_environment_stage_call(null, tick, phase, stage_name, payload, false)
	var stage_result = NativeComputeBridgeScript.environment_stage_result(dispatch)
	var dispatched = NativeComputeBridgeScript.is_environment_stage_dispatched(dispatch)
	if not bool(dispatch.get("ok", false)):
		var failed_payload: Dictionary = stage_result.duplicate(true)
		if failed_payload.is_empty():
			failed_payload = {"status": "failed"}
		failed_payload["ok"] = false
		failed_payload["executed"] = bool(dispatch.get("executed", true))
		failed_payload["dispatched"] = false
		failed_payload["error"] = String(dispatch.get("error", "environment_stage_dispatch_failed"))
		return failed_payload
	if not dispatched:
		var undispatched_payload: Dictionary = stage_result.duplicate(true)
		if undispatched_payload.is_empty():
			undispatched_payload = {"status": "undispatched"}
		undispatched_payload["ok"] = false
		undispatched_payload["executed"] = bool(dispatch.get("executed", true))
		undispatched_payload["dispatched"] = false
		undispatched_payload["error"] = String(dispatch.get("error", undispatched_payload.get("error", "environment_stage_dispatch_not_confirmed")))
		return undispatched_payload
	if stage_result.is_empty():
		return {
			"ok": true,
			"executed": bool(dispatch.get("executed", true)),
			"dispatched": true,
			"status": "executed",
		}
	var response: Dictionary = stage_result.duplicate(true)
	var status := String(response.get("status", "")).strip_edges().to_lower()
	var response_error := String(response.get("error", "")).strip_edges()
	var failed_statuses := ["failed", "error", "dropped", "drop", "noop", "no_op", "disabled", "undispatched"]
	var is_failed = status in failed_statuses or response_error != ""
	response["ok"] = not is_failed
	response["executed"] = bool(dispatch.get("executed", true))
	response["dispatched"] = not is_failed
	if is_failed and response_error == "":
		response["error"] = String(dispatch.get("error", "environment_stage_dispatch_failed"))
	if not response.has("status"):
		response["status"] = ("failed" if is_failed else "executed")
	return response

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
	if not bool(stage_result.get("ok", true)):
		return {
			"ok": false,
			"executed": bool(stage_result.get("executed", true)),
			"dispatched": false,
			"status": String(stage_result.get("status", "failed")),
			"error": String(stage_result.get("error", "voxel_stage_dispatch_failed")),
		}
	if stage_result.is_empty():
		return {}
	var env_variant = stage_result.get("environment", environment_snapshot)
	var hydro_variant = stage_result.get("hydrology", water_snapshot)
	if not (env_variant is Dictionary) or not (hydro_variant is Dictionary):
		return {}
	var changed_tiles = normalize_changed_tiles(stage_result.get("changed_tiles", []))
	return {
		"ok": true,
		"executed": bool(stage_result.get("executed", true)),
		"dispatched": true,
		"status": String(stage_result.get("status", "executed")),
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
