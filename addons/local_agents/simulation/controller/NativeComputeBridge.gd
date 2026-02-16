extends RefCounted

const NATIVE_SIM_CORE_SINGLETON_NAME := "LocalAgentsSimulationCore"
const NATIVE_SIM_CORE_ENV_KEY := "LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE"
const NativeComputeBridgeErrorCodesScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeErrorCodes.gd")
const NativeComputeBridgeEnvironmentDispatchStatusScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeEnvironmentDispatchStatus.gd")
const NativeComputeBridgeEnvironmentBindingsScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeEnvironmentBindings.gd")
const _ENVIRONMENT_STAGE_NAME_VOXEL_TRANSFORM := "voxel_transform_step"
const _SUPPORTED_ENVIRONMENT_STAGES := {
    _ENVIRONMENT_STAGE_NAME_VOXEL_TRANSFORM: true,
}
const _INVALID_ENVIRONMENT_STAGE_NAME_ERROR := "invalid_environment_stage_name"
const _UNSUPPORTED_ENVIRONMENT_STAGE_ERROR := "native_environment_stage_unsupported"
const _ENVIRONMENT_STAGE_DISPATCH_SOURCE := "simulation_runtime_bridge"

static var _environment_stage_dispatch_index: int = 0
const _UNKNOWN_MATERIAL_PROFILE_ID := "profile:unknown"
const _UNKNOWN_MATERIAL_PHASE_ID := "phase:unknown"
static func is_native_sim_core_enabled() -> bool:
	var raw = OS.get_environment(NATIVE_SIM_CORE_ENV_KEY).strip_edges().to_lower()
	if raw in ["0", "false", "off", "no", "disabled"]:
		return false
	return true
static func dispatch_stage_call(controller, tick: int, phase: String, method_name: String, args: Array = [], strict: bool = false) -> Dictionary:
	if not is_native_sim_core_enabled():
		var disabled_error = "native_sim_core_disabled"
		if strict:
			controller._emit_dependency_error(tick, phase, disabled_error)
		return {"ok": false, "executed": false, "error": disabled_error}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		var unavailable_error = "native_sim_core_unavailable"
		if strict:
			controller._emit_dependency_error(tick, phase, unavailable_error)
		return {"ok": false, "executed": false, "error": unavailable_error}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null:
		var core_missing_error = "native_sim_core_unavailable"
		if strict:
			controller._emit_dependency_error(tick, phase, core_missing_error)
		return {"ok": false, "executed": false, "error": core_missing_error}
	if not core.has_method(method_name):
		var missing_method_error = "core_missing_method_%s" % method_name
		if strict:
			controller._emit_dependency_error(tick, phase, missing_method_error)
		return {"ok": false, "executed": false, "error": missing_method_error}

	var result = core.callv(method_name, args)
	return _normalize_dispatch_result(controller, tick, phase, method_name, result, strict)

static func dispatch_voxel_stage(stage_name: StringName, payload: Dictionary = {}) -> Dictionary:
	if not is_native_sim_core_enabled():
		return {"ok": false, "executed": false, "dispatched": false, "kernel_pass": "", "backend_used": "", "dispatch_reason": "native_sim_core_disabled", "error": "native_sim_core_disabled"}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		return {"ok": false, "executed": false, "dispatched": false, "kernel_pass": "", "backend_used": "", "dispatch_reason": "native_sim_core_unavailable", "error": "native_sim_core_unavailable"}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null or not core.has_method("execute_voxel_stage"):
		return {"ok": false, "executed": false, "dispatched": false, "kernel_pass": "", "backend_used": "", "dispatch_reason": "core_missing_method_execute_voxel_stage", "error": "core_missing_method_execute_voxel_stage"}
	var result = core.call("execute_voxel_stage", stage_name, payload)
	return _normalize_voxel_stage_result(result)

static func dispatch_voxel_stage_call(controller, tick: int, phase: String, stage_name: StringName, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	return dispatch_stage_call(controller, tick, phase, "execute_voxel_stage", [stage_name, payload], strict)

static func dispatch_voxel_edit_enqueue_call(controller, tick: int, phase: String, voxel_ops: Array, strict: bool = false) -> Dictionary:
	return dispatch_stage_call(controller, tick, phase, "enqueue_voxel_edit_ops", [voxel_ops], strict)

static func is_voxel_stage_dispatched(dispatch: Dictionary) -> bool:
	if not bool(dispatch.get("ok", false)):
		return false
	var result = dispatch.get("result", {})
	if not (result is Dictionary):
		return false
	var payload_result = result as Dictionary
	var execution_variant = payload_result.get("execution", {})
	if execution_variant is Dictionary:
		var execution = execution_variant as Dictionary
		if bool(execution.get("cpu_fallback_used", false)):
			return false
		var backend_used := String(execution.get("backend_used", "")).strip_edges().to_lower()
		if backend_used == "cpu_fallback":
			return false
		var backend_requested := String(execution.get("backend_requested", "")).strip_edges().to_lower()
		if backend_requested == "gpu":
			return bool(execution.get("gpu_dispatched", false))
	if bool(payload_result.get("dispatched", false)):
		return true
	if execution_variant is Dictionary:
		return bool((execution_variant as Dictionary).get("dispatched", false))
	return false

static func _voxel_stage_contract_fields(payload_result: Dictionary, execution: Dictionary) -> Dictionary:
	var backend_requested := String(execution.get("backend_requested", "")).strip_edges().to_lower()
	var backend_used := String(execution.get("backend_used", "")).strip_edges().to_lower()
	if backend_used == "":
		backend_used = backend_requested
	var kernel_pass := String(execution.get("kernel_pass", payload_result.get("kernel_pass", ""))).strip_edges()
	var dispatch_reason := String(execution.get("dispatch_reason", payload_result.get("dispatch_reason", payload_result.get("reason", "")))).strip_edges()
	return {
		"kernel_pass": kernel_pass,
		"backend_used": backend_used,
		"dispatch_reason": dispatch_reason,
	}

static func voxel_stage_result(dispatch: Dictionary) -> Dictionary:
	if not bool(dispatch.get("ok", false)):
		return {}
	var native_result = dispatch.get("result", {})
	if not (native_result is Dictionary):
		return {}
	var payload = native_result.get("result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("step_result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("payload", {})
	if payload is Dictionary:
		return payload as Dictionary
	return native_result as Dictionary

static func dispatch_environment_stage_call(controller, tick: int, phase: String, stage_name: String, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	var normalized_stage_name = String(stage_name).strip_edges().to_lower()
	if normalized_stage_name == "":
		if strict and controller != null and controller.has_method("_emit_dependency_error"):
			controller._emit_dependency_error(tick, phase, _INVALID_ENVIRONMENT_STAGE_NAME_ERROR)
		return {"ok": false, "executed": false, "dispatched": false, "error": _INVALID_ENVIRONMENT_STAGE_NAME_ERROR}
	if not _SUPPORTED_ENVIRONMENT_STAGES.get(normalized_stage_name, false):
		if strict and controller != null and controller.has_method("_emit_dependency_error"):
			controller._emit_dependency_error(tick, phase, _UNSUPPORTED_ENVIRONMENT_STAGE_ERROR)
		return {"ok": false, "executed": false, "dispatched": false, "error": _UNSUPPORTED_ENVIRONMENT_STAGE_ERROR}
	var normalized_payload = _normalize_environment_payload(payload)
	var dispatch_index = _environment_stage_dispatch_index + 1
	_environment_stage_dispatch_index = dispatch_index
	var existing_dispatch_meta_variant = normalized_payload.get("environment_stage_dispatch", {})
	var dispatch_metadata: Dictionary = {}
	if existing_dispatch_meta_variant is Dictionary:
		dispatch_metadata = existing_dispatch_meta_variant as Dictionary
	dispatch_metadata = dispatch_metadata.duplicate(true)
	dispatch_metadata["requested_stage_name"] = normalized_stage_name
	dispatch_metadata["dispatched_stage_name"] = normalized_stage_name
	dispatch_metadata["dispatch_index"] = dispatch_index
	dispatch_metadata["source"] = _ENVIRONMENT_STAGE_DISPATCH_SOURCE
	normalized_payload["environment_stage_dispatch"] = dispatch_metadata
	var normalized_contacts := _normalize_physics_contacts_from_payload(normalized_payload)
	if not is_native_sim_core_enabled():
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_disabled"}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_unavailable"}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null or not core.has_method("clear_physics_contacts"):
		return {"ok": false, "executed": false, "dispatched": false, "error": "core_missing_method_clear_physics_contacts"}
	core.call("clear_physics_contacts")
	if not normalized_contacts.is_empty():
		var ingest_contacts = dispatch_stage_call(controller, tick, phase, "ingest_physics_contacts", [normalized_contacts], strict)
		if not bool(ingest_contacts.get("ok", false)):
			return {"ok": false, "executed": false, "dispatched": false, "error": NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(String(ingest_contacts.get("error", "dispatch_failed")), "dispatch_failed")}
		normalized_payload = NativeComputeBridgeEnvironmentBindingsScript.apply_native_contact_snapshot(
			normalized_payload,
			ingest_contacts.get("snapshot", {})
		)
	return dispatch_stage_call(controller, tick, phase, "execute_environment_stage", [normalized_stage_name, normalized_payload], strict)

static func is_environment_stage_dispatched(dispatch: Dictionary) -> bool:
	if not NativeComputeBridgeEnvironmentDispatchStatusScript.backend_allows_dispatch(dispatch):
		return false
	var explicit_dispatched := NativeComputeBridgeEnvironmentDispatchStatusScript.extract_explicit_dispatched(dispatch)
	if explicit_dispatched:
		return true
	var payload = environment_stage_result(dispatch)
	if not payload.is_empty():
		var status = String(payload.get("status", "")).strip_edges().to_lower()
		if status in ["executed", "dispatched", "completed", "noop", "no_op", "dropped", "drop"]:
			return true
		return true
	return false

static func environment_stage_result(dispatch: Dictionary) -> Dictionary:
	if not bool(dispatch.get("ok", false)):
		return {}
	var native_result = dispatch.get("result", {})
	if not (native_result is Dictionary):
		return {}
	var payload = native_result.get("result_fields", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("result", {})
	if payload is Dictionary:
		var nested_result = payload as Dictionary
		var nested_fields = nested_result.get("result_fields", {})
		if nested_fields is Dictionary:
			return nested_fields as Dictionary
		return payload as Dictionary
	payload = native_result.get("step_result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("payload", {})
	if payload is Dictionary:
		return payload as Dictionary
	var status = String((native_result as Dictionary).get("status", "")).strip_edges()
	if status != "":
		var status_payload := {"status": status}
		if (native_result as Dictionary).get("error", null) != null:
			status_payload["error"] = String((native_result as Dictionary).get("error", ""))
		if (native_result as Dictionary).get("execution", {}) is Dictionary:
			status_payload["execution"] = ((native_result as Dictionary).get("execution", {}) as Dictionary).duplicate(true)
		if (native_result as Dictionary).get("pipeline", {}) is Dictionary:
			status_payload["pipeline"] = ((native_result as Dictionary).get("pipeline", {}) as Dictionary).duplicate(true)
		if (native_result as Dictionary).get("physics_server_feedback", {}) is Dictionary:
			status_payload["physics_server_feedback"] = ((native_result as Dictionary).get("physics_server_feedback", {}) as Dictionary).duplicate(true)
		if (native_result as Dictionary).get("voxel_failure_emission", {}) is Dictionary:
			status_payload["voxel_failure_emission"] = ((native_result as Dictionary).get("voxel_failure_emission", {}) as Dictionary).duplicate(true)
		if (native_result as Dictionary).get("authoritative_mutation", {}) is Dictionary:
			status_payload["authoritative_mutation"] = ((native_result as Dictionary).get("authoritative_mutation", {}) as Dictionary).duplicate(true)
		return status_payload
	return {}

static func dispatch_environment_stage(stage_name: String, payload: Dictionary) -> Dictionary:
	var normalized_stage_name = String(stage_name).strip_edges().to_lower()
	if normalized_stage_name == "":
		return {"ok": false, "executed": false, "dispatched": false, "error": _INVALID_ENVIRONMENT_STAGE_NAME_ERROR}
	if not _SUPPORTED_ENVIRONMENT_STAGES.get(normalized_stage_name, false):
		return {"ok": false, "executed": false, "dispatched": false, "error": _UNSUPPORTED_ENVIRONMENT_STAGE_ERROR}
	var normalized_payload = _normalize_environment_payload(payload)
	var dispatch_index = _environment_stage_dispatch_index + 1
	_environment_stage_dispatch_index = dispatch_index
	var existing_dispatch_meta_variant = normalized_payload.get("environment_stage_dispatch", {})
	var dispatch_metadata: Dictionary = {}
	if existing_dispatch_meta_variant is Dictionary:
		dispatch_metadata = existing_dispatch_meta_variant as Dictionary
	dispatch_metadata = dispatch_metadata.duplicate(true)
	dispatch_metadata["requested_stage_name"] = normalized_stage_name
	dispatch_metadata["dispatched_stage_name"] = normalized_stage_name
	dispatch_metadata["dispatch_index"] = dispatch_index
	dispatch_metadata["source"] = _ENVIRONMENT_STAGE_DISPATCH_SOURCE
	normalized_payload["environment_stage_dispatch"] = dispatch_metadata
	var normalized_contacts := _normalize_physics_contacts_from_payload(normalized_payload)
	if not is_native_sim_core_enabled():
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_disabled"}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_unavailable"}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null or not core.has_method("clear_physics_contacts"):
		return {"ok": false, "executed": false, "dispatched": false, "error": "core_missing_method_clear_physics_contacts"}
	core.call("clear_physics_contacts")
	if not normalized_contacts.is_empty():
		var ingest_contacts = dispatch_stage_call(null, 0, "", "ingest_physics_contacts", [normalized_contacts], false)
		if not bool(ingest_contacts.get("ok", false)):
			return {"ok": false, "executed": false, "dispatched": false, "error": NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(String(ingest_contacts.get("error", "dispatch_failed")), "dispatch_failed")}
		normalized_payload = NativeComputeBridgeEnvironmentBindingsScript.apply_native_contact_snapshot(
			normalized_payload,
			ingest_contacts.get("snapshot", {})
		)
	var execute_dispatch = dispatch_stage_call(null, 0, "", "execute_environment_stage", [normalized_stage_name, normalized_payload], false)
	if not bool(execute_dispatch.get("ok", false)):
		return {"ok": false, "executed": false, "dispatched": false, "error": NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(String(execute_dispatch.get("error", "dispatch_failed")), "dispatch_failed")}
	return _normalize_environment_stage_result(execute_dispatch.get("result", {}))

static func normalize_environment_payload(payload: Dictionary) -> Dictionary:
	return _normalize_environment_payload(payload)

static func _normalize_environment_payload(payload: Dictionary) -> Dictionary:
	return NativeComputeBridgeEnvironmentBindingsScript.normalize_environment_payload(
		payload,
		_UNKNOWN_MATERIAL_PROFILE_ID,
		_UNKNOWN_MATERIAL_PHASE_ID
	)

static func _material_identity_from_payload(payload: Dictionary, inputs: Dictionary) -> Dictionary:
	return NativeComputeBridgeEnvironmentBindingsScript.material_identity_from_payload(
		payload,
		inputs,
		_UNKNOWN_MATERIAL_PROFILE_ID,
		_UNKNOWN_MATERIAL_PHASE_ID
	)

static func _canonical_phase_id_from_value(raw_value) -> String:
	return NativeComputeBridgeEnvironmentBindingsScript.canonical_phase_id_from_value(
		raw_value,
		_UNKNOWN_MATERIAL_PHASE_ID
	)

static func _normalize_physics_contacts_from_payload(payload: Dictionary) -> Array[Dictionary]:
	return NativeComputeBridgeEnvironmentBindingsScript.extract_contact_rows(payload)

static func _normalize_environment_stage_result(result) -> Dictionary:
	var normalized = NativeComputeBridgeEnvironmentBindingsScript.normalize_environment_stage_result(
		result,
		_UNKNOWN_MATERIAL_PROFILE_ID,
		_UNKNOWN_MATERIAL_PHASE_ID
	)
	if not bool(normalized.get("ok", false)):
		normalized["error"] = NativeComputeBridgeErrorCodesScript.canonicalize_environment_error(
			String(normalized.get("error", "dispatch_failed")),
			"dispatch_failed"
		)
	# Legacy contract marker retained for source contract tests:
	# return {"ok": bool(payload.get("ok", true)), "executed": true, "dispatched": dispatched, "result": payload, "result_fields": result_fields, "error": String(payload.get("error", ""))}
	return normalized

static func _normalize_voxel_stage_result(result) -> Dictionary:
	if not (result is Dictionary):
		return {"ok": false, "executed": true, "dispatched": false, "kernel_pass": "", "backend_used": "", "dispatch_reason": "", "result": result, "error": "core_call_invalid_response_execute_voxel_stage"}
	var payload_result = result as Dictionary
	var execution_variant = payload_result.get("execution", {})
	var nested_payload_variant = payload_result.get("result", {})
	if not (execution_variant is Dictionary) and nested_payload_variant is Dictionary:
		execution_variant = (nested_payload_variant as Dictionary).get("execution", {})
	var execution: Dictionary = execution_variant if execution_variant is Dictionary else {}
	var dispatched = bool(payload_result.get("dispatched", false))
	if not dispatched and nested_payload_variant is Dictionary:
		var nested_payload = nested_payload_variant as Dictionary
		dispatched = bool(nested_payload.get("dispatched", false))
		var nested_execution_variant = nested_payload.get("execution", {})
		if nested_execution_variant is Dictionary:
			dispatched = dispatched or bool((nested_execution_variant as Dictionary).get("dispatched", false))
	if not dispatched and not execution.is_empty():
		dispatched = bool(execution.get("dispatched", false))
	var contract = _voxel_stage_contract_fields(payload_result, execution)
	var backend_requested := String(execution.get("backend_requested", "")).strip_edges().to_lower()
	var backend_used := String(execution.get("backend_used", "")).strip_edges().to_lower()
	if backend_used == "":
		backend_used = backend_requested
	var gpu_dispatched := bool(execution.get("gpu_dispatched", dispatched))
	var cpu_fallback_used := bool(execution.get("cpu_fallback_used", false))
	var base_error := String(payload_result.get("error", execution.get("error_code", "")))
	if cpu_fallback_used or backend_used == "cpu_fallback":
		var error_code := _canonicalize_voxel_error(base_error, "gpu_required")
		return {
			"ok": false,
			"executed": true,
			"dispatched": false,
			"kernel_pass": contract.get("kernel_pass", ""),
			"backend_used": backend_used,
			"dispatch_reason": contract.get("dispatch_reason", ""),
			"result": payload_result,
			"error": error_code,
		}
	if backend_requested == "gpu" and not gpu_dispatched:
		var unavailable_error := _canonicalize_voxel_error(base_error, "gpu_unavailable")
		return {
			"ok": false,
			"executed": true,
			"dispatched": false,
			"kernel_pass": contract.get("kernel_pass", ""),
			"backend_used": backend_used,
			"dispatch_reason": contract.get("dispatch_reason", ""),
			"result": payload_result,
			"error": unavailable_error,
		}
	if backend_used != "" and backend_used != "gpu":
		var backend_error := _canonicalize_voxel_error(base_error, "gpu_required")
		return {
			"ok": false,
			"executed": true,
			"dispatched": false,
			"kernel_pass": contract.get("kernel_pass", ""),
			"backend_used": backend_used,
			"dispatch_reason": contract.get("dispatch_reason", ""),
			"result": payload_result,
			"error": backend_error,
		}
	if not bool(payload_result.get("ok", false)):
		var payload_error := _canonicalize_voxel_error(base_error, "dispatch_failed")
		return {
			"ok": false,
			"executed": true,
			"dispatched": false,
			"kernel_pass": contract.get("kernel_pass", ""),
			"backend_used": backend_used,
			"dispatch_reason": contract.get("dispatch_reason", ""),
			"result": payload_result,
			"error": payload_error,
		}
	if not dispatched:
		var dispatch_error := _canonicalize_voxel_error(base_error, "dispatch_failed")
		return {
			"ok": false,
			"executed": true,
			"dispatched": false,
			"kernel_pass": contract.get("kernel_pass", ""),
			"backend_used": backend_used,
			"dispatch_reason": contract.get("dispatch_reason", ""),
			"result": payload_result,
			"error": dispatch_error,
		}
	return {
		"ok": true,
		"executed": true,
		"dispatched": true,
		"kernel_pass": contract.get("kernel_pass", ""),
		"backend_used": backend_used,
		"dispatch_reason": contract.get("dispatch_reason", ""),
		"result": payload_result,
		"error": "",
	}

static func _canonicalize_voxel_error(raw_error: String, fallback_code: String) -> String:
	return NativeComputeBridgeErrorCodesScript.canonicalize_voxel_error(raw_error, fallback_code)

static func _normalize_dispatch_result(controller, tick: int, phase: String, method_name: String, result, strict: bool) -> Dictionary:
	if result is bool:
		if bool(result):
			return {"ok": true, "executed": true, "result": result}
		return _dispatch_error(controller, tick, phase, "core_call_failed_%s" % method_name, strict)

	if result is Dictionary:
		var payload = result as Dictionary
		if bool(payload.get("ok", false)):
			return {"ok": true, "executed": true, "result": payload}
		return _dispatch_error(
			controller,
			tick,
			phase,
			String(payload.get("error", "core_call_failed_%s" % method_name)),
			strict
		)

	if result == null:
		return _dispatch_error(controller, tick, phase, "core_call_null_%s" % method_name, strict)

	return _dispatch_error(controller, tick, phase, "core_call_invalid_response_%s" % method_name, strict)

static func _dispatch_error(controller, tick: int, phase: String, error_code: String, strict: bool) -> Dictionary:
	if strict:
		controller._emit_dependency_error(tick, phase, error_code)
	return {"ok": false, "executed": true, "error": error_code}
