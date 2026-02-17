extends RefCounted
class_name WorldNativeVoxelDispatchMetrics

static func normalize_transform_stage_ms(stage_ms: Dictionary) -> Dictionary:
	return {
		"stage_a": float(stage_ms.get("stage_a", 0.0)),
		"stage_b": float(stage_ms.get("stage_b", 0.0)),
		"stage_c": float(stage_ms.get("stage_c", 0.0)),
		"stage_d": float(stage_ms.get("stage_d", 0.0)),
	}

static func extract_transform_stage_ms_current(dispatch: Dictionary, fallback_duration_ms: float) -> Dictionary:
	var per_stage := normalize_transform_stage_ms({})
	var stage_ms_sources: Array = []
	var root_per_stage_variant = dispatch.get("per_stage_ms", {})
	if root_per_stage_variant is Dictionary:
		stage_ms_sources.append(root_per_stage_variant as Dictionary)
	var root_stage_dispatch_variant = dispatch.get("stage_dispatch_ms", {})
	if root_stage_dispatch_variant is Dictionary:
		stage_ms_sources.append(root_stage_dispatch_variant as Dictionary)
	var result_variant = dispatch.get("result", {})
	if result_variant is Dictionary:
		var result_payload = result_variant as Dictionary
		var result_per_stage_variant = result_payload.get("per_stage_ms", {})
		if result_per_stage_variant is Dictionary:
			stage_ms_sources.append(result_per_stage_variant as Dictionary)
		var result_stage_dispatch_variant = result_payload.get("stage_dispatch_ms", {})
		if result_stage_dispatch_variant is Dictionary:
			stage_ms_sources.append(result_stage_dispatch_variant as Dictionary)
		var execution_variant = result_payload.get("execution", {})
		if execution_variant is Dictionary:
			var execution_payload = execution_variant as Dictionary
			var execution_per_stage_variant = execution_payload.get("per_stage_ms", {})
			if execution_per_stage_variant is Dictionary:
				stage_ms_sources.append(execution_per_stage_variant as Dictionary)
			var execution_stage_dispatch_variant = execution_payload.get("stage_dispatch_ms", {})
			if execution_stage_dispatch_variant is Dictionary:
				stage_ms_sources.append(execution_stage_dispatch_variant as Dictionary)
	var voxel_result_variant = dispatch.get("voxel_result", {})
	if voxel_result_variant is Dictionary:
		var voxel_payload = voxel_result_variant as Dictionary
		var voxel_per_stage_variant = voxel_payload.get("per_stage_ms", {})
		if voxel_per_stage_variant is Dictionary:
			stage_ms_sources.append(voxel_per_stage_variant as Dictionary)
		var voxel_stage_dispatch_variant = voxel_payload.get("stage_dispatch_ms", {})
		if voxel_stage_dispatch_variant is Dictionary:
			stage_ms_sources.append(voxel_stage_dispatch_variant as Dictionary)
	for source_variant in stage_ms_sources:
		if not (source_variant is Dictionary):
			continue
		var source = source_variant as Dictionary
		for key_variant in source.keys():
			var bucket = map_transform_dispatch_bucket(String(key_variant))
			if bucket == "":
				continue
			var raw_ms = source.get(key_variant, 0.0)
			var stage_ms := 0.0
			if raw_ms is float or raw_ms is int:
				stage_ms = maxf(0.0, float(raw_ms))
			elif raw_ms is Dictionary:
				var nested_ms = (raw_ms as Dictionary).get("ms", 0.0)
				stage_ms = maxf(0.0, float(nested_ms))
			per_stage[bucket] = float(per_stage.get(bucket, 0.0)) + stage_ms
	var kernel_pass_bucket = map_transform_dispatch_bucket(String(dispatch.get("kernel_pass", "")))
	if kernel_pass_bucket != "":
		per_stage[kernel_pass_bucket] = maxf(float(per_stage.get(kernel_pass_bucket, 0.0)), maxf(0.0, fallback_duration_ms))
	var dispatch_reason_bucket = map_transform_dispatch_bucket(String(dispatch.get("dispatch_reason", "")))
	if dispatch_reason_bucket != "" and kernel_pass_bucket == "":
		per_stage[dispatch_reason_bucket] = maxf(float(per_stage.get(dispatch_reason_bucket, 0.0)), maxf(0.0, fallback_duration_ms))
	return normalize_transform_stage_ms(per_stage)

static func map_transform_dispatch_bucket(raw_stage_token: String) -> String:
	var token := raw_stage_token.strip_edges().to_lower()
	if token == "":
		return ""
	if token == "stage_a" or token.contains("stage_a") or token.contains("atmosphere"):
		return "stage_a"
	if token == "stage_b" or token.contains("stage_b") or token.contains("network"):
		return "stage_b"
	if token == "stage_c" or token.contains("stage_c") or token.contains("deformation") or token.contains("voxel"):
		return "stage_c"
	if token == "stage_d" or token.contains("stage_d") or token.contains("exposure") or token.contains("solar"):
		return "stage_d"
	return ""

static func destruction_pipeline_snapshot_from_dispatch(dispatch: Dictionary) -> Dictionary:
	var plan_payload := _find_voxel_failure_emission(dispatch, 0)
	var planned_op_count := 0
	var executed_op_count := 0
	var reason := ""
	var status := ""
	if not plan_payload.is_empty():
		planned_op_count = int(plan_payload.get("planned_op_count", 0))
		if planned_op_count <= 0:
			var op_payloads_variant = plan_payload.get("op_payloads", [])
			if op_payloads_variant is Array:
				planned_op_count = (op_payloads_variant as Array).size()
		executed_op_count = int(plan_payload.get("executed_op_count", plan_payload.get("ops_changed", 0)))
		reason = String(plan_payload.get("reason", "")).strip_edges()
		status = String(plan_payload.get("status", "")).strip_edges().to_lower()
	var drop_reason := ""
	if not plan_payload.is_empty() and status in ["failed", "disabled", "dropped", "skipped"]:
		drop_reason = reason
	elif not bool(dispatch.get("dispatched", true)):
		drop_reason = String(dispatch.get("dispatch_reason", "")).strip_edges()
	return {
		"planned_op_count": maxi(0, planned_op_count),
		"executed_op_count": maxi(0, executed_op_count),
		"drop_reason": drop_reason,
	}

static func count_native_voxel_ops(payload: Dictionary) -> int:
	return _count_native_voxel_ops_recursive(payload, 0)

static func _find_voxel_failure_emission(source: Dictionary, depth: int) -> Dictionary:
	if source.is_empty() or depth > 6:
		return {}
	var direct_variant = source.get("voxel_failure_emission", {})
	if direct_variant is Dictionary and not (direct_variant as Dictionary).is_empty():
		return (direct_variant as Dictionary).duplicate(true)
	for key in ["result_fields", "result", "dispatch", "payload", "execution", "voxel_result"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			var nested_payload = _find_voxel_failure_emission(nested_variant as Dictionary, depth + 1)
			if not nested_payload.is_empty():
				return nested_payload
	return {}

static func _count_native_voxel_ops_recursive(source: Dictionary, depth: int) -> int:
	if source.is_empty() or depth > 8:
		return 0
	var total := 0
	for key in ["op_payloads", "operations", "voxel_ops"]:
		var items_variant = source.get(key, [])
		if items_variant is Array:
			total += (items_variant as Array).size()
	for key in ["voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			total += _count_native_voxel_ops_recursive(nested_variant as Dictionary, depth + 1)
	return total
