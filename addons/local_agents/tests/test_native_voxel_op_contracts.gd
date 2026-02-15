@tool
extends RefCounted

const NATIVE_CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const VOXEL_EDIT_ENGINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp"
const VOXEL_GPU_EXECUTOR_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/VoxelEditGpuExecutor.cpp"
const VOXEL_GPU_DISPATCH_METADATA_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/VoxelGpuDispatchMetadata.cpp"
const NATIVE_BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_voxel_op_ordering_contract_source() and ok
	ok = _test_fallback_path_selection_contract_source() and ok
	ok = _test_gpu_dispatch_success_contract_source() and ok
	ok = _test_environment_stage_dispatch_and_result_extraction_contract_source() and ok
	ok = _test_changed_region_payload_shape_contract_source() and ok
	ok = _test_adaptive_multires_and_zoom_throttle_contract_source() and ok
	ok = _test_variable_rate_deterministic_processing_contract_source() and ok
	ok = _test_environment_stage_field_handle_injection_contract_source() and ok
	if ok:
		print("Native voxel op source contracts passed (ordering, fallback selection, changed-region payload shape).")
	return ok

func _test_environment_stage_field_handle_injection_contract_source() -> bool:
	var source := _read_script_source(NATIVE_CORE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("bool extract_reference_from_dictionary(const Dictionary &payload, String &out_ref)"), "Core must define dictionary-based field reference extractor for handle injection") and ok
	ok = _assert(source.contains("Array collect_input_field_handles("), "Core must define field-handle collection helper for environment inputs") and ok
	ok = _assert(source.contains("const Dictionary resolved = registry->resolve_field_handle(token);"), "Handle injection should resolve registered handles before creating new ones") and ok
	ok = _assert(source.contains("const Dictionary created = registry->create_field_handle(token);"), "Handle injection should create handles when resolving by field name") and ok
	ok = _assert(source.contains("const Dictionary source_inputs = environment_payload.get(\"inputs\", Dictionary());"), "Handle injection must read payload.inputs before pipeline dispatch") and ok
	ok = _assert(source.contains("const Dictionary scheduled_frame_inputs = maybe_inject_field_handles_into_environment_inputs(effective_payload, field_registry_.get());"), "Environment stage must inject computed field_handles before compute execution") and ok
	ok = _assert(source.contains("scheduled_frame[\"inputs\"] = scheduled_frame_inputs;"), "Environment stage should dispatch injected inputs into scheduled_frame") and ok
	ok = _assert(source.contains("if (!did_inject_handles) {"), "Field handle injection should preserve scalar path by skipping injection if no valid references are found") and ok
	ok = _assert(source.contains("pipeline_inputs[\"field_handles\"] = field_handles;"), "Injected field_handles should be added to a duplicated pipeline input dictionary") and ok
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
	ok = _assert(engine_source.contains("execution[\"backend_used\"] = String(\"none\");"), "Voxel op fallback contract must not claim cpu_fallback backend usage") and ok
	ok = _assert(engine_source.contains("execution[\"cpu_fallback_used\"] = false;"), "Voxel op fallback contract must report cpu_fallback_used=false") and ok
	ok = _assert(engine_source.contains("execution[\"error_code\"] = String(\"gpu_required\");"), "Voxel op fallback contract must expose canonical gpu_required error_code") and ok
	ok = _assert(engine_source.contains("result[\"error\"] = String(\"gpu_required\");"), "Voxel op fallback contract must fail fast with canonical gpu_required code") and ok

	ok = _assert(bridge_source.contains("var backend_used := String(execution.get(\"backend_used\", \"\")).strip_edges().to_lower()"), "Native bridge must read execution.backend_used for strict backend validation") and ok
	ok = _assert(bridge_source.contains("var gpu_dispatched := bool(execution.get(\"gpu_dispatched\", dispatched))"), "Native bridge must read execution.gpu_dispatched for strict GPU dispatch validation") and ok
	ok = _assert(bridge_source.contains("if cpu_fallback_used or backend_used == \"cpu_fallback\":"), "Native bridge must reject cpu_fallback backend usage") and ok
	ok = _assert(bridge_source.contains("if backend_requested == \"gpu\" and not gpu_dispatched:"), "Native bridge must fail fast when gpu backend is requested but not dispatched") and ok
	ok = _assert(bridge_source.contains("var unavailable_error := _canonicalize_voxel_error(base_error, \"gpu_unavailable\")"), "Native bridge must canonicalize missing GPU dispatch errors to gpu_unavailable") and ok
	ok = _assert(bridge_source.contains("static func _canonicalize_voxel_error(raw_error: String, fallback_code: String) -> String:"), "Native bridge must include canonical voxel error taxonomy mapping helper") and ok
	return ok

func _test_gpu_dispatch_success_contract_source() -> bool:
	var engine_source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if engine_source == "":
		return false
	var executor_source := _read_script_source(VOXEL_GPU_EXECUTOR_CPP_PATH)
	if executor_source == "":
		return false
	var metadata_source := _read_script_source(VOXEL_GPU_DISPATCH_METADATA_CPP_PATH)
	if metadata_source == "":
		return false
	var ok := true
	ok = _assert(engine_source.contains("if (!gpu_backend_enabled_) {"), "Voxel engine must keep an explicit GPU availability gate for fail-fast behavior") and ok
	ok = _assert(engine_source.contains("const VoxelGpuExecutionResult gpu_result = VoxelEditGpuExecutor::execute("), "Voxel engine success path must dispatch through VoxelEditGpuExecutor") and ok
	ok = _assert(not engine_source.contains("const StageExecutionStats cpu_stats = execute_cpu_stage("), "Voxel engine success path must not execute CPU stage") and ok
	ok = _assert(executor_source.contains("result.deferred_ops = pending_ops;"), "GPU executor failure path must requeue ordered pending ops to avoid loss") and ok
	ok = _assert(engine_source.contains("const Dictionary execution = build_voxel_gpu_dispatch_metadata(dispatch_metadata);"), "Voxel engine must build dispatched GPU execution metadata through native helper") and ok
	ok = _assert(engine_source.contains("result[\"dispatched\"] = true;"), "Voxel engine must flag dispatched=true on GPU success path") and ok
	ok = _assert(engine_source.contains("result[\"ok\"] = true;"), "Voxel engine must report ok=true when GPU dispatch succeeds") and ok
	ok = _assert(metadata_source.contains("execution[\"readback\"] = readback;"), "GPU success metadata must expose deterministic readback payload") and ok
	ok = _assert(metadata_source.contains("readback[\"deterministic_signature\"] = signature;"), "GPU readback payload must include deterministic_signature") and ok
	return ok

func _test_environment_stage_dispatch_and_result_extraction_contract_source() -> bool:
	var bridge_source := _read_script_source(NATIVE_BRIDGE_GD_PATH)
	if bridge_source == "":
		return false
	var ok := true
	ok = _assert(bridge_source.contains("var result_fields: Dictionary = {}"), "Environment-stage normalization must initialize result_fields extraction payload.") and ok
	ok = _assert(bridge_source.contains("if payload.get(\"result_fields\", {}) is Dictionary:"), "Environment-stage normalization must read top-level result_fields when available.") and ok
	ok = _assert(bridge_source.contains("elif payload.get(\"result\", {}) is Dictionary:"), "Environment-stage normalization must fall back to result dictionary payloads.") and ok
	ok = _assert(bridge_source.contains("if result_fields.get(\"result_fields\", {}) is Dictionary:"), "Environment-stage normalization must unwrap nested result.result_fields payloads.") and ok
	ok = _assert(bridge_source.contains("elif payload.get(\"step_result\", {}) is Dictionary:"), "Environment-stage normalization must accept step_result payloads.") and ok
	ok = _assert(bridge_source.contains("elif payload.get(\"payload\", {}) is Dictionary:"), "Environment-stage normalization must accept payload fallback dictionaries.") and ok
	ok = _assert(
		bridge_source.contains("return {\"ok\": bool(payload.get(\"ok\", true)), \"executed\": true, \"dispatched\": dispatched, \"result\": payload, \"result_fields\": result_fields, \"error\": String(payload.get(\"error\", \"\"))}"),
		"Environment-stage normalization must expose ok/executed/dispatched/status-ready result_fields contract."
	) and ok
	ok = _assert(bridge_source.contains("if status in [\"executed\", \"dispatched\", \"completed\", \"noop\", \"no_op\", \"dropped\", \"drop\"]:"), "Environment-stage dispatch status contract must treat terminal status values as dispatched.") and ok
	ok = _assert(bridge_source.contains("var payload = environment_stage_result(dispatch)"), "Environment-stage dispatch checks must derive payload through environment_stage_result path.") and ok
	ok = _assert(bridge_source.contains("if not payload.is_empty():"), "Environment-stage dispatch checks must accept non-empty payloads even without explicit dispatched=true.") and ok
	ok = _assert(bridge_source.contains("var status_payload := {\"status\": status}"), "Environment-stage result extraction must expose status payload when only status metadata is present.") and ok
	return ok

func _test_changed_region_payload_shape_contract_source() -> bool:
	var source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("identity[\"payload\"] = payload.duplicate(true);"), "Native voxel op response must deep-copy payload so changed-region input shape is preserved") and ok
	ok = _assert(source.contains("result[\"changed_region\"] = gpu_stats.changed_region.duplicate(true);"), "Native voxel op response must expose changed_region payload") and ok
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

func _test_variable_rate_deterministic_processing_contract_source() -> bool:
	var source := _read_script_source(VOXEL_EDIT_ENGINE_CPP_PATH)
	if source == "":
		return false
	var executor_source := _read_script_source(VOXEL_GPU_EXECUTOR_CPP_PATH)
	if executor_source == "":
		return false
	var ok := true
	ok = _assert(source.contains("std::sort("), "Variable-rate processing must sort queued ops before execution") and ok
	ok = _assert(source.contains("lhs.sequence_id < rhs.sequence_id"), "Variable-rate processing must preserve deterministic sequence_id tier ordering") and ok
	ok = _assert(executor_source.contains("if (op_stride > 1) {"), "Variable-rate processing must gate execution when op_stride > 1") and ok
	ok = _assert(
		executor_source.contains("static_cast<int32_t>((op.sequence_id + static_cast<uint64_t>(stride_phase)) % static_cast<uint64_t>(op_stride)) != 0"),
		"Variable-rate processing must select deterministic op tiers via sequence_id + stride_phase modulo op_stride."
	) and ok
	ok = _assert(source.contains("runtime_policy.stride_phase = static_cast<int32_t>("), "Variable-rate processing must derive runtime stride_phase for fairness across steps.") and ok
	ok = _assert(source.contains("buffer.execute_total % static_cast<int64_t>(std::max(1, runtime_policy.op_stride))"), "Variable-rate processing must advance stride_phase from execute_total modulo op_stride.") and ok
	ok = _assert(source.contains("execution[\"stride_phase\"] = runtime_policy.stride_phase;"), "Result execution metadata must expose stride_phase.") and ok
	ok = _assert(executor_source.contains("stats.ops_scanned = static_cast<int64_t>(ops.size());"), "Variable-rate processing must record scanned-op count.") and ok
	ok = _assert(executor_source.contains("stats.ops_processed = static_cast<int64_t>(dispatch_ops.size());"), "Variable-rate processing must record processed-op count.") and ok
	ok = _assert(executor_source.contains("stats.ops_requeued += 1;"), "Variable-rate processing must record requeued-op count.") and ok
	ok = _assert(source.contains("buffer.pending_ops = gpu_result.deferred_ops;"), "Variable-rate processing must requeue deferred ops for deterministic replay continuity.") and ok
	ok = _assert(source.contains("result[\"ops_scanned\"] = gpu_stats.ops_scanned;"), "Result contract must expose ops_scanned for stride fairness verification.") and ok
	ok = _assert(source.contains("result[\"ops_processed\"] = gpu_stats.ops_processed;"), "Result contract must expose ops_processed for variable-rate verification.") and ok
	ok = _assert(source.contains("result[\"ops_requeued\"] = gpu_stats.ops_requeued;"), "Result contract must expose ops_requeued for stride fairness verification.") and ok
	ok = _assert(source.contains("result[\"queue_pending_before\"] = pending_before;"), "Result contract must expose queue_pending_before for fairness accounting.") and ok
	ok = _assert(source.contains("result[\"queue_pending_after\"] = static_cast<int64_t>(buffer.pending_ops.size());"), "Result contract must expose queue_pending_after for fairness accounting.") and ok
	ok = _assert(source.contains("buffer.requeued_total += gpu_stats.ops_requeued;"), "Stage-level fairness accounting must accumulate requeued totals.") and ok
	ok = _assert(source.contains("result[\"ops_changed\"] = gpu_stats.ops_changed;"), "Result contract must expose ops_changed for variable-rate verification.") and ok
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
