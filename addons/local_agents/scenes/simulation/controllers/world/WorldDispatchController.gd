extends RefCounted
class_name LocalAgentsWorldDispatchController

const WorldNativeVoxelDispatchRuntimeScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")
const WorldDispatchContractsScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchContracts.gd")
const WorldDestructionOrchestratorScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDestructionOrchestrator.gd")

var _native_stage_name: StringName = &"voxel_transform_step"
var _destruction_orchestrator = WorldDestructionOrchestratorScript.new()

func configure(native_stage_name: StringName) -> void:
	_native_stage_name = native_stage_name if native_stage_name != StringName() else &"voxel_transform_step"

func process_native_voxel_rate(delta: float, projectile_contact_rows: Array, context: Dictionary) -> void:
	var tick := int(context.get("tick", 0))
	var frame_index := maxi(0, int(context.get("frame_index", Engine.get_process_frames())))
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

	var fps_launcher_controller_variant = context.get("fps_launcher_controller", null)
	var fps_launcher_controller: Node = fps_launcher_controller_variant if fps_launcher_controller_variant is Node else null
	var dispatch_contact_rows: Array = projectile_contact_rows
	if fps_launcher_controller != null and fps_launcher_controller.has_method("sample_voxel_dispatch_contact_rows"):
		var rows_variant = fps_launcher_controller.call("sample_voxel_dispatch_contact_rows")
		if rows_variant is Array:
			dispatch_contact_rows = rows_variant as Array
	var launcher_contract: Dictionary = {}
	if fps_launcher_controller != null and fps_launcher_controller.has_method("native_tick_contact_contract"):
		var launcher_contract_variant = fps_launcher_controller.call("native_tick_contact_contract")
		if launcher_contract_variant is Dictionary:
			launcher_contract = launcher_contract_variant as Dictionary

	WorldNativeVoxelDispatchRuntimeScript.record_hits_queued(native_voxel_dispatch_runtime, dispatch_contact_rows.size())
	var sync_environment_callable_variant = context.get("sync_environment_from_state", Callable())
	var sync_environment_callable: Callable = sync_environment_callable_variant if sync_environment_callable_variant is Callable else Callable()
	var tick_payload := WorldDispatchContractsScript.build_native_tick_payload(
		tick,
		delta,
		base_budget,
		view_metrics,
		dispatch_contact_rows,
		launcher_contract,
		{"frame_index": frame_index}
	)
	WorldNativeVoxelDispatchRuntimeScript.record_dispatch_attempt_after_fire(native_voxel_dispatch_runtime)
	var dispatch_start_usec := Time.get_ticks_usec()
	var dispatch_variant = simulation_controller.call("execute_native_voxel_stage", tick, _native_stage_name, tick_payload, false)
	var dispatch_duration_ms := float(maxi(0, Time.get_ticks_usec() - dispatch_start_usec)) / 1000.0
	var tick_tier_id := "native_consolidated_tick"
	if not (dispatch_variant is Dictionary):
		_record_native_voxel_dispatch_failure(native_voxel_dispatch_runtime, simulation_controller, tick, tick_tier_id, "", "invalid_dispatch_result", dispatch_duration_ms, false, {})
		return
	var dispatch = dispatch_variant as Dictionary
	var backend_used := _normalize_gpu_backend_used(dispatch)
	var dispatch_reason := String(dispatch.get("dispatch_reason", ""))
	var native_tick_contract_variant = dispatch.get("native_tick_contract", {})
	var native_tick_contract: Dictionary = native_tick_contract_variant if native_tick_contract_variant is Dictionary else {}
	if native_tick_contract.has("tier_id"):
		tick_tier_id = String(native_tick_contract.get("tier_id", tick_tier_id)).strip_edges()
		if tick_tier_id == "":
			tick_tier_id = "native_consolidated_tick"
	if not bool(dispatch.get("dispatched", false)):
		_fail_native_voxel_dependency(native_voxel_dispatch_runtime, simulation_controller, tick, "native voxel stage was not dispatched", tick_tier_id, dispatch_reason, dispatch_duration_ms, dispatch)
		return
	if backend_used.findn("gpu") == -1:
		_fail_native_voxel_dependency(native_voxel_dispatch_runtime, simulation_controller, tick, "native voxel stage backend is not GPU: %s" % backend_used, tick_tier_id, dispatch_reason, dispatch_duration_ms, dispatch)
		return
	_record_native_voxel_dispatch_success(native_voxel_dispatch_runtime, simulation_controller, tick, tick_tier_id, backend_used, dispatch_reason, dispatch_duration_ms, dispatch)
	var native_executed_op_count := WorldNativeVoxelDispatchRuntimeScript.record_destruction_plan(native_voxel_dispatch_runtime, dispatch)
	var stage_payload := WorldDispatchContractsScript.build_stage_payload(dispatch, backend_used, dispatch_reason, dispatch_contact_rows, native_executed_op_count)
	if stage_payload.is_empty():
		return
	var mutation := WorldDispatchContractsScript.build_native_authoritative_mutation(dispatch, stage_payload, native_executed_op_count)
	var mutation_applied := false
	var can_apply_stage_mutation := _has_native_mutation_state(simulation_controller) and _has_native_mutation_signal(dispatch, stage_payload)
	if can_apply_stage_mutation and _destruction_orchestrator != null:
		mutation_applied = _destruction_orchestrator.apply_stage_result(
			simulation_controller,
			native_voxel_dispatch_runtime,
			tick,
			stage_payload,
			sync_environment_callable
		)
	if not mutation_applied:
		WorldNativeVoxelDispatchRuntimeScript.record_mutation(native_voxel_dispatch_runtime, stage_payload, mutation, Engine.get_process_frames())
		if sync_environment_callable.is_valid():
			sync_environment_callable.call(WorldDispatchContractsScript.build_mutation_sync_state(simulation_controller, tick, mutation))
		native_tick_contract["mutation_applied"] = false
	else:
		native_tick_contract["mutation_applied"] = true
	var consumed_contacts := maxi(0, int(native_tick_contract.get("contacts_consumed", dispatch_contact_rows.size())))
	var mutation_applied_to_contact_contract := bool(native_tick_contract.get("mutation_applied", mutation_applied))
	if consumed_contacts > 0:
		WorldNativeVoxelDispatchRuntimeScript.record_contacts_dispatched(native_voxel_dispatch_runtime, consumed_contacts)
	if fps_launcher_controller != null and fps_launcher_controller.has_method("apply_native_tick_contract"):
		native_tick_contract["mutation_applied"] = mutation_applied_to_contact_contract
		fps_launcher_controller.call("apply_native_tick_contract", native_tick_contract)
	elif consumed_contacts > 0 and fps_launcher_controller != null and fps_launcher_controller.has_method("acknowledge_voxel_dispatch_contact_rows"):
		fps_launcher_controller.call("acknowledge_voxel_dispatch_contact_rows", consumed_contacts, mutation_applied_to_contact_contract)

func _has_native_mutation_signal(dispatch: Dictionary, stage_payload: Dictionary) -> bool:
	var payload_ops_variant = stage_payload.get("native_ops", [])
	if payload_ops_variant is Array and not (payload_ops_variant as Array).is_empty():
		return true
	if int(stage_payload.get("_destruction_executed_op_count", 0)) > 0:
		return true
	var changed_chunks_variant = stage_payload.get("changed_chunks", [])
	if changed_chunks_variant is Array and not (changed_chunks_variant as Array).is_empty():
		return true
	var authority_variant = dispatch.get("native_mutation_authority", {})
	if authority_variant is Dictionary:
		var authority := authority_variant as Dictionary
		if bool(authority.get("changed", false)):
			return true
		if int(authority.get("ops_changed", 0)) > 0:
			return true
		if authority.has("changed_chunks"):
			var changed_chunks := authority.get("changed_chunks", [])
			if changed_chunks is Array and not (changed_chunks as Array).is_empty():
				return true
			if changed_chunks is String:
				if String(changed_chunks).strip_edges() != "":
					return true
				if (changed_chunks as String).strip_edges() != "":
					return true
		if bool(authority.get("mutation_applied", false)):
			return true
	return false

func _has_native_mutation_state(simulation_controller: Object) -> bool:
	if simulation_controller == null:
		return false
	var has_environment_snapshot := false
	var has_network_state_snapshot := false
	var has_transform_changed_last_tick := false
	var has_transform_changed_tiles_last_tick := false
	for property in simulation_controller.get_property_list():
		var property_name := String(property.get("name", ""))
		match property_name:
			"_environment_snapshot":
				has_environment_snapshot = true
			"_network_state_snapshot":
				has_network_state_snapshot = true
			"_transform_changed_last_tick":
				has_transform_changed_last_tick = true
			"_transform_changed_tiles_last_tick":
				has_transform_changed_tiles_last_tick = true
	return has_environment_snapshot and has_network_state_snapshot and has_transform_changed_last_tick and has_transform_changed_tiles_last_tick

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

func _normalize_gpu_backend_used(dispatch: Dictionary) -> String:
	var backend_used := String(dispatch.get("backend_used", "")).strip_edges().to_lower()
	if backend_used == "":
		var voxel_result_variant = dispatch.get("voxel_result", {})
		if voxel_result_variant is Dictionary and bool((voxel_result_variant as Dictionary).get("gpu_dispatched", false)):
			backend_used = "gpu"
	if backend_used == "":
		var result_variant = dispatch.get("result", {})
		if result_variant is Dictionary:
			var execution_variant = (result_variant as Dictionary).get("execution", {})
			if execution_variant is Dictionary and bool((execution_variant as Dictionary).get("gpu_dispatched", false)):
				backend_used = "gpu"
	if backend_used == "" and bool(dispatch.get("dispatched", false)):
		backend_used = "gpu"
	if backend_used.findn("gpu") != -1:
		return "gpu"
	return backend_used
