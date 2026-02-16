@tool
extends RefCounted

const WorldDispatchControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd")
const WorldNativeVoxelDispatchRuntimeScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")

class MockSimulationController extends Node:
	var calls: Array = []
	var metrics_payload: Dictionary = {}

	func execute_native_voxel_stage(tick: int, stage_name: StringName, payload: Dictionary, _strict: bool) -> Dictionary:
		calls.append({
			"tick": tick,
			"stage_name": String(stage_name),
			"payload": payload.duplicate(true),
		})
		return {
			"ok": true,
			"dispatched": true,
			"backend_used": "gpu_compute",
			"dispatch_reason": "native_gpu_primary",
			"kernel_pass": "voxel_transform_stage_c",
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
	var sample_rows: Array = []
	var ack_calls: Array = []

	func sample_voxel_dispatch_contact_rows() -> Array:
		return sample_rows.duplicate(true)

	func acknowledge_voxel_dispatch_contact_rows(count: int, mutated: bool) -> void:
		ack_calls.append({"count": count, "mutated": mutated})

class MockCameraController extends RefCounted:
	func native_view_metrics() -> Dictionary:
		return {
			"zoom_factor": 0.25,
			"camera_distance": 9.5,
			"uniformity_score": 0.4,
			"compute_budget_scale": 0.6,
		}

func run_test(_tree: SceneTree) -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var scheduler := MockScheduler.new()
	var fps_launcher := MockFpsLauncher.new()
	var camera_controller := MockCameraController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	var synced_states: Array = []

	fps_launcher.sample_rows = [
		{
			"body_id": 998,
			"projectile_kind": "voxel_chunk",
			"contact_impulse": 12.0,
			"relative_speed": 21.0,
			"contact_point": Vector3(10.0, 4.0, 10.0),
		}
	]

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
		ok = _assert(String(payload.get("rate_tier", "")) == "contact_flush", "Dispatch payload should force rate_tier=contact_flush when only queued contacts trigger pulse.") and ok
		ok = _assert(_is_approx(float(payload.get("compute_budget_scale", 0.0)), 0.6), "Dispatch payload should preserve compute_budget_scale from native view metrics.") and ok
		ok = _assert(contacts.size() == 1, "Dispatch payload should pass projectile contact rows through to native stage.") and ok
		if contacts.size() == 1 and contacts[0] is Dictionary:
			var row := contacts[0] as Dictionary
			ok = _assert(int(row.get("body_id", 0)) == 998, "Dispatch payload should preserve contact origin body_id for native telemetry.") and ok

	ok = _assert(fps_launcher.ack_calls.size() == 1, "Successful mutation pulse should acknowledge queued projectile contacts exactly once.") and ok
	if fps_launcher.ack_calls.size() == 1 and fps_launcher.ack_calls[0] is Dictionary:
		var ack := fps_launcher.ack_calls[0] as Dictionary
		ok = _assert(int(ack.get("count", 0)) == 1, "Contact acknowledgment count should match dispatched queued-contact row count.") and ok
		ok = _assert(bool(ack.get("mutated", false)), "Contact acknowledgment should mark mutation-confirmed=true after native-authoritative mutation.") and ok

	ok = _assert(int(runtime.get("pulses_total", 0)) == 1 and int(runtime.get("pulses_success", 0)) == 1, "Runtime telemetry should track successful native dispatch pulse counters.") and ok
	ok = _assert(int(runtime.get("hits_queued", 0)) == 1 and int(runtime.get("contacts_dispatched", 0)) == 1, "Runtime telemetry should preserve queued/dispatched contact counters.") and ok
	ok = _assert(int(runtime.get("ops_applied", 0)) > 0, "Runtime telemetry should increment ops_applied when native mutation executes.") and ok
	var timings_variant = runtime.get("pulse_timings", [])
	var timings: Array = timings_variant if timings_variant is Array else []
	ok = _assert(timings.size() == 1, "Runtime telemetry should append one pulse timing sample for single dispatch pulse.") and ok
	if timings.size() == 1 and timings[0] is Dictionary:
		var timing := timings[0] as Dictionary
		ok = _assert(String(timing.get("backend_used", "")) == "gpu_compute", "Telemetry contract should pass through native backend_used origin unchanged.") and ok
		ok = _assert(String(timing.get("dispatch_reason", "")) == "native_gpu_primary", "Telemetry contract should pass through native dispatch_reason origin unchanged.") and ok
	ok = _assert(int(simulation_controller.metrics_payload.get("pulse_count", 0)) == 1, "Runtime telemetry push should sync pulse_count into simulation controller metrics contract.") and ok
	ok = _assert(synced_states.size() == 1, "Successful native mutation should emit exactly one sync_environment_from_state payload.") and ok
	simulation_controller.free()
	fps_launcher.free()
	return ok

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-5) -> bool:
	return absf(lhs - rhs) <= epsilon

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
