extends RefCounted
class_name LocalAgentsWorldDispatchController

const WorldNativeVoxelDispatchRuntimeScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")
const WorldDispatchContractsScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchContracts.gd")

var _native_stage_name: StringName = &"voxel_transform_step"

func configure(native_stage_name: StringName) -> void:
	_native_stage_name = native_stage_name if native_stage_name != StringName() else &"voxel_transform_step"

func process_native_voxel_rate(delta: float, projectile_contact_rows: Array, context: Dictionary) -> void:
	var tick := int(context.get("tick", 0))
	var simulation_controller_variant = context.get("simulation_controller", null)
	var simulation_controller: Node = simulation_controller_variant if simulation_controller_variant is Node else null
	var native_voxel_dispatch_runtime_variant = context.get("native_voxel_dispatch_runtime", {})
	var native_voxel_dispatch_runtime: Dictionary = native_voxel_dispatch_runtime_variant if native_voxel_dispatch_runtime_variant is Dictionary else {}
	if simulation_controller == null or not simulation_controller.has_method("execute_native_voxel_stage"):
		_fail_native_voxel_dependency(native_voxel_dispatch_runtime, simulation_controller, tick, "native voxel dispatch unavailable: execute_native_voxel_stage missing", "missing_dispatch_method", "", 0.0)
		return

	var camera_controller = context.get("camera_controller", null)
	var view_metrics: Dictionary = {}
	if camera_controller != null and camera_controller.has_method("native_view_metrics"):
		view_metrics = camera_controller.call("native_view_metrics")
	var base_budget := clampf(float(view_metrics.get("compute_budget_scale", 1.0)), 0.05, 1.0)

	var voxel_rate_scheduler = context.get("voxel_rate_scheduler", null)
	var pulses: Array = []
	if voxel_rate_scheduler != null and voxel_rate_scheduler.has_method("advance"):
		var pulses_variant = voxel_rate_scheduler.call("advance", delta, base_budget)
		if pulses_variant is Array:
			pulses = pulses_variant as Array

	var fps_launcher_controller_variant = context.get("fps_launcher_controller", null)
	var fps_launcher_controller: Node = fps_launcher_controller_variant if fps_launcher_controller_variant is Node else null
	var dispatch_contact_rows: Array = projectile_contact_rows
	if fps_launcher_controller != null and fps_launcher_controller.has_method("sample_voxel_dispatch_contact_rows"):
		var rows_variant = fps_launcher_controller.call("sample_voxel_dispatch_contact_rows")
		if rows_variant is Array:
			dispatch_contact_rows = rows_variant as Array

	WorldNativeVoxelDispatchRuntimeScript.record_hits_queued(native_voxel_dispatch_runtime, dispatch_contact_rows.size())
	if pulses.is_empty() and dispatch_contact_rows.is_empty():
		return
	pulses = WorldDispatchContractsScript.ensure_pulses_with_contact_flush(pulses, base_budget)

	var attempted_dispatch := false
	var any_mutation_applied := false
	var graphics_target_wall_controller = context.get("graphics_target_wall_controller", null)
	var sync_environment_callable_variant = context.get("sync_environment_from_state", Callable())
	var sync_environment_callable: Callable = sync_environment_callable_variant if sync_environment_callable_variant is Callable else Callable()
	for pulse_variant in pulses:
		if not (pulse_variant is Dictionary):
			continue
		attempted_dispatch = true
		WorldNativeVoxelDispatchRuntimeScript.record_dispatch_attempt_after_fire(native_voxel_dispatch_runtime)
		var pulse = pulse_variant as Dictionary
		var tier_id := String(pulse.get("tier_id", "high"))
		var pulse_payload := WorldDispatchContractsScript.build_dispatch_payload(
			tick,
			delta,
			tier_id,
			float(pulse.get("compute_budget_scale", base_budget)),
			view_metrics,
			dispatch_contact_rows
		)
		var dispatch_start_usec := Time.get_ticks_usec()
		var dispatch_variant = simulation_controller.call("execute_native_voxel_stage", tick, _native_stage_name, pulse_payload, false)
		var dispatch_duration_ms := float(maxi(0, Time.get_ticks_usec() - dispatch_start_usec)) / 1000.0
		if not (dispatch_variant is Dictionary):
			_record_native_voxel_dispatch_failure(native_voxel_dispatch_runtime, simulation_controller, tick, tier_id, "", "invalid_dispatch_result", dispatch_duration_ms, false, {})
			continue
		var dispatch = dispatch_variant as Dictionary
		var backend_used := String(dispatch.get("backend_used", ""))
		if graphics_target_wall_controller != null and graphics_target_wall_controller.has_method("normalize_gpu_backend_used"):
			backend_used = String(graphics_target_wall_controller.call("normalize_gpu_backend_used", dispatch))
		var dispatch_reason := String(dispatch.get("dispatch_reason", ""))
		if not bool(dispatch.get("dispatched", false)):
			_fail_native_voxel_dependency(native_voxel_dispatch_runtime, simulation_controller, tick, "native voxel stage was not dispatched", tier_id, dispatch_reason, dispatch_duration_ms, dispatch)
			return
		if backend_used.findn("gpu") == -1:
			_fail_native_voxel_dependency(native_voxel_dispatch_runtime, simulation_controller, tick, "native voxel stage backend is not GPU: %s" % backend_used, tier_id, dispatch_reason, dispatch_duration_ms, dispatch)
			return
		_record_native_voxel_dispatch_success(native_voxel_dispatch_runtime, simulation_controller, tick, tier_id, backend_used, dispatch_reason, dispatch_duration_ms, dispatch)
		var native_executed_op_count := WorldNativeVoxelDispatchRuntimeScript.record_destruction_plan(native_voxel_dispatch_runtime, dispatch)
		var stage_payload := WorldDispatchContractsScript.build_stage_payload(dispatch, backend_used, dispatch_reason, dispatch_contact_rows, native_executed_op_count)
		if stage_payload.is_empty():
			continue
		var mutation := WorldDispatchContractsScript.build_native_authoritative_mutation(dispatch, stage_payload, native_executed_op_count)
		WorldNativeVoxelDispatchRuntimeScript.record_mutation(native_voxel_dispatch_runtime, stage_payload, mutation, Engine.get_process_frames())
		if not bool(mutation.get("changed", false)):
			continue
		any_mutation_applied = true
		if sync_environment_callable.is_valid():
			sync_environment_callable.call(WorldDispatchContractsScript.build_mutation_sync_state(simulation_controller, tick, mutation))
	if attempted_dispatch and any_mutation_applied and fps_launcher_controller != null and fps_launcher_controller.has_method("acknowledge_voxel_dispatch_contact_rows"):
		WorldNativeVoxelDispatchRuntimeScript.record_contacts_dispatched(native_voxel_dispatch_runtime, dispatch_contact_rows.size())
		fps_launcher_controller.call("acknowledge_voxel_dispatch_contact_rows", dispatch_contact_rows.size(), true)

func _record_native_voxel_dispatch_success(runtime: Dictionary, simulation_controller: Node, tick: int, tier_id: String, backend_used: String, dispatch_reason: String, duration_ms: float, dispatch: Dictionary = {}) -> void:
	WorldNativeVoxelDispatchRuntimeScript.record_success(
		runtime,
		simulation_controller,
		tick,
		tier_id,
		backend_used,
		dispatch_reason,
		duration_ms,
		dispatch
	)

func _record_native_voxel_dispatch_failure(runtime: Dictionary, simulation_controller: Node, tick: int, tier_id: String, backend_used: String, dispatch_reason: String, duration_ms: float, is_dependency_error: bool, dispatch: Dictionary = {}) -> void:
	WorldNativeVoxelDispatchRuntimeScript.record_failure(
		runtime,
		simulation_controller,
		tick,
		tier_id,
		backend_used,
		dispatch_reason,
		duration_ms,
		is_dependency_error,
		dispatch
	)

func _fail_native_voxel_dependency(runtime: Dictionary, simulation_controller: Node, tick: int, reason: String, tier_id: String, dispatch_reason: String, duration_ms: float, dispatch: Dictionary = {}) -> void:
	WorldNativeVoxelDispatchRuntimeScript.fail_dependency(
		runtime,
		simulation_controller,
		tick,
		reason,
		tier_id,
		dispatch_reason,
		duration_ms,
		dispatch
	)
