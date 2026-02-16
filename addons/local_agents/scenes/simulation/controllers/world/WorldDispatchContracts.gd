extends RefCounted
class_name WorldDispatchContracts

static func build_dispatch_payload(tick: int, delta: float, rate_tier: String, base_budget: float, view_metrics: Dictionary, dispatch_contact_rows: Array) -> Dictionary:
	return {
		"tick": tick,
		"delta": delta,
		"rate_tier": rate_tier,
		"compute_budget_scale": base_budget,
		"zoom_factor": clampf(float(view_metrics.get("zoom_factor", 0.0)), 0.0, 1.0),
		"camera_distance": maxf(0.0, float(view_metrics.get("camera_distance", 0.0))),
		"uniformity_score": clampf(float(view_metrics.get("uniformity_score", 0.0)), 0.0, 1.0),
		"physics_contacts": dispatch_contact_rows,
	}

static func ensure_pulses_with_contact_flush(pulses: Array, base_budget: float) -> Array:
	if not pulses.is_empty():
		return pulses
	return [{"tier_id": "contact_flush", "compute_budget_scale": base_budget, "forced_contact_flush": true}]

static func build_stage_payload(dispatch: Dictionary, backend_used: String, dispatch_reason: String, dispatch_contact_rows: Array, executed_op_count: int) -> Dictionary:
	var stage_payload: Dictionary = {}
	var voxel_payload = dispatch.get("voxel_result", {})
	if voxel_payload is Dictionary:
		stage_payload = (voxel_payload as Dictionary).duplicate(false)
	var raw_result = dispatch.get("result", {})
	if raw_result is Dictionary:
		stage_payload["result"] = (raw_result as Dictionary).duplicate(false)
	stage_payload["kernel_pass"] = String(dispatch.get("kernel_pass", ""))
	stage_payload["backend_used"] = backend_used
	stage_payload["dispatch_reason"] = dispatch_reason
	stage_payload["dispatched"] = bool(dispatch.get("dispatched", false))
	stage_payload["physics_contacts"] = dispatch_contact_rows
	stage_payload["native_ops"] = _flatten_native_ops(dispatch)
	stage_payload["changed_chunks"] = _normalize_changed_chunks(_extract_changed_chunks(dispatch))
	var changed_region := _extract_changed_region(dispatch)
	if not changed_region.is_empty():
		stage_payload["changed_region"] = changed_region
	stage_payload["_destruction_executed_op_count"] = executed_op_count
	return stage_payload

static func build_native_authoritative_mutation(dispatch: Dictionary, stage_payload: Dictionary, executed_op_count: int) -> Dictionary:
	var normalized_executed_op_count := maxi(0, executed_op_count)
	var changed_chunks_variant = stage_payload.get("changed_chunks", [])
	var changed_chunks: Array = changed_chunks_variant if changed_chunks_variant is Array else []
	var changed := normalized_executed_op_count > 0
	var mutation: Dictionary = {
		"ok": changed,
		"changed": changed,
		"error": "" if changed else _native_no_mutation_error(dispatch),
		"tick": int(stage_payload.get("tick", -1)),
		"changed_tiles": [],
		"changed_chunks": changed_chunks.duplicate(true),
		"mutation_path": "native_result_authoritative",
		"mutation_path_state": "success" if changed else "failure",
	}
	if not changed:
		mutation["failure_paths"] = [_native_no_mutation_error(dispatch)]
	return mutation

static func build_mutation_sync_state(simulation_controller: Node, tick: int, mutation: Dictionary) -> Dictionary:
	return {
		"tick": tick,
		"environment_snapshot": mutation.get("environment_snapshot", simulation_controller.current_environment_snapshot() if simulation_controller.has_method("current_environment_snapshot") else {}),
		"network_state_snapshot": mutation.get("network_state_snapshot", simulation_controller.current_network_state_snapshot() if simulation_controller.has_method("current_network_state_snapshot") else {}),
		"atmosphere_state_snapshot": simulation_controller.call("get_atmosphere_state_snapshot") if simulation_controller.has_method("get_atmosphere_state_snapshot") else {},
		"deformation_state_snapshot": simulation_controller.call("get_deformation_state_snapshot") if simulation_controller.has_method("get_deformation_state_snapshot") else {},
		"exposure_state_snapshot": simulation_controller.call("get_exposure_state_snapshot") if simulation_controller.has_method("get_exposure_state_snapshot") else {},
		"transform_changed": true,
		"transform_changed_tiles": (mutation.get("changed_tiles", []) as Array).duplicate(true),
		"transform_changed_chunks": (mutation.get("changed_chunks", []) as Array).duplicate(true),
	}

static func _native_no_mutation_error(dispatch: Dictionary) -> String:
	var dispatch_reason := String(dispatch.get("dispatch_reason", "")).strip_edges().to_lower()
	if dispatch_reason in ["gpu_required", "gpu_unavailable", "native_required", "native_unavailable"]:
		return dispatch_reason
	return "native_voxel_stage_no_mutation"

static func _flatten_native_ops(source: Dictionary) -> Array:
	var out: Array = []
	_collect_native_ops(source, out, 0)
	return out

static func _collect_native_ops(source: Dictionary, out: Array, depth: int) -> void:
	if depth > 3:
		return
	for key in ["native_ops", "op_payloads", "operations", "voxel_ops"]:
		var rows_variant = source.get(key, [])
		if not (rows_variant is Array):
			continue
		for row_variant in (rows_variant as Array):
			if row_variant is Dictionary:
				out.append((row_variant as Dictionary).duplicate(true))
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			_collect_native_ops(nested_variant as Dictionary, out, depth + 1)

static func _extract_changed_chunks(source: Dictionary) -> Array:
	var out: Array = []
	_collect_changed_chunks(source, out, 0)
	return out

static func _collect_changed_chunks(source: Dictionary, out: Array, depth: int) -> void:
	if depth > 3:
		return
	var rows_variant = source.get("changed_chunks", [])
	if rows_variant is Array:
		for row_variant in (rows_variant as Array):
			if row_variant is Dictionary:
				out.append((row_variant as Dictionary).duplicate(true))
			elif row_variant is String:
				var row_key := String(row_variant).strip_edges()
				if row_key != "":
					out.append(row_key)
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			_collect_changed_chunks(nested_variant as Dictionary, out, depth + 1)

static func _normalize_changed_chunks(rows: Array) -> Array:
	var seen: Dictionary = {}
	var normalized: Array = []
	for row_variant in rows:
		var chunk: Dictionary = {}
		if row_variant is Dictionary:
			var row = row_variant as Dictionary
			var chunk_x := int(row.get("x", 0))
			var chunk_y := int(row.get("y", 0))
			var chunk_z := int(row.get("z", row.get("y", 0)))
			chunk = {"x": chunk_x, "y": chunk_y, "z": chunk_z}
		else:
			var key := String(row_variant).strip_edges()
			if key == "":
				continue
			var parts := key.split(":")
			if parts.size() != 2:
				continue
			chunk = {"x": int(parts[0]), "y": 0, "z": int(parts[1])}
		var dedupe_key := "%d:%d:%d" % [int(chunk.get("x", 0)), int(chunk.get("y", 0)), int(chunk.get("z", 0))]
		if seen.has(dedupe_key):
			continue
		seen[dedupe_key] = true
		normalized.append(chunk)
	normalized.sort_custom(func(a, b):
		var left: Dictionary = a if a is Dictionary else {}
		var right: Dictionary = b if b is Dictionary else {}
		var lx := int(left.get("x", 0))
		var rx := int(right.get("x", 0))
		if lx != rx:
			return lx < rx
		var ly := int(left.get("y", 0))
		var ry := int(right.get("y", 0))
		if ly != ry:
			return ly < ry
		return int(left.get("z", 0)) < int(right.get("z", 0))
	)
	return normalized

static func _extract_changed_region(source: Dictionary) -> Dictionary:
	return _find_changed_region(source, 0)

static func _find_changed_region(source: Dictionary, depth: int) -> Dictionary:
	if depth > 3:
		return {}
	var region_variant = source.get("changed_region", {})
	if region_variant is Dictionary:
		var region = region_variant as Dictionary
		if bool(region.get("valid", false)):
			return region.duplicate(true)
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			var nested_region := _find_changed_region(nested_variant as Dictionary, depth + 1)
			if not nested_region.is_empty():
				return nested_region
	return {}
