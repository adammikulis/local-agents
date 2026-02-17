@tool
extends RefCounted

const WorldDispatchControllerScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd")
const WorldNativeVoxelDispatchRuntimeScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")
const SimulationVoxelTerrainMutatorScript := preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")

class MockSimulationController extends Node:
	var calls: Array = []
	var dispatch_responses: Array = []
	var metrics_payload: Dictionary = {}

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
		return _dispatch_without_native_ops(1)

	func set_transform_dispatch_metrics(metrics: Dictionary) -> void:
		metrics_payload = metrics.duplicate(true)

	func get_physics_contact_snapshot() -> Dictionary:
		return {"buffered_rows": []}

	func _dispatch_without_native_ops(contacts_consumed: int) -> Dictionary:
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
				"ops_changed": 0,
				"changed": false,
				"changed_chunks": [],
				"per_stage_ms": {"stage_c": 0.21},
			},
			"result": {
				"ops_changed": 0,
				"changed": false,
				"changed_chunks": [],
			},
		}

class MockCameraController extends RefCounted:
	func native_view_metrics() -> Dictionary:
		return {
			"zoom_factor": 0.2,
			"camera_distance": 7.0,
			"uniformity_score": 0.5,
			"compute_budget_scale": 0.75,
		}

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _run_mixed_contact_ingress_merge_failure_test() and ok
	ok = _run_reimpact_only_no_success_branch_test() and ok
	ok = _run_contact_source_failure_contract_test() and ok
	if ok:
		print("Native debris dispatch unified-impact contract test passed.")
	return ok

func _run_mixed_contact_ingress_merge_failure_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	var camera_controller := MockCameraController.new()
	simulation_controller.dispatch_responses.append(simulation_controller._dispatch_without_native_ops(1))

	var dedupe_contact_id := "impact-chain-100"
	var projectile_row := _contact_row(dedupe_contact_id, "launcher_projectile", 7001)
	var debris_row := _contact_row(dedupe_contact_id, "fracture_debris", 7001)
	var reimpact_row := _contact_row(dedupe_contact_id, "reimpact", 7001)
	var context := {
		"tick": 100,
		"frame_index": 420,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"camera_controller": camera_controller,
		"projectile_contact_rows": [projectile_row],
		"debris_contact_rows": [debris_row],
		"fracture_contact_rows": [debris_row],
		"reimpact_contact_rows": [reimpact_row],
		"re_impact_contact_rows": [reimpact_row],
	}

	var status: Dictionary = controller.process_native_voxel_rate(0.016, context)
	var ok := true
	ok = _assert(simulation_controller.calls.size() == 1, "Unified impact chain should call execute_native_voxel_stage exactly once per pulse.") and ok
	if simulation_controller.calls.size() == 1 and simulation_controller.calls[0] is Dictionary:
		var call := simulation_controller.calls[0] as Dictionary
		var payload_variant = call.get("payload", {})
		var payload: Dictionary = payload_variant if payload_variant is Dictionary else {}
		var contacts_variant = payload.get("physics_contacts", [])
		var contacts: Array = contacts_variant if contacts_variant is Array else []
		ok = _assert(contacts.size() == 1, "All impact ingress rows (including legacy aliases) should merge into one dispatch contact row.") and ok
		if contacts.size() == 1 and contacts[0] is Dictionary:
			var ingress_row := contacts[0] as Dictionary
			ok = _assert(String(ingress_row.get("contact_id", "")) == dedupe_contact_id, "Merged dispatch ingress should preserve canonical contact_id.") and ok
			ok = _assert(int(ingress_row.get("deadline_frame", -1)) > int(ingress_row.get("hit_frame", 0)), "Merged dispatch ingress should preserve deadline metadata.") and ok

	ok = _assert(not bool(status.get("ok", true)), "Contact-driven mixed impact dispatch must fail when native ops are missing.") and ok
	ok = _assert(bool(status.get("dispatched", false)), "Dispatch should still execute on GPU path before fail-fast mutation result is applied.") and ok
	ok = _assert(not bool(status.get("mutation_applied", true)), "Mixed impact dispatch must not report mutation_applied=true without native ops.") and ok
	ok = _assert(String(status.get("error", "")) == "native_voxel_op_payload_missing", "Missing native ops should return typed native_voxel_op_payload_missing error for mixed ingress.") and ok
	ok = _assert(String(status.get("mutation_error", "")) == "native_voxel_op_payload_missing", "mutation_error should match typed no-native-op failure for mixed ingress.") and ok
	ok = _assert(String(status.get("mutation_path", "")) == "native_ops_payload_primary", "Mixed ingress should fail on canonical native_ops_payload_primary mutation path.") and ok
	ok = _assert(int(status.get("contacts_consumed", -1)) == 0, "contacts_consumed must remain 0 when mutation is not applied.") and ok
	ok = _assert(int(runtime.get("contacts_dispatched", -1)) == 0, "Runtime contacts_dispatched must remain 0 for no-native-op failures.") and ok
	ok = _assert(String(runtime.get("last_drop_reason", "")) == "native_voxel_op_payload_missing", "Runtime drop reason should preserve typed no-native-op failure.") and ok
	return ok

func _run_reimpact_only_no_success_branch_test() -> bool:
	var controller := WorldDispatchControllerScript.new()
	var simulation_controller := MockSimulationController.new()
	var runtime := WorldNativeVoxelDispatchRuntimeScript.default_runtime()
	var camera_controller := MockCameraController.new()
	simulation_controller.dispatch_responses.append(simulation_controller._dispatch_without_native_ops(1))

	var context := {
		"tick": 101,
		"frame_index": 421,
		"simulation_controller": simulation_controller,
		"native_voxel_dispatch_runtime": runtime,
		"camera_controller": camera_controller,
		"reimpact_contact_rows": [_contact_row("impact-chain-200", "reimpact", 8002)],
	}
	var status: Dictionary = controller.process_native_voxel_rate(0.016, context)
	var ok := true
	ok = _assert(not bool(status.get("ok", true)), "Re-impact rows must not create a separate success branch when native ops are missing.") and ok
	ok = _assert(not bool(status.get("mutation_applied", true)), "Re-impact rows must report mutation_applied=false without native ops.") and ok
	ok = _assert(String(status.get("error", "")) == "native_voxel_op_payload_missing", "Re-impact no-native-op failures must keep explicit native_voxel_op_payload_missing error code.") and ok
	ok = _assert(String(status.get("mutation_path", "")) == "native_ops_payload_primary", "Re-impact no-native-op failures must stay on canonical native_ops_payload_primary path.") and ok
	ok = _assert(int(runtime.get("contacts_dispatched", -1)) == 0, "Re-impact no-native-op failures must not count as dispatched contacts.") and ok
	return ok

func _run_contact_source_failure_contract_test() -> bool:
	var simulation_controller := MockSimulationController.new()
	var cases := [
		{"source": "launcher_projectile", "id": "impact-chain-projectile"},
		{"source": "fracture_debris", "id": "impact-chain-debris"},
		{"source": "reimpact", "id": "impact-chain-reimpact"},
	]

	var ok := true
	var tick := 300
	for case_variant in cases:
		if not (case_variant is Dictionary):
			continue
		var case_data := case_variant as Dictionary
		var payload := {
			"physics_contacts": [_contact_row(String(case_data.get("id", "")), String(case_data.get("source", "")), 9100 + tick)],
			"changed_chunks": [{"x": 1, "y": 0, "z": 1}],
		}
		var mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(
			simulation_controller,
			tick,
			payload
		)
		var label := String(case_data.get("source", "unknown"))
		ok = _assert(not bool(mutation.get("changed", true)), "%s missing-native-op path must report changed=false." % label) and ok
		ok = _assert(String(mutation.get("mutation_path", "")) == "native_ops_payload_primary", "%s missing-native-op path must use native_ops_payload_primary." % label) and ok
		ok = _assert(String(mutation.get("mutation_path_state", "")) == "failure", "%s missing-native-op path must report mutation_path_state=failure." % label) and ok
		ok = _assert(String(mutation.get("error", "")) == "native_voxel_op_payload_missing", "%s missing-native-op path must return typed native_voxel_op_payload_missing." % label) and ok
		var failure_paths_variant = mutation.get("failure_paths", [])
		var failure_paths: Array = failure_paths_variant if failure_paths_variant is Array else []
		ok = _assert(failure_paths.size() == 1 and String(failure_paths[0]) == "native_voxel_op_payload_missing", "%s missing-native-op path must keep explicit failure_paths without fallback success." % label) and ok
		tick += 1
	return ok

func _contact_row(contact_id: String, contact_source: String, body_id: int) -> Dictionary:
	var row := {
		"contact_id": contact_id,
		"body_id": body_id,
		"collider_id": 5,
		"frame": 100,
		"hit_frame": 100,
		"deadline_frame": 106,
		"contact_point": Vector3(1.0, 2.0, 3.0),
		"contact_impulse": 6.0,
		"relative_speed": 10.0,
		"projectile_kind": "voxel_chunk",
		"projectile_density_tag": "dense",
		"projectile_hardness_tag": "hard",
		"projectile_material_tag": "dense_voxel",
		"failure_emission_profile": "dense_hard_voxel_chunk",
		"projectile_radius": 0.07,
		"body_mass": 0.2,
	}
	if contact_source != "":
		row["contact_source"] = contact_source
	return row

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
