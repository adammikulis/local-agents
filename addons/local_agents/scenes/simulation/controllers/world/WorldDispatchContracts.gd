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
	stage_payload["_destruction_executed_op_count"] = executed_op_count
	return stage_payload

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
