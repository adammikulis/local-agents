extends RefCounted

static func backend_allows_dispatch(dispatch: Dictionary) -> bool:
	if not bool(dispatch.get("ok", false)):
		return false
	var result = dispatch.get("result", {})
	if not (result is Dictionary):
		return false
	var native_result = result as Dictionary
	var execution_variant = native_result.get("execution", {})
	if not (execution_variant is Dictionary):
		return true
	var execution = execution_variant as Dictionary
	if bool(execution.get("cpu_fallback_used", false)):
		return false
	var backend_used := String(execution.get("backend_used", "")).strip_edges().to_lower()
	if backend_used == "cpu_fallback":
		return false
	var backend_requested := String(execution.get("backend_requested", "")).strip_edges().to_lower()
	if backend_requested == "gpu" and not bool(execution.get("gpu_dispatched", false)):
		return false
	if backend_used != "" and backend_used != "gpu":
		return false
	return true

static func extract_explicit_dispatched(dispatch: Dictionary) -> bool:
	if not bool(dispatch.get("ok", false)):
		return false
	var result = dispatch.get("result", {})
	if not (result is Dictionary):
		return false
	var native_result = result as Dictionary
	var explicit_dispatched = bool(dispatch.get("dispatched", false))
	explicit_dispatched = explicit_dispatched or bool(native_result.get("dispatched", false))
	var execution_variant = native_result.get("execution", {})
	if execution_variant is Dictionary:
		explicit_dispatched = explicit_dispatched or bool((execution_variant as Dictionary).get("dispatched", false))
	var nested_result_variant = native_result.get("result", {})
	if nested_result_variant is Dictionary:
		var nested_result = nested_result_variant as Dictionary
		explicit_dispatched = explicit_dispatched or bool(nested_result.get("dispatched", false))
		var nested_execution_variant = nested_result.get("execution", {})
		if nested_execution_variant is Dictionary:
			explicit_dispatched = explicit_dispatched or bool((nested_execution_variant as Dictionary).get("dispatched", false))
	return explicit_dispatched
