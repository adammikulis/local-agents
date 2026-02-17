@tool
extends RefCounted

const WorldDispatchControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd")
const WorldNativeVoxelDispatchRuntimeScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")

class MockSimulationController extends Node:
	var calls: Array = []
	var metrics_payload: Dictionary = {}
	var dispatch_responses: Array = []

	func execute_native_voxel_stage(tick: int, stage_name: StringName, payload: Dictionary, _strict: bool) -> Dictionary:
		calls.append({
			"tick": tick,
			"stage_name": String(stage_name),
			"payload": payload.duplicate(true),
		})
		if not dispatch_responses.is_empty():
			var response_variant = dispatch_responses.pop_front()
			if response_variant is Dictionary:
				return (response_variant as Dictionary).duplicate(true)
		return _success_dispatch(1)

	func _success_dispatch(contacts_consumed: int) -> Dictionary:
		return {
			"ok": true,
			"dispatched": true,
			"backend_used": "gpu_compute",
			"dispatch_reason": "native_gpu_primary",
			"kernel_pass": "voxel_transform_stage_c",
			"native_tick_contract": {
				"contacts_consumed": maxi(0, contacts_consumed),
				"deadline_error": "",
			},
			"execution": {
				"ops_changed": 1,
				"changed": true,
				"changed_chunks": [{"x": 1, "y": 0, "z": 1}],
				"changed_region": {
					"valid": true,
					"min": {"x": 10, "y": 4, "z": 10},
					"max": {"x": 10, "y": 4, "z": 10},
				},
				"per_stage_ms": {"stage_c": 0.28},
			},
			"result": {
				"ops_changed": 1,
				"changed": true,
				"changed_chunks": [{"x": 1, "y": 0, "z": 1}],
				"changed_region": {
					"valid": true,
					"min": {"x": 10, "y": 4, "z": 10},
					"max": {"x": 10, "y": 4, "z": 10},
				},
			},
		}

	func set_transform_dispatch_metrics(metrics: Dictionary) -> void:
		metrics_payload = metrics.duplicate(true)

class MockScheduler extends RefCounted:
	var advance_calls: Array = []

	func advance(delta: float, base_budget: float) -> Array:
		advance_calls.append({"delta": delta, "base_budget": base_budget})
		return []

class MockCameraController extends RefCounted:
	func native_view_metrics() -> Dictionary:
		return {
			"zoom_factor": 0.25,
			"camera_distance": 9.5,
			"uniformity_score": 0.4,
			"compute_budget_scale": 0.6,
		}

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _run_native_dispatch_success_contract_test() and ok
	ok = _run_contacts_dispatched_uses_native_contract_value_test() and ok
	return ok

func _run_native_dispatch_success_contract_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var scheduler := MockScheduler.new()
	var camera_controller := MockCameraController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	var synced_states: Array = []

	simulation_controller.dispatch_responses.append(simulation_controller._success_dispatch(1))
	var context := {
		"tick": 91,
		"frame_index": 287,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"projectile_contact_rows": [{
			"body_id": 11,
			"contact_point": Vector3(1.0, 2.0, 3.0),
			"contact_impulse": 8.0,
			"relative_speed": 14.0,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_voxel",
			"failure_emission_profile": "dense_hard_voxel_chunk",
			"projectile_radius": 0.07,
			"body_mass": 0.2,
			"deadline_frame": 293,
		}],
		"fracture_contact_rows": [],
		"debris_contact_rows": [],
		"voxel_rate_scheduler": scheduler,
		"camera_controller": camera_controller,
		"sync_environment_from_state": func(state: Dictionary) -> void:
			synced_states.append(state.duplicate(true)),
	}

	var result: Dictionary = controller.process_native_voxel_rate(0.05, context)

	var ok := true
	ok = _assert(simulation_controller.calls.size() == 1, "Native orchestration should dispatch exactly one pulse per process invocation.") and ok
	if simulation_controller.calls.size() == 1 and simulation_controller.calls[0] is Dictionary:
		var call := simulation_controller.calls[0] as Dictionary
		var payload_variant = call.get("payload", {})
		var payload: Dictionary = payload_variant if payload_variant is Dictionary else {}
		var contacts_variant = payload.get("physics_contacts", [])
		var contacts: Array = contacts_variant if contacts_variant is Array else []
		ok = _assert(int(call.get("tick", -1)) == 91, "Native orchestration dispatch should use simulation tick without launcher-owned queue shims.") and ok
		ok = _assert(String(call.get("stage_name", "")) == "voxel_transform_step", "Native orchestration dispatch should target canonical voxel_transform_step stage.") and ok
		ok = _assert(int(payload.get("tick", -1)) == 91, "Dispatch payload tick should match simulation tick.") and ok
		ok = _assert(int(payload.get("simulation_tick", -1)) == 91, "Dispatch payload should expose simulation tick metadata for telemetry contracts.") and ok
		ok = _assert(String(payload.get("rate_tier", "")) == "native_consolidated_tick", "Dispatch payload should use the native consolidated tick rate tier.") and ok
		ok = _assert(_is_approx(float(payload.get("compute_budget_scale", 0.0)), 0.6), "Dispatch payload should preserve compute_budget_scale from native view metrics.") and ok
		ok = _assert(contacts.size() == 1, "Dispatch payload should use launcher projectile contact rows when rigid-body debris reporter rows are disabled.") and ok
		var projectile_row: Dictionary = contacts[0] if contacts[0] is Dictionary else {}
		ok = _assert(String(projectile_row.get("projectile_kind", "")) == "voxel_chunk", "Projectile dispatch row should include projectile_kind metadata for native failure emission.") and ok
		ok = _assert(String(projectile_row.get("projectile_density_tag", "")) == "dense", "Projectile dispatch row should include projectile_density_tag metadata for native failure emission.") and ok
		ok = _assert(String(projectile_row.get("projectile_hardness_tag", "")) == "hard", "Projectile dispatch row should include projectile_hardness_tag metadata for native failure emission.") and ok
		ok = _assert(String(projectile_row.get("projectile_material_tag", "")) == "dense_voxel", "Projectile dispatch row should include projectile_material_tag metadata for native failure emission.") and ok
		ok = _assert(String(projectile_row.get("failure_emission_profile", "")) == "dense_hard_voxel_chunk", "Projectile dispatch row should include failure_emission_profile metadata for native failure emission.") and ok
		ok = _assert(_is_approx(float(projectile_row.get("projectile_radius", 0.0)), 0.07), "Projectile dispatch row should include projectile_radius metadata for native failure emission.") and ok
		ok = _assert(_is_approx(float(projectile_row.get("body_mass", 0.0)), 0.2), "Projectile dispatch row should include body_mass metadata for native failure emission.") and ok
		ok = _assert(int(projectile_row.get("deadline_frame", -1)) == 293, "Projectile dispatch row should carry deadline_frame metadata for native queue/deadline contracts.") and ok
		var orchestration_variant = payload.get("native_tick_orchestration", {})
		var orchestration: Dictionary = orchestration_variant if orchestration_variant is Dictionary else {}
		var contract_variant = orchestration.get("orchestration_contract", {})
		var contract: Dictionary = contract_variant if contract_variant is Dictionary else {}
		ok = _assert(int(contract.get("pending_contacts", 0)) == 1, "Dispatch payload should expose pending_contacts from launcher projectile rows only.") and ok

	ok = _assert(int(runtime.get("pulses_total", 0)) == 1 and int(runtime.get("pulses_success", 0)) == 1, "Runtime telemetry should track successful native dispatch pulse counters.") and ok
	ok = _assert(not bool(result.get("ok", true)), "Contact-driven dispatch without native mutation evidence must fail closed and never report success.") and ok
	ok = _assert(not bool(result.get("mutation_applied", true)), "Contact-only dispatch payloads without native mutation evidence must not report mutation_applied=true.") and ok
	ok = _assert(int(runtime.get("contacts_dispatched", 0)) == 0, "Runtime telemetry contacts_dispatched must remain 0 when native mutation is not applied.") and ok
	ok = _assert(int(runtime.get("ops_applied", 0)) > 0, "Runtime telemetry should keep native executed-op accounting even when mutation fails closed.") and ok
	var timings_variant = runtime.get("pulse_timings", [])
	var timings: Array = timings_variant if timings_variant is Array else []
	ok = _assert(timings.size() == 1, "Runtime telemetry should append one pulse timing sample for single dispatch pulse.") and ok
	if timings.size() == 1 and timings[0] is Dictionary:
		var timing := timings[0] as Dictionary
		ok = _assert(String(timing.get("backend_used", "")).to_lower().begins_with("gpu"), "Telemetry contract should report GPU backend usage.") and ok
		ok = _assert(String(timing.get("dispatch_reason", "")) == "native_gpu_primary", "Telemetry contract should pass through native dispatch_reason origin unchanged.") and ok
	ok = _assert(int(simulation_controller.metrics_payload.get("pulse_count", 0)) == 1, "Runtime telemetry push should sync pulse_count into simulation controller metrics contract.") and ok
	ok = _assert(synced_states.size() == 0, "No sync_environment_from_state payload should be emitted when native mutation is not applied.") and ok
	simulation_controller.free()
	return ok

func _run_contacts_dispatched_uses_native_contract_value_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var scheduler := MockScheduler.new()
	var camera_controller := MockCameraController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	simulation_controller.dispatch_responses.append(simulation_controller._success_dispatch(0))
	var context := {
		"tick": 44,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"voxel_rate_scheduler": scheduler,
		"camera_controller": camera_controller,
	}
	controller.process_native_voxel_rate(0.05, context)
	var ok := true
	ok = _assert(int(runtime.get("contacts_dispatched", 0)) == 0, "Runtime telemetry contacts_dispatched should remain unchanged when native contacts_consumed=0.") and ok
	simulation_controller.free()
	return ok

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-5) -> bool:
	return absf(lhs - rhs) <= epsilon

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
