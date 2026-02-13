@tool
extends RefCounted

const NATIVE_CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const VOXEL_EDIT_ENGINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp"
const NATIVE_BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_voxel_op_ordering_contract_source() and ok
	ok = _test_fallback_path_selection_contract_source() and ok
	ok = _test_changed_region_payload_shape_contract_source() and ok
	ok = _test_adaptive_multires_and_zoom_throttle_contract_source() and ok
	if ok:
		print("Native voxel op source contracts passed (ordering, fallback selection, changed-region payload shape).")
	return ok

func _test_voxel_op_ordering_contract_source() -> bool:
	var source := _read_script_source(NATIVE_CORE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary LocalAgentsSimulationCore::execute_voxel_stage"), "Native core must define execute_voxel_stage") and ok
	ok = _assert(source.contains("Dictionary LocalAgentsSimulationCore::apply_voxel_stage"), "Native core must define apply_voxel_stage dispatcher") and ok
	ok = _assert(source.contains("voxel_stage_dispatch_count_ += 1;"), "Voxel op ordering requires global domain dispatch counter increment") and ok
	ok = _assert(source.contains("const int64_t stage_dispatch_count = increment_stage_counter(voxel_stage_counters_, stage_name);"), "Voxel op ordering requires per-stage dispatch counter increment") and ok
	ok = _assert(source.contains("result[\"counters\"] = build_stage_dispatch_counters(voxel_stage_dispatch_count_, stage_dispatch_count);"), "Native core must include ordering counters in voxel stage result") and ok

	var engine_source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if engine_source == "":
		return false
	ok = _assert(engine_source.contains("parsed_op.sequence_id = next_sequence_id_;"), "Voxel edit queue must assign monotonic sequence IDs") and ok
	ok = _assert(engine_source.contains("next_sequence_id_ += 1;"), "Voxel edit queue must advance sequence IDs per enqueue") and ok
	ok = _assert(engine_source.contains("std::sort("), "Voxel edit execution must sort queued ops for deterministic ordering") and ok
	ok = _assert(engine_source.contains("lhs.sequence_id < rhs.sequence_id"), "Voxel edit execution must order by sequence_id") and ok
	ok = _assert(engine_source.contains("if (String(stage_name).is_empty()) {\n        return make_error_result(stage_domain, stage_name, payload, String(\"invalid_stage_name\"));\n    }"), "Voxel op contract must reject blank stage names with invalid_stage_name") and ok
	return ok

func _test_fallback_path_selection_contract_source() -> bool:
	var engine_source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if engine_source == "":
		return false
	var bridge_source := _read_script_source(NATIVE_BRIDGE_GD_PATH)
	if bridge_source == "":
		return false

	var ok := true
	ok = _assert(engine_source.contains("execution[\"backend_requested\"] = String(\"gpu\");"), "Voxel op fallback contract must declare gpu as requested backend") and ok
	ok = _assert(engine_source.contains("execution[\"gpu_attempted\"] = true;"), "Voxel op fallback contract must report gpu attempt") and ok
	ok = _assert(engine_source.contains("execution[\"gpu_dispatched\"] = false;"), "Voxel op fallback contract must report undispatched gpu path when unavailable") and ok
	ok = _assert(engine_source.contains("execution[\"gpu_status\"] = String(\"not_available\");"), "Voxel op fallback contract must report gpu_status=not_available") and ok
	ok = _assert(engine_source.contains("execution[\"backend_used\"] = String(\"cpu_fallback\");"), "Voxel op fallback contract must report cpu_fallback backend_used") and ok
	ok = _assert(engine_source.contains("execution[\"cpu_fallback_used\"] = true;"), "Voxel op fallback contract must report cpu_fallback_used=true") and ok

	ok = _assert(bridge_source.contains("var execution_variant = payload_result.get(\"execution\", {})"), "Native bridge must read execution payload for fallback dispatch state") and ok
	ok = _assert(bridge_source.contains("dispatched = bool((execution_variant as Dictionary).get(\"dispatched\", false))"), "Native bridge must map execution.dispatched into dispatch result") and ok
	ok = _assert(bridge_source.contains("\"dispatched\": dispatched"), "Native bridge must expose dispatched fallback state") and ok
	return ok

func _test_changed_region_payload_shape_contract_source() -> bool:
	var source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("identity[\"payload\"] = payload.duplicate(true);"), "Native voxel op response must deep-copy payload so changed-region input shape is preserved") and ok
	ok = _assert(source.contains("result[\"changed_region\"] = cpu_stats.changed_region.duplicate(true);"), "Native voxel op response must expose changed_region payload") and ok
	ok = _assert(source.contains("changed_region[\"valid\"] = has_region;"), "changed_region payload must include valid flag") and ok
	ok = _assert(source.contains("changed_region[\"min\"] = build_point_dict"), "changed_region payload must include min point dictionary") and ok
	ok = _assert(source.contains("changed_region[\"max\"] = build_point_dict"), "changed_region payload must include max point dictionary") and ok
	ok = _assert(source.contains("stats.changed_chunks = changed_chunks_array;"), "Native voxel op response must expose changed chunk array payload") and ok
	ok = _assert(source.contains("changed_chunks_array.append(build_point_dict(chunk.x, chunk.y, chunk.z));"), "Changed chunk rows must use x/y/z point dictionaries") and ok
	return ok

func _test_adaptive_multires_and_zoom_throttle_contract_source() -> bool:
	var source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("execution[\"voxel_scale\"] = runtime_policy.voxel_scale;"), "Execution metadata must expose voxel_scale for adaptive multires") and ok
	ok = _assert(source.contains("execution[\"op_stride\"] = runtime_policy.op_stride;"), "Execution metadata must expose op_stride for zoom-throttled compute") and ok
	ok = _assert(source.contains("const int32_t qx = floor_div(op.voxel.x, voxel_scale) * voxel_scale;"), "CPU fallback must quantize coordinates for larger adaptive voxel cells") and ok
	ok = _assert(source.contains("if (payload.has(\"camera_distance\"))"), "Runtime policy should support camera-distance based zoom factor") and ok
	ok = _assert(source.contains("if (payload.has(\"uniformity_score\"))"), "Runtime policy should support uniform-region coarsening via uniformity_score") and ok
	ok = _assert(source.contains("if (payload.has(\"compute_budget_scale\"))"), "Runtime policy should support explicit compute_budget_scale throttling") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _read_script_source(script_path: String) -> String:
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % script_path)
		return ""
	return file.get_as_text()
