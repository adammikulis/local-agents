extends RefCounted
class_name WorldNativeVoxelDispatchRuntime

const WorldNativeVoxelDispatchMetricsScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchMetrics.gd")

static func record_success(runtime: Dictionary, simulation_controller, tick: int, tier_id: String, backend_used: String, dispatch_reason: String, duration_ms: float, dispatch: Dictionary = {}) -> void:
	runtime["pulses_total"] = int(runtime.get("pulses_total", 0)) + 1
	runtime["pulses_success"] = int(runtime.get("pulses_success", 0)) + 1
	runtime["last_backend"] = backend_used
	runtime["last_dispatch_reason"] = dispatch_reason
	_record_pulse(runtime, simulation_controller, tick, tier_id, backend_used, dispatch_reason, duration_ms, true, dispatch)

static func record_failure(runtime: Dictionary, simulation_controller, tick: int, tier_id: String, backend_used: String, dispatch_reason: String, duration_ms: float, is_dependency_error: bool, dispatch: Dictionary = {}) -> void:
	runtime["pulses_total"] = int(runtime.get("pulses_total", 0)) + 1
	runtime["pulses_failed"] = int(runtime.get("pulses_failed", 0)) + 1
	runtime["last_backend"] = backend_used
	runtime["last_dispatch_reason"] = dispatch_reason
	if is_dependency_error:
		runtime["dependency_errors"] = int(runtime.get("dependency_errors", 0)) + 1
	_record_pulse(runtime, simulation_controller, tick, tier_id, backend_used, dispatch_reason, duration_ms, false, dispatch)

static func fail_dependency(runtime: Dictionary, simulation_controller, tick: int, reason: String, tier_id: String, dispatch_reason: String, duration_ms: float, dispatch: Dictionary = {}) -> void:
	runtime["last_error"] = reason
	runtime["last_error_tick"] = tick
	record_failure(runtime, simulation_controller, tick, tier_id, "", dispatch_reason, duration_ms, true, dispatch)
	push_error("GPU_REQUIRED: %s" % reason)

static func record_hits_queued(runtime: Dictionary, hits_count: int) -> void:
	var count := maxi(0, hits_count)
	if count <= 0:
		return
	runtime["hits_queued"] = int(runtime.get("hits_queued", 0)) + count

static func record_contacts_dispatched(runtime: Dictionary, contacts_count: int) -> void:
	var count := maxi(0, contacts_count)
	if count <= 0:
		return
	runtime["contacts_dispatched"] = int(runtime.get("contacts_dispatched", 0)) + count

static func set_fps_mode_active(runtime: Dictionary, active: bool) -> void:
	runtime["fps_mode_active"] = active

static func record_fire_attempt(runtime: Dictionary) -> void:
	runtime["fire_attempts"] = int(runtime.get("fire_attempts", 0)) + 1

static func record_fire_result(runtime: Dictionary, fired: bool, frame_index: int) -> void:
	if not fired:
		return
	runtime["fire_successes"] = int(runtime.get("fire_successes", 0)) + 1
	runtime["dispatch_attempts_after_fire"] = 0
	runtime["first_mutation_frames_since_fire"] = -1
	runtime["_last_successful_fire_frame"] = maxi(0, frame_index)

static func record_dispatch_attempt_after_fire(runtime: Dictionary) -> void:
	if int(runtime.get("_last_successful_fire_frame", -1)) < 0:
		return
	if int(runtime.get("first_mutation_frames_since_fire", -1)) >= 0:
		return
	runtime["dispatch_attempts_after_fire"] = int(runtime.get("dispatch_attempts_after_fire", 0)) + 1

static func record_destruction_plan(runtime: Dictionary, dispatch: Dictionary) -> int:
	var snapshot := WorldNativeVoxelDispatchMetricsScript.destruction_pipeline_snapshot_from_dispatch(dispatch)
	var planned_op_count := maxi(0, int(snapshot.get("planned_op_count", 0)))
	if planned_op_count > 0:
		runtime["plans_planned"] = int(runtime.get("plans_planned", 0)) + planned_op_count
	var drop_reason := String(snapshot.get("drop_reason", "")).strip_edges()
	if drop_reason != "":
		runtime["last_drop_reason"] = drop_reason
	return maxi(0, int(snapshot.get("executed_op_count", 0)))

static func record_mutation(runtime: Dictionary, stage_payload: Dictionary, mutation: Dictionary, frame_index: int = -1) -> void:
	var executed_op_count := maxi(0, int(stage_payload.get("_destruction_executed_op_count", 0)))
	if executed_op_count <= 0:
		executed_op_count = WorldNativeVoxelDispatchMetricsScript.count_native_voxel_ops(stage_payload)
	runtime["ops_applied"] = int(runtime.get("ops_applied", 0)) + maxi(0, executed_op_count)
	var mutation_changed_tiles_variant = mutation.get("changed_tiles", [])
	if mutation_changed_tiles_variant is Array:
		runtime["changed_tiles"] = int(runtime.get("changed_tiles", 0)) + (mutation_changed_tiles_variant as Array).size()
	if not bool(mutation.get("changed", false)):
		var mutation_error := String(mutation.get("error", "")).strip_edges()
		if mutation_error != "":
			runtime["last_drop_reason"] = mutation_error
		return
	if int(runtime.get("_last_successful_fire_frame", -1)) < 0:
		return
	if int(runtime.get("first_mutation_frames_since_fire", -1)) >= 0:
		return
	var resolved_frame := frame_index
	if resolved_frame < 0:
		resolved_frame = Engine.get_process_frames()
	runtime["first_mutation_frames_since_fire"] = maxi(0, resolved_frame - int(runtime.get("_last_successful_fire_frame", resolved_frame)))

static func _record_pulse(runtime: Dictionary, simulation_controller, tick: int, tier_id: String, backend_used: String, dispatch_reason: String, duration_ms: float, success: bool, dispatch: Dictionary = {}) -> void:
	var timing_variant = runtime.get("pulse_timings", [])
	var pulse_timings: Array = timing_variant if timing_variant is Array else []
	pulse_timings.append({
		"tick": tick,
		"tier_id": tier_id,
		"duration_ms": duration_ms,
		"backend_used": backend_used,
		"dispatch_reason": dispatch_reason,
		"success": success,
	})
	while pulse_timings.size() > 64:
		pulse_timings.remove_at(0)
	runtime["pulse_timings"] = pulse_timings
	var per_stage_ms_current := WorldNativeVoxelDispatchMetricsScript.extract_transform_stage_ms_current(dispatch, duration_ms)
	runtime["per_stage_ms_current"] = per_stage_ms_current
	var aggregate_variant = runtime.get("per_stage_ms_aggregate", {})
	var per_stage_ms_aggregate := WorldNativeVoxelDispatchMetricsScript.normalize_transform_stage_ms(aggregate_variant if aggregate_variant is Dictionary else {})
	per_stage_ms_aggregate["stage_a"] = float(per_stage_ms_aggregate.get("stage_a", 0.0)) + float(per_stage_ms_current.get("stage_a", 0.0))
	per_stage_ms_aggregate["stage_b"] = float(per_stage_ms_aggregate.get("stage_b", 0.0)) + float(per_stage_ms_current.get("stage_b", 0.0))
	per_stage_ms_aggregate["stage_c"] = float(per_stage_ms_aggregate.get("stage_c", 0.0)) + float(per_stage_ms_current.get("stage_c", 0.0))
	per_stage_ms_aggregate["stage_d"] = float(per_stage_ms_aggregate.get("stage_d", 0.0)) + float(per_stage_ms_current.get("stage_d", 0.0))
	runtime["per_stage_ms_aggregate"] = per_stage_ms_aggregate
	push_transform_dispatch_metrics(runtime, simulation_controller)

static func push_transform_dispatch_metrics(runtime: Dictionary, simulation_controller) -> void:
	if simulation_controller == null or not simulation_controller.has_method("set_transform_dispatch_metrics"):
		return
	var per_stage_current_variant = runtime.get("per_stage_ms_current", {})
	var per_stage_aggregate_variant = runtime.get("per_stage_ms_aggregate", {})
	simulation_controller.set_transform_dispatch_metrics({
		"pulse_count": int(runtime.get("pulses_total", 0)),
		"gpu_dispatch_success_count": int(runtime.get("pulses_success", 0)),
		"gpu_dispatch_failure_count": int(runtime.get("pulses_failed", 0)),
		"per_stage_ms_current": WorldNativeVoxelDispatchMetricsScript.normalize_transform_stage_ms(per_stage_current_variant if per_stage_current_variant is Dictionary else {}),
		"per_stage_ms_aggregate": WorldNativeVoxelDispatchMetricsScript.normalize_transform_stage_ms(per_stage_aggregate_variant if per_stage_aggregate_variant is Dictionary else {}),
	})
