@tool
extends RefCounted

const NativeComputeBridgeScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const WorldDispatchContractsScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchContracts.gd")

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _run_native_tick_contract_behavior_test() and ok
	ok = _run_typed_error_taxonomy_behavior_test() and ok

	if ok:
		print("Native voxel orchestration behavior contracts passed (native tick + typed error taxonomy).")
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _run_native_tick_contract_behavior_test() -> bool:
	var payload := {
		"delta": 0.033,
		"physics_contacts": [
			{"body_id": 1, "projectile_kind": "voxel_chunk"},
			{"body_id": 2, "projectile_kind": "voxel_chunk"},
		],
	}
	var successful_dispatch := {
		"ok": true,
		"executed": true,
		"dispatched": true,
		"result": {
			"status": "ok",
			"execution": {"ops_requested": 3, "ops_processed": 2, "ops_requeued": 1},
			"counters": {"dispatch_count_total": 9, "dispatch_count_stage": 4},
		},
	}
	var failed_dispatch := {
		"ok": false,
		"executed": true,
		"dispatched": false,
		"error": "dispatch_failed",
		"result": {
			"status": "dispatch_failed",
			"execution": {"ops_requested": 3, "ops_processed": 0, "ops_requeued": 3},
			"counters": {"dispatch_count_total": 10, "dispatch_count_stage": 5},
		},
	}
	var success_contract := NativeComputeBridgeScript.environment_tick_contract(successful_dispatch, 28, payload)
	var failure_contract := NativeComputeBridgeScript.environment_tick_contract(failed_dispatch, 29, payload)
	var ok := true
	ok = _assert(bool(success_contract.get("dispatched", false)), "Native tick contract should report dispatched=true for successful native dispatch.") and ok
	ok = _assert(int(success_contract.get("contacts_submitted", 0)) == 2, "Native tick contract should report submitted contact count from payload.") and ok
	ok = _assert(int(success_contract.get("contacts_consumed", 0)) == 2, "Native tick contract should consume all submitted contacts when native dispatch succeeds.") and ok
	ok = _assert(int(success_contract.get("ops_requested", 0)) == 3 and int(success_contract.get("ops_processed", 0)) == 2, "Native tick contract should preserve native execution ops counters.") and ok
	ok = _assert(not bool(failure_contract.get("dispatched", true)), "Native tick contract should report dispatched=false for failed dispatch.") and ok
	ok = _assert(String(failure_contract.get("error", "")) == "dispatch_failed", "Native tick contract should preserve typed dispatch_failed error code on failed dispatch.") and ok
	ok = _assert(int(failure_contract.get("contacts_consumed", -1)) == 0, "Native tick contract should consume zero contacts on failed dispatch outcomes.") and ok
	return ok

func _run_typed_error_taxonomy_behavior_test() -> bool:
	var ok := true
	for reason in ["gpu_required", "gpu_unavailable", "native_required", "native_unavailable"]:
		var mutation := WorldDispatchContractsScript.build_native_authoritative_mutation(
			{"dispatch_reason": reason, "dispatched": true},
			{"changed_chunks": []},
			0
		)
		ok = _assert(String(mutation.get("error", "")) == reason, "Typed no-mutation contract should preserve '%s' error code." % reason) and ok
		var failure_paths_variant = mutation.get("failure_paths", [])
		var failure_paths: Array = failure_paths_variant if failure_paths_variant is Array else []
		ok = _assert(failure_paths.size() == 1 and String(failure_paths[0]) == reason, "Typed no-mutation contract should preserve '%s' failure_paths value." % reason) and ok
		ok = _assert(not bool(mutation.get("changed", true)), "Typed no-mutation contract should report changed=false for '%s'." % reason) and ok

	var generic_mutation := WorldDispatchContractsScript.build_native_authoritative_mutation(
		{"dispatch_reason": "contract_pending", "dispatched": true},
		{"changed_chunks": []},
		0
	)
	ok = _assert(String(generic_mutation.get("error", "")) == "native_voxel_stage_no_mutation", "Non-taxonomy dispatch reasons should normalize to native_voxel_stage_no_mutation.") and ok
	var generic_failure_paths_variant = generic_mutation.get("failure_paths", [])
	var generic_failure_paths: Array = generic_failure_paths_variant if generic_failure_paths_variant is Array else []
	ok = _assert(generic_failure_paths.size() == 1 and String(generic_failure_paths[0]) == "native_voxel_stage_no_mutation", "Generic no-mutation paths should report native_voxel_stage_no_mutation in failure_paths.") and ok
	return ok
