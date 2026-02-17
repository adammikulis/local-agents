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

class MockFpsLauncher extends Node:
	var pending_rows: Array = []
	var native_tick_contract: Dictionary = {}
	var apply_contract_calls: Array = []
	var contract_ack_calls: Array = []
	var fallback_ack_calls: Array = []

	func sample_voxel_dispatch_contact_rows() -> Array:
		return pending_rows.duplicate(true)

	func native_tick_contact_contract() -> Dictionary:
		return native_tick_contract.duplicate(true)

	func apply_native_tick_contract(contract: Dictionary) -> void:
		apply_contract_calls.append(contract.duplicate(true))
		var consumed := maxi(0, int(contract.get("contacts_consumed", 0)))
		var remove_count := mini(consumed, pending_rows.size())
		if remove_count <= 0:
			return
		pending_rows = pending_rows.slice(remove_count, pending_rows.size())
		contract_ack_calls.append({
			"count": remove_count,
			"source": "native_tick_contract",
		})

	func acknowledge_voxel_dispatch_contact_rows(count: int, mutated: bool) -> void:
		fallback_ack_calls.append({"count": count, "mutated": mutated})

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
	ok = _run_native_tick_contract_ack_authority_test() and ok
	return ok

func _run_native_dispatch_success_contract_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var scheduler := MockScheduler.new()
	var fps_launcher := MockFpsLauncher.new()
	var camera_controller := MockCameraController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	var synced_states: Array = []

	fps_launcher.pending_rows = [
		{
			"body_id": 998,
			"projectile_kind": "voxel_chunk",
			"contact_impulse": 12.0,
			"relative_speed": 21.0,
			"contact_point": Vector3(10.0, 4.0, 10.0),
		}
	]
	fps_launcher.native_tick_contract = {
		"pending_contacts": 1,
		"earliest_deadline_frame": 144,
	}
	simulation_controller.dispatch_responses.append(simulation_controller._success_dispatch(1))

	var context := {
		"tick": 91,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"voxel_rate_scheduler": scheduler,
		"fps_launcher_controller": fps_launcher,
		"camera_controller": camera_controller,
		"sync_environment_from_state": func(state: Dictionary) -> void:
			synced_states.append(state.duplicate(true)),
	}

	controller.process_native_voxel_rate(0.05, [], context)

	var ok := true
	ok = _assert(simulation_controller.calls.size() == 1, "Native orchestration should dispatch exactly one forced contact-flush pulse when contact rows are queued.") and ok
	if simulation_controller.calls.size() == 1 and simulation_controller.calls[0] is Dictionary:
		var call := simulation_controller.calls[0] as Dictionary
		var payload_variant = call.get("payload", {})
		var payload: Dictionary = payload_variant if payload_variant is Dictionary else {}
		var contacts_variant = payload.get("physics_contacts", [])
		var contacts: Array = contacts_variant if contacts_variant is Array else []
		ok = _assert(int(call.get("tick", -1)) == 91, "Native orchestration dispatch call should preserve tick from orchestration context.") and ok
		ok = _assert(String(call.get("stage_name", "")) == "voxel_transform_step", "Native orchestration dispatch should target canonical voxel_transform_step stage.") and ok
		ok = _assert(int(payload.get("tick", -1)) == 91, "Dispatch payload should carry orchestration tick for native stage contracts.") and ok
		ok = _assert(String(payload.get("rate_tier", "")) == "native_consolidated_tick", "Dispatch payload should use the native consolidated tick rate tier for consolidated dispatch.") and ok
		ok = _assert(_is_approx(float(payload.get("compute_budget_scale", 0.0)), 0.6), "Dispatch payload should preserve compute_budget_scale from native view metrics.") and ok
		ok = _assert(contacts.size() == 1, "Dispatch payload should pass projectile contact rows through to native stage.") and ok
		var orchestration_variant = payload.get("native_tick_orchestration", {})
		var orchestration: Dictionary = orchestration_variant if orchestration_variant is Dictionary else {}
		var launcher_contract_variant = orchestration.get("launcher_contract", {})
		var launcher_contract: Dictionary = launcher_contract_variant if launcher_contract_variant is Dictionary else {}
		ok = _assert(int(launcher_contract.get("pending_contacts", 0)) == 1, "Dispatch payload should forward launcher native_tick_contact_contract pending_contacts unchanged.") and ok
		ok = _assert(int(launcher_contract.get("earliest_deadline_frame", -1)) == 144, "Dispatch payload should forward launcher native_tick_contact_contract deadline metadata unchanged.") and ok
		if contacts.size() == 1 and contacts[0] is Dictionary:
			var row := contacts[0] as Dictionary
			ok = _assert(int(row.get("body_id", 0)) == 998, "Dispatch payload should preserve contact origin body_id for native telemetry.") and ok

	ok = _assert(fps_launcher.apply_contract_calls.size() == 1, "Runtime path should apply native_tick_contract exactly once per successful dispatch pulse.") and ok
	ok = _assert(fps_launcher.fallback_ack_calls.is_empty(), "Runtime path should not use fallback acknowledge path when apply_native_tick_contract exists.") and ok
	ok = _assert(fps_launcher.contract_ack_calls.size() == 1, "Native tick contract contacts_consumed should drive projectile contact ack outcomes.") and ok
	if fps_launcher.contract_ack_calls.size() == 1 and fps_launcher.contract_ack_calls[0] is Dictionary:
		var ack := fps_launcher.contract_ack_calls[0] as Dictionary
		ok = _assert(int(ack.get("count", 0)) == 1, "Contact acknowledgment count should match dispatched queued-contact row count.") and ok

	ok = _assert(int(runtime.get("pulses_total", 0)) == 1 and int(runtime.get("pulses_success", 0)) == 1, "Runtime telemetry should track successful native dispatch pulse counters.") and ok
	ok = _assert(int(runtime.get("hits_queued", 0)) == 1 and int(runtime.get("contacts_dispatched", 0)) == 1, "Runtime telemetry should preserve queued/dispatched contact counters.") and ok
	ok = _assert(int(runtime.get("ops_applied", 0)) > 0, "Runtime telemetry should increment ops_applied when native mutation executes.") and ok
	var timings_variant = runtime.get("pulse_timings", [])
	var timings: Array = timings_variant if timings_variant is Array else []
	ok = _assert(timings.size() == 1, "Runtime telemetry should append one pulse timing sample for single dispatch pulse.") and ok
	if timings.size() == 1 and timings[0] is Dictionary:
		var timing := timings[0] as Dictionary
		ok = _assert(String(timing.get("backend_used", "")).to_lower().begins_with("gpu"), "Telemetry contract should report GPU backend usage.") and ok
		ok = _assert(String(timing.get("dispatch_reason", "")) == "native_gpu_primary", "Telemetry contract should pass through native dispatch_reason origin unchanged.") and ok
	ok = _assert(int(simulation_controller.metrics_payload.get("pulse_count", 0)) == 1, "Runtime telemetry push should sync pulse_count into simulation controller metrics contract.") and ok
	ok = _assert(synced_states.size() == 1, "Successful native mutation should emit exactly one sync_environment_from_state payload.") and ok
	simulation_controller.free()
	fps_launcher.free()
	return ok

func _run_native_tick_contract_ack_authority_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var scheduler := MockScheduler.new()
	var fps_launcher := MockFpsLauncher.new()
	var camera_controller := MockCameraController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	fps_launcher.pending_rows = [
		{
			"body_id": 1001,
			"projectile_kind": "voxel_chunk",
			"contact_impulse": 10.0,
			"relative_speed": 15.0,
			"contact_point": Vector3(3.0, 2.0, 3.0),
		}
	]
	fps_launcher.native_tick_contract = {
		"pending_contacts": 1,
		"earliest_deadline_frame": 55,
	}
	simulation_controller.dispatch_responses.append(simulation_controller._success_dispatch(0))
	var context := {
		"tick": 44,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"voxel_rate_scheduler": scheduler,
		"fps_launcher_controller": fps_launcher,
		"camera_controller": camera_controller,
	}
	controller.process_native_voxel_rate(0.05, [], context)
	var ok := true
	ok = _assert(fps_launcher.apply_contract_calls.size() == 1, "Runtime path should always apply native_tick_contract when provided by dispatch response.") and ok
	ok = _assert(fps_launcher.contract_ack_calls.is_empty(), "contacts_consumed=0 should keep queued rows pending until native contract confirms consumption.") and ok
	ok = _assert(fps_launcher.fallback_ack_calls.is_empty(), "Fallback acknowledge path should stay unused when native_tick_contract API exists.") and ok
	ok = _assert(fps_launcher.pending_rows.size() == 1, "Pending rows should remain queued when native contract reports contacts_consumed=0.") and ok
	ok = _assert(int(runtime.get("contacts_dispatched", 0)) == 0, "Runtime telemetry contacts_dispatched should follow native tick contract consumed count, not queued row size.") and ok
	simulation_controller.free()
	fps_launcher.free()
	return ok

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-5) -> bool:
	return absf(lhs - rhs) <= epsilon

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
