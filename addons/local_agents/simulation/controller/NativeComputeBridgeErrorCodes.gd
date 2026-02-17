extends RefCounted

static func canonicalize_environment_error(raw_error: String, fallback_code: String) -> String:
	var code := raw_error.strip_edges()
	if code == "":
		return fallback_code
	var lowered := code.to_lower()
	if lowered in ["gpu_required", "gpu_unavailable", "native_required", "dispatch_failed"]:
		return lowered
	if lowered.find("gpu_required") != -1:
		return "gpu_required"
	if lowered.find("gpu_backend_unavailable") != -1 or lowered.find("rendering_server_unavailable") != -1 or lowered.find("device_create_failed") != -1:
		return "gpu_unavailable"
	if lowered.find("native") != -1 or lowered.find("core_missing_method") != -1 or lowered.find("compute_manager_unavailable") != -1:
		return "native_required"
	if lowered.find("dispatch") != -1 or lowered.find("shader") != -1 or lowered.find("compute") != -1 or lowered.find("pipeline") != -1:
		return "dispatch_failed"
	return fallback_code

static func canonicalize_voxel_error(raw_error: String, fallback_code: String) -> String:
	var code := raw_error.strip_edges()
	if code == "":
		return fallback_code
	var lowered := code.to_lower()
	if lowered in ["gpu_required", "gpu_unavailable", "contract_mismatch", "descriptor_invalid", "dispatch_failed", "readback_invalid", "memory_exhausted", "unsupported_legacy_stage"]:
		return lowered
	if lowered.find("gpu_backend_unavailable") != -1 or lowered.find("rendering_server_unavailable") != -1 or lowered.find("device_create_failed") != -1 or lowered.find("core_unavailable") != -1:
		return "gpu_unavailable"
	if lowered.find("cpu_fallback") != -1 or lowered.find("backend_required") != -1:
		return "gpu_required"
	if lowered.find("readback") != -1:
		return "readback_invalid"
	if lowered.find("buffer_create_failed") != -1:
		return "memory_exhausted"
	if lowered.find("metadata_overflow") != -1 or lowered.find("invalid_") != -1 or lowered.find("missing") != -1:
		return "descriptor_invalid"
	if lowered.find("dispatch") != -1 or lowered.find("shader") != -1 or lowered.find("pipeline") != -1 or lowered.find("uniform_set") != -1 or lowered.find("compute_") != -1:
		return "dispatch_failed"
	return fallback_code
