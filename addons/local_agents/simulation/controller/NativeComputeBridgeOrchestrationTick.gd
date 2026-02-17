extends RefCounted

const NativeComputeBridgeErrorCodesScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeErrorCodes.gd")

static func normalize_tick_dispatch(dispatch: Dictionary, tick: int, payload: Dictionary, delta_seconds: float, frame_index: int) -> Dictionary:
	if not bool(dispatch.get("ok", false)):
		var dispatch_error := String(dispatch.get("error", "dispatch_failed"))
		return _error_contract(dispatch_error, tick, delta_seconds, frame_index, _submitted_contact_count(payload), false)

	var orchestration_variant = dispatch.get("result", {})
	if not (orchestration_variant is Dictionary):
		return _error_contract("core_call_invalid_response_execute_voxel_orchestration_tick", tick, delta_seconds, frame_index, _submitted_contact_count(payload), false)
	var orchestration = orchestration_variant as Dictionary
	var stage_dispatch_variant = orchestration.get("dispatch", {})
	var stage_dispatch: Dictionary = stage_dispatch_variant if stage_dispatch_variant is Dictionary else {}
	var stage_result := _extract_stage_result(stage_dispatch)
	var execution := _extract_execution(stage_dispatch, stage_result)
	var dispatched := bool(orchestration.get("dispatched", false))
	if not dispatched:
		dispatched = bool(stage_dispatch.get("dispatched", false))
	if not dispatched:
		dispatched = bool(execution.get("dispatched", false))
	if not dispatched and not stage_result.is_empty():
		dispatched = true

	var submitted_contacts := _submitted_contact_count(payload)
	var consumed_contacts := maxi(0, int(orchestration.get("consumed_count", 0)))
	if consumed_contacts <= 0 and dispatched:
		consumed_contacts = submitted_contacts
	var backend_used := _extract_backend(orchestration, stage_dispatch, execution)
	var dispatch_reason := _extract_dispatch_reason(orchestration, stage_dispatch, stage_result, execution)
	var kernel_pass := String(orchestration.get("kernel_pass", execution.get("kernel_pass", stage_result.get("kernel_pass", "")))).strip_edges()
	var raw_error := String(orchestration.get("error", stage_dispatch.get("error", dispatch.get("error", ""))))
	var normalized_error := NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(raw_error, "dispatch_failed") if raw_error != "" else ""
	var mutation_applied := bool(orchestration.get("mutation_applied", bool(stage_result.get("changed", false))))
	var ok := bool(orchestration.get("ok", false)) and bool(stage_dispatch.get("ok", true)) and dispatched
	if not ok and normalized_error == "":
		normalized_error = "dispatch_failed"
	var native_tick_contract := {
		"tier_id": "native_consolidated_tick",
		"tick": tick,
		"delta": maxf(0.0, delta_seconds),
		"frame_index": frame_index,
		"dispatched": dispatched,
		"status": String(stage_result.get("status", orchestration.get("status", ""))),
		"error": normalized_error,
		"contacts_submitted": submitted_contacts,
		"contacts_consumed": consumed_contacts,
		"ack_required": bool(orchestration.get("ack_required", consumed_contacts > 0)),
		"mutation_applied": mutation_applied,
		"ops_requested": maxi(0, int(stage_result.get("ops_requested", execution.get("ops_requested", 0)))),
		"ops_processed": maxi(0, int(stage_result.get("ops_processed", execution.get("ops_processed", 0)))),
		"ops_requeued": maxi(0, int(stage_result.get("ops_requeued", execution.get("ops_requeued", 0)))),
		"queue_pending_before": maxi(0, int(execution.get("queue_pending_before", 0))),
		"queue_pending_after": maxi(0, int(execution.get("queue_pending_after", 0))),
	}

	if backend_used == "" and dispatched:
		backend_used = "gpu"
	if backend_used.findn("gpu") == -1 and dispatched:
		ok = false
		if normalized_error == "":
			normalized_error = "gpu_required"
		native_tick_contract["error"] = normalized_error

	return {
		"ok": ok,
		"executed": bool(dispatch.get("executed", false)),
		"dispatched": dispatched,
		"kernel_pass": kernel_pass,
		"backend_used": backend_used,
		"dispatch_reason": dispatch_reason,
		"result": stage_dispatch.get("result", orchestration),
		"voxel_result": stage_result,
		"native_mutation_authority": _extract_native_mutation_authority(orchestration, stage_result, execution),
		"native_tick_contract": native_tick_contract,
		"error": normalized_error,
	}

static func _extract_stage_result(stage_dispatch: Dictionary) -> Dictionary:
	var stage_result_variant = stage_dispatch.get("result_fields", {})
	if stage_result_variant is Dictionary:
		return (stage_result_variant as Dictionary).duplicate(true)
	var raw_result_variant = stage_dispatch.get("result", {})
	if raw_result_variant is Dictionary:
		var raw_result = raw_result_variant as Dictionary
		var nested_variant = raw_result.get("result_fields", {})
		if nested_variant is Dictionary:
			return (nested_variant as Dictionary).duplicate(true)
		return raw_result.duplicate(true)
	return {}

static func _extract_execution(stage_dispatch: Dictionary, stage_result: Dictionary) -> Dictionary:
	var execution_variant = stage_result.get("execution", {})
	if execution_variant is Dictionary:
		return (execution_variant as Dictionary).duplicate(true)
	var stage_result_variant = stage_dispatch.get("result", {})
	if stage_result_variant is Dictionary:
		var stage_result_payload = stage_result_variant as Dictionary
		var nested_execution_variant = stage_result_payload.get("execution", {})
		if nested_execution_variant is Dictionary:
			return (nested_execution_variant as Dictionary).duplicate(true)
	return {}

static func _extract_backend(orchestration: Dictionary, stage_dispatch: Dictionary, execution: Dictionary) -> String:
	var backend_used := String(orchestration.get("backend_used", execution.get("backend_used", ""))).strip_edges().to_lower()
	if backend_used != "":
		return backend_used
	backend_used = String(execution.get("backend_requested", "")).strip_edges().to_lower()
	if backend_used != "":
		return backend_used
	var dispatch_result_variant = stage_dispatch.get("result", {})
	if dispatch_result_variant is Dictionary:
		var dispatch_result = dispatch_result_variant as Dictionary
		var nested_execution_variant = dispatch_result.get("execution", {})
		if nested_execution_variant is Dictionary:
			var nested_execution = nested_execution_variant as Dictionary
			backend_used = String(nested_execution.get("backend_used", nested_execution.get("backend_requested", ""))).strip_edges().to_lower()
			if backend_used != "":
				return backend_used
	return ""

static func _extract_dispatch_reason(orchestration: Dictionary, stage_dispatch: Dictionary, stage_result: Dictionary, execution: Dictionary) -> String:
	var dispatch_reason := String(orchestration.get("dispatch_reason", execution.get("dispatch_reason", ""))).strip_edges()
	if dispatch_reason != "":
		return dispatch_reason
	dispatch_reason = String(stage_result.get("status", "")).strip_edges()
	if dispatch_reason != "":
		return dispatch_reason
	return String(stage_dispatch.get("error", "")).strip_edges()

static func _extract_native_mutation_authority(orchestration: Dictionary, stage_result: Dictionary, execution: Dictionary) -> Dictionary:
	var authority: Dictionary = {}
	for source in [execution, stage_result, orchestration]:
		if not (source is Dictionary):
			continue
		var source_dict := source as Dictionary
		if source_dict.has("ops_changed"):
			authority["ops_changed"] = maxi(0, int(source_dict.get("ops_changed", 0)))
		if source_dict.has("changed"):
			authority["changed"] = bool(source_dict.get("changed", false))
		if source_dict.has("changed_chunks") and source_dict.get("changed_chunks", []) is Array:
			authority["changed_chunks"] = (source_dict.get("changed_chunks", []) as Array).duplicate(true)
		if source_dict.has("changed_region") and source_dict.get("changed_region", {}) is Dictionary:
			authority["changed_region"] = (source_dict.get("changed_region", {}) as Dictionary).duplicate(true)
	var explicit_authority_variant = stage_result.get("authoritative_mutation", {})
	if explicit_authority_variant is Dictionary:
		var explicit_authority = explicit_authority_variant as Dictionary
		if explicit_authority.has("changed"):
			authority["changed"] = bool(explicit_authority.get("changed", false))
		if explicit_authority.has("ops_changed"):
			authority["ops_changed"] = maxi(0, int(explicit_authority.get("ops_changed", 0)))
		if explicit_authority.has("changed_chunks") and explicit_authority.get("changed_chunks", []) is Array:
			authority["changed_chunks"] = (explicit_authority.get("changed_chunks", []) as Array).duplicate(true)
		if explicit_authority.has("changed_region") and explicit_authority.get("changed_region", {}) is Dictionary:
			authority["changed_region"] = (explicit_authority.get("changed_region", {}) as Dictionary).duplicate(true)
	return authority

static func _submitted_contact_count(payload: Dictionary) -> int:
	var contacts_variant = payload.get("physics_contacts", payload.get("physics_server_contacts", []))
	if contacts_variant is Array:
		return (contacts_variant as Array).size()
	if contacts_variant is Dictionary:
		var contacts = contacts_variant as Dictionary
		var buffered_rows_variant = contacts.get("buffered_rows", [])
		if buffered_rows_variant is Array:
			return (buffered_rows_variant as Array).size()
	return 0

static func _error_contract(error_code: String, tick: int, delta_seconds: float, frame_index: int, contacts_submitted: int, dispatched: bool) -> Dictionary:
	var canonical_error := NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(error_code, "dispatch_failed")
	return {
		"ok": false,
		"executed": true,
		"dispatched": dispatched,
		"kernel_pass": "",
		"backend_used": "",
		"dispatch_reason": "",
		"result": {},
		"voxel_result": {},
		"native_mutation_authority": {},
		"native_tick_contract": {
			"tier_id": "native_consolidated_tick",
			"tick": tick,
			"delta": maxf(0.0, delta_seconds),
			"frame_index": frame_index,
			"dispatched": dispatched,
			"status": "",
			"error": canonical_error,
			"contacts_submitted": maxi(0, contacts_submitted),
			"contacts_consumed": 0,
			"ack_required": false,
			"mutation_applied": false,
		},
		"error": canonical_error,
	}
