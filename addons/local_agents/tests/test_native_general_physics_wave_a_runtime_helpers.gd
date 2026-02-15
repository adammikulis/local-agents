@tool
extends RefCounted

const CFG := preload("res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime_constants.gd")

func _extract_payload_with_fallback(payloads: Array, payload_key: String, default_value: Variant = null) -> Variant:
	for payload_variant in payloads:
		if payload_variant == null:
			continue
		if typeof(payload_variant) != TYPE_DICTIONARY:
			if payload_variant is Array || payload_variant is PackedStringArray:
				for nested_payload in payload_variant:
					var nested_payload_value = _extract_payload_with_fallback([nested_payload], payload_key, null)
					if nested_payload_value != null:
						return nested_payload_value
			continue
		var payload: Dictionary = payload_variant as Dictionary
		if payload.has(payload_key):
			var payload_value = payload.get(payload_key, null)
			if payload_value != null:
				return payload_value
		var nested_payload := _extract_nested_pipeline_payload(payload)
		if nested_payload != payload && nested_payload.has(payload_key):
			var nested_payload_value = nested_payload.get(payload_key, null)
			if nested_payload_value != null:
				return nested_payload_value
	return default_value

func _is_pipeline_payload_summary_like(payload: Dictionary) -> bool:
	if payload.size() == 0:
		return false
	return (payload.has("pipeline") && payload.get("pipeline") is Dictionary) || (
		(payload.has("result") && payload.get("result") is Dictionary) ||
		(payload.has("summary") && payload.get("summary") is Dictionary) ||
		(payload.has("payload") && payload.get("payload") is Dictionary) ||
		(payload.has("value") && payload.get("value") is Dictionary)
	)

func _extract_nested_pipeline_payload(payload_variant: Variant) -> Dictionary:
	if typeof(payload_variant) != TYPE_DICTIONARY:
		return {}
	var payload: Dictionary = payload_variant as Dictionary
	if payload.has("pipeline") && payload.get("pipeline") is Dictionary:
		return _extract_nested_pipeline_payload(payload.get("pipeline"))
	if payload.has("pipeline") && payload.get("pipeline") is Array:
		var pipeline_container := payload.get("pipeline")
		var pipeline_payload = _first_dictionary_in_container(pipeline_container)
		if pipeline_payload is Dictionary:
			return _extract_nested_pipeline_payload(pipeline_payload)
	if not _is_pipeline_payload_summary_like(payload):
		return payload
	for candidate_key in ["result", "summary", "payload", "value"]:
		var candidate = payload.get(candidate_key)
		if candidate is Dictionary:
			return _extract_nested_pipeline_payload(candidate)
		if candidate is Array:
			var candidate_payload = _first_dictionary_in_container(candidate)
			if candidate_payload is Dictionary:
				return _extract_nested_pipeline_payload(candidate_payload)
	return payload

func _extract_pipeline_payload(step_result: Dictionary) -> Dictionary:
	var pipeline_root = _extract_payload_with_fallback([step_result], "pipeline", {})
	if not (pipeline_root is Dictionary):
		if pipeline_root is Array:
			var pipeline_payload = _first_dictionary_in_container(pipeline_root)
			if pipeline_payload is Dictionary:
				return _extract_nested_pipeline_payload(pipeline_payload)
		if _is_pipeline_payload_summary_like(step_result):
			return _extract_nested_pipeline_payload(step_result)
		return {}
	return _extract_nested_pipeline_payload(pipeline_root)

func _first_dictionary_in_container(values_variant: Variant) -> Variant:
	if values_variant is Dictionary:
		return values_variant
	if values_variant is Array:
		for value in values_variant:
			if value is Dictionary:
				return value
			var nested_dictionary = _first_dictionary_in_container(value)
			if nested_dictionary is Dictionary:
				return nested_dictionary
	return {}

func _coerce_dictionary_payload(payload_variant: Variant, default_value: Dictionary = {}) -> Dictionary:
	if payload_variant is Dictionary:
		return _extract_nested_pipeline_payload(payload_variant)
	var payload_dictionary := _first_dictionary_in_container(payload_variant)
	if payload_dictionary is Dictionary:
		return _extract_nested_pipeline_payload(payload_dictionary)
	return default_value

func _coerce_scalar_float(value: Variant, default_value: float = 0.0) -> float:
	if value is int || value is float:
		return float(value)
	if value is String:
		return float(value)
	if value is Dictionary:
		var nested_value = _extract_payload_with_fallback([value], "value", null)
		if nested_value != null:
			return _coerce_scalar_float(nested_value, default_value)
	if value is Array:
		if value.size() == 0:
			return default_value
		var first_value = value[0]
		return _coerce_scalar_float(first_value, default_value)
	if value is PackedFloat32Array || value is PackedFloat64Array || value is PackedInt32Array || value is PackedInt64Array:
		if value.size() == 0:
			return default_value
		return float(value[0])
	return default_value

func _coerce_numeric_array(values: Variant) -> Array:
	var output: Array = []
	if values is Array:
		for value in values:
			if value is int || value is float:
				output.append(float(value))
			else:
				return []
		return output
	if values is PackedFloat32Array || values is PackedFloat64Array || values is PackedInt32Array || values is PackedInt64Array:
		output.resize(values.size())
		for index in range(values.size()):
			output[index] = float(values[index])
		return output
	return []

func _sum_numeric_array(values: Variant) -> float:
	var values_array := _coerce_numeric_array(values)
	var total := 0.0
	for value in values_array:
		total += float(value)
	return total

func _mean_numeric_array(values: Variant) -> float:
	var values_array := _coerce_numeric_array(values)
	var count := float(values_array.size())
	if count == 0.0:
		return 0.0
	return _sum_numeric_array(values_array) / count

func _assert_numeric_array_sum_equivalence(lhs_values: Variant, rhs_values: Variant, tolerance: float = 1.0e-12) -> bool:
	if not _is_numeric_array(lhs_values):
		return _assert(false, "Numeric-array aggregate comparison requires a numeric lhs array.")
	if not _is_numeric_array(rhs_values):
		return _assert(false, "Numeric-array aggregate comparison requires a numeric rhs array.")
	var lhs_sum := _sum_numeric_array(lhs_values)
	var rhs_sum := _sum_numeric_array(rhs_values)
	return _assert(abs(lhs_sum - rhs_sum) <= tolerance, "Numeric-array aggregate sums should match within tolerance.")

func _assert_numeric_array_sum_and_mean_equivalence(lhs_values: Variant, rhs_values: Variant, tolerance: float = 1.0e-12) -> bool:
	if not _is_numeric_array(lhs_values):
		return _assert(false, "Numeric-array aggregate comparison requires a numeric lhs array.")
	if not _is_numeric_array(rhs_values):
		return _assert(false, "Numeric-array aggregate comparison requires a numeric rhs array.")
	var lhs_sum := _sum_numeric_array(lhs_values)
	var rhs_sum := _sum_numeric_array(rhs_values)
	var lhs_mean := _mean_numeric_array(lhs_values)
	var rhs_mean := _mean_numeric_array(rhs_values)
	var sums_match: bool = abs(lhs_sum - rhs_sum) <= tolerance
	var means_match: bool = abs(lhs_mean - rhs_mean) <= tolerance
	return _assert(sums_match && means_match, "Numeric-array aggregate sums and means should match within tolerance.")

func _is_numeric_array(values: Variant) -> bool:
	if values is Array:
		for value in values:
			if not (value is int || value is float):
				return false
		return true
	if values is PackedFloat32Array || values is PackedFloat64Array || values is PackedInt32Array || values is PackedInt64Array:
		return true
	return false

func _normalize_handle_ref(raw_handle: Variant) -> String:
	if raw_handle is String:
		var normalized := String(raw_handle).strip_edges()
		if normalized.begins_with("field::"):
			normalized = normalized.substr(7)
		if normalized.ends_with("_field"):
			normalized = normalized.substr(0, normalized.length() - 6)
		return normalized
	if raw_handle is Dictionary:
		for candidate_key in ["handle_id", "resolved_handle", "resolved_handle_ref", "id", "handle", "value", "ref"]:
			if raw_handle.has(candidate_key):
				var nested_handle = _normalize_handle_ref(raw_handle.get(candidate_key))
				if nested_handle != "":
					return nested_handle
		return ""
	if raw_handle is Array:
		for item in raw_handle:
			var nested_handle = _normalize_handle_ref(item)
			if nested_handle != "":
				return nested_handle
		return ""
	return ""

func _assert_hot_field_resolution(
	diagnostics: Dictionary,
	field_names: Array,
	expected_resolved: bool,
	expected_resolved_via_handle: bool,
	expected_fallback_used: bool,
	expected_mode: String,
	expected_fallback_reason: String,
	expected_resolved_source: String = ""
) -> bool:
	var ok := true
	for field_name in field_names:
		if typeof(field_name) != TYPE_STRING:
			continue
		var field_diag: Dictionary = diagnostics.get(field_name, {})
		if not _assert(typeof(field_diag) == TYPE_DICTIONARY, "Hot stage diagnostics should include '%s' entry." % String(field_name)):
			ok = false
			continue
		ok = _assert(bool(field_diag.get("resolved_via_handle", false)) == expected_resolved_via_handle, "Hot field '%s' should%s report resolved_via_handle = %s." % [String(field_name), " " if expected_resolved_via_handle else " not", str(expected_resolved_via_handle)]) and ok
		ok = _assert(bool(field_diag.get("fallback_used", false)) == expected_fallback_used, "Hot field '%s' should%s report fallback_used = %s." % [String(field_name), " " if expected_fallback_used else " not", str(expected_fallback_used)]) and ok
		ok = _assert(String(field_diag.get("mode", "")) == expected_mode, "Hot field '%s' mode should be '%s' when deterministic fallback behavior is exercised." % [String(field_name), expected_mode]) and ok
		ok = _assert(bool(field_diag.get("resolved", false)) == expected_resolved, "Hot field '%s' should%s resolve in stage inputs." % [String(field_name), " " if expected_resolved else " not"]) and ok
		if expected_fallback_reason != "":
			ok = _assert(String(field_diag.get("fallback_reason", "")) == expected_fallback_reason, "Hot field '%s' fallback reason should be '%s'." % [String(field_name), expected_fallback_reason]) and ok
		if expected_resolved_source != "":
			ok = _assert(String(field_diag.get("resolved_source", "")) == expected_resolved_source, "Hot field '%s' resolved source should be '%s'." % [String(field_name), expected_resolved_source]) and ok
	return ok

func _assert_hot_handle_field_diagnostics(
	diagnostics: Dictionary,
	field_names: Array,
	expected_resolved_source: String,
	expected_handle_refs: Dictionary
) -> bool:
	var ok := true
	for field_name in field_names:
		if typeof(field_name) != TYPE_STRING:
			continue
		var field_diag: Dictionary = diagnostics.get(field_name, {})
		if not _assert(typeof(field_diag) == TYPE_DICTIONARY, "Hot handle diagnostics should include '%s' entry." % String(field_name)):
			ok = false
			continue
		ok = _assert(bool(field_diag.get("resolved", false)), "Hot handle field '%s' should resolve through handle mode." % String(field_name)) and ok
		ok = _assert(bool(field_diag.get("resolved_via_handle", false)), "Hot handle field '%s' should report resolved_via_handle=true." % String(field_name)) and ok
		ok = _assert(not bool(field_diag.get("fallback_used", false)), "Hot handle field '%s' should not use fallback while compatibility gate is off." % String(field_name)) and ok
		ok = _assert(String(field_diag.get("mode", "")) == "handle", "Hot handle field '%s' should be in handle mode." % String(field_name)) and ok
		ok = _assert(String(field_diag.get("fallback_reason", "")) == "", "Hot handle field '%s' should not expose fallback_reason." % String(field_name)) and ok
		ok = _assert(String(field_diag.get("resolved_source", "")) == expected_resolved_source, "Hot handle field '%s' should resolve from '%s'." % [String(field_name), expected_resolved_source]) and ok
		var expected_handle := _normalize_handle_ref(expected_handle_refs.get(field_name, ""))
		if not expected_handle.is_empty():
			var resolved_handle := _normalize_handle_ref(field_diag.get("resolved_handle", null))
			var resolved_handle_ref := _normalize_handle_ref(field_diag.get("resolved_handle_ref", null))
			ok = _assert(resolved_handle == expected_handle, "Hot handle field '%s' should resolve via expected handle '%s'." % [String(field_name), expected_handle]) and ok
			if resolved_handle_ref.is_empty():
				resolved_handle_ref = resolved_handle
			ok = _assert(resolved_handle_ref == expected_handle, "Hot handle field '%s' should report resolved_handle_ref '%s'." % [String(field_name), expected_handle]) and ok
	return ok

func _extract_field_handle_metadata_value(step_result: Dictionary, metadata_key: String) -> Variant:
	var direct_value: Variant = _extract_payload_with_fallback([step_result], metadata_key, null)
	if direct_value != null:
		return direct_value
	var pipeline_payload: Dictionary = _extract_pipeline_payload(step_result)
	var metadata_value = _extract_payload_with_fallback([pipeline_payload], metadata_key, null)
	if metadata_value != null:
		return metadata_value
	var summary_payload := _extract_payload_with_fallback([pipeline_payload], "summary", {})
	var result_payload := _extract_payload_with_fallback([pipeline_payload], "result", {})
	var result_summary_payload: Variant = {}
	if result_payload is Dictionary:
		var typed_result_payload: Dictionary = result_payload as Dictionary
		result_summary_payload = _extract_payload_with_fallback([typed_result_payload], "summary", {})
		if result_summary_payload is Dictionary:
			return _extract_payload_with_fallback([summary_payload, result_payload, result_summary_payload], metadata_key, null)
	return _extract_payload_with_fallback([summary_payload, result_payload], metadata_key, null)

func _build_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"mass_field": CFG.BASE_MASS.duplicate(true),
			"pressure_field": CFG.BASE_PRESSURE.duplicate(true),
			"temperature_field": CFG.BASE_TEMPERATURE.duplicate(true),
			"velocity_field": CFG.BASE_VELOCITY.duplicate(true),
			"density_field": CFG.BASE_DENSITY.duplicate(true),
			"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
		}
	}

func _build_transport_neighborhood_payload(topology: Array) -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"mass_field": CFG.TRANSPORT_MASS.duplicate(true),
			"pressure_field": CFG.TRANSPORT_PRESSURE.duplicate(true),
			"temperature_field": CFG.TRANSPORT_TEMPERATURE.duplicate(true),
			"velocity_field": CFG.TRANSPORT_VELOCITY.duplicate(true),
			"density_field": CFG.TRANSPORT_DENSITY.duplicate(true),
			"neighbor_topology": topology.duplicate(true),
		}
	}

func _build_handle_first_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"field_handles": [
				"field::mass_density",
				"pressure_field",
				{"handle_id":"field::momentum_x"},
				{"handle_id":"field::temperature_field"},
				"density_field",
			],
			"field_buffers": {
				"mass": [1000.0, 1000.0],
				"pressure": [150.0, 150.0],
				"temperature": [310.0, 310.0],
				"velocity": [0.25, 0.25],
				"density": [1.1, 1.2],
				"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
			},
			"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
		}
	}

func _build_handle_chain_payload() -> Dictionary:
	var payload := _build_handle_first_payload()
	var inputs: Dictionary = payload.get("inputs", Dictionary())
	if typeof(inputs) == TYPE_DICTIONARY:
		inputs = inputs.duplicate(true)
		inputs.erase("field_buffers")
		payload["inputs"] = inputs
	return payload

func _build_missing_handles_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"field_handles": ["invalid_mass_handle", "invalid_pressure_handle", "invalid_velocity_handle"],
			"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
		}
	}

func _build_scalar_compat_fallback_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"compatibility_mode": true,
			"field_handles": ["invalid_mass_handle", "invalid_pressure_handle", "invalid_velocity_handle"],
			"mass": 12.5,
			"pressure": 120.0,
			"temperature": 300.0,
			"velocity": 1.0,
			"density": 1.15,
			"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
		}
	}

func _extract_stage_field_input_diagnostics(step_result: Dictionary) -> Dictionary:
	var pipeline: Dictionary = _extract_pipeline_payload(step_result)
	if pipeline.is_empty():
		push_error("Wave-A continuity step result missing pipeline payload.")
		return {}
	var diagnostics = _extract_payload_with_fallback([pipeline], "stage_field_input_diagnostics", {})
	if typeof(diagnostics) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing stage_field_input_diagnostics payload.")
		return {}
	return diagnostics as Dictionary

func _extract_field_evolution_handle_resolution_diagnostics(step_result: Dictionary) -> Dictionary:
	var pipeline: Dictionary = _extract_pipeline_payload(step_result)
	if pipeline.is_empty():
		push_error("Wave-A continuity step result missing pipeline payload.")
		return {}
	var field_evolution = _extract_payload_with_fallback([pipeline], "field_evolution", {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return {}
	var diagnostics = _extract_payload_with_fallback([field_evolution], "handle_resolution_diagnostics", {})
	if typeof(diagnostics) != TYPE_DICTIONARY:
		push_error("Wave-A continuity field_evolution missing handle_resolution_diagnostics payload.")
		return {}
	return diagnostics as Dictionary

func _assert_summary_key_set_stability(reference: Dictionary, candidate: Dictionary, allowed_extra: Array) -> bool:
	var missing: Array = []
	var extra: Array = []
	var reference_keys := _sorted_keys(reference)
	var candidate_keys := _sorted_keys(candidate)
	for reference_key in reference_keys:
		if candidate_keys.find(reference_key) < 0:
			missing.append(reference_key)
	for candidate_key in candidate_keys:
		if reference_keys.find(candidate_key) < 0 && allowed_extra.find(candidate_key) < 0:
			extra.append(candidate_key)
	if missing.size() > 0:
		return _assert(false, "Summary missing required keys vs reference baseline: %s" % str(missing))
	if extra.size() > 0:
		return _assert(false, "Summary contains unexpected keys not in baseline or allowlist: %s" % str(extra))
	return true

func _sorted_keys(source: Dictionary) -> Array:
	var keys: Array = source.keys()
	keys.sort()
	return keys

func _has_scalar_fallback_used(diagnostics: Dictionary) -> bool:
	var hot_fields := ["mass", "velocity", "pressure", "temperature", "density"]
	for field_name in hot_fields:
		var field_diag: Dictionary = diagnostics.get(field_name, {})
		if typeof(field_diag) != TYPE_DICTIONARY:
			continue
		if bool(field_diag.get("fallback_used", false)):
			var reason := String(field_diag.get("fallback_reason", ""))
			if reason.find("fallback") >= 0:
				return true
	return false

func _build_override_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"field_buffers": {
				"mass": [1000.0, 1000.0],
				"pressure": [150.0, 150.0],
				"temperature": [310.0, 310.0],
				"velocity": [0.25, 0.25],
				"density": [1.1, 1.2],
				"neighbor_topology": CFG.BASE_TOPOLOGY.duplicate(true),
			},
		}
	}

func _extract_updated_mass(step_result: Dictionary) -> Array:
	var pipeline: Dictionary = _extract_pipeline_payload(step_result)
	if pipeline.is_empty():
		push_error("Wave-A continuity step result missing pipeline payload.")
		return []
	var field_evolution = _coerce_dictionary_payload(_extract_payload_with_fallback([pipeline], "field_evolution", {}), {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return []
	var updated_fields = _coerce_dictionary_payload(_extract_payload_with_fallback([field_evolution], "updated_fields", {}), {})
	if typeof(updated_fields) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing updated_fields payload.")
		return []
	var mass_variant = _coerce_numeric_array(updated_fields.get("mass", []))
	if mass_variant.is_empty():
		push_error("Wave-A continuity step result missing updated mass field array.")
		return []
	return mass_variant

func _extract_transport_pair_summary(step_result: Dictionary) -> Dictionary:
	var result := {}
	var pipeline: Dictionary = _extract_pipeline_payload(step_result)
	if pipeline.is_empty():
		push_error("Wave-A continuity step result missing pipeline payload.")
		return result
	var field_evolution = _coerce_dictionary_payload(_extract_payload_with_fallback([pipeline], "field_evolution", {}), {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return result
	var updated_fields = _coerce_dictionary_payload(_extract_payload_with_fallback([field_evolution], "updated_fields", {}), {})
	if typeof(updated_fields) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing updated_fields payload.")
		return result
	result["pair_updates"] = int(_extract_payload_with_fallback([field_evolution], "pair_updates", -1))
	result["mass"] = _coerce_numeric_array(updated_fields.get("mass", []))
	result["pressure"] = _coerce_numeric_array(updated_fields.get("pressure", []))
	result["temperature"] = _coerce_numeric_array(updated_fields.get("temperature", []))
	result["velocity"] = _coerce_numeric_array(updated_fields.get("velocity", []))
	result["density"] = _coerce_numeric_array(updated_fields.get("density", []))
	return result

func _assert_transport_payload_equivalence(
	lhs_result: Dictionary,
	rhs_result: Dictionary,
	tolerance: float = 1.0e-12
) -> bool:
	var lhs := _extract_transport_pair_summary(lhs_result)
	var rhs := _extract_transport_pair_summary(rhs_result)
	if not _assert(typeof(lhs) == TYPE_DICTIONARY && typeof(rhs) == TYPE_DICTIONARY, "Transport payload extraction must succeed on both steps."):
		return false

	var key_set_fields := ["mass", "pressure", "temperature", "velocity", "density", "pair_updates"]
	var summary_fields := ["mass", "pressure", "temperature", "density", "pair_updates"]
	var lhs_keys := _sorted_keys(lhs)
	var rhs_keys := _sorted_keys(rhs)
	for key in key_set_fields:
		if lhs_keys.find(key) < 0:
			return _assert(false, "Transport summary missing key '%s' in baseline result." % String(key))
		if rhs_keys.find(key) < 0:
			return _assert(false, "Transport summary missing key '%s' in permuted-result comparison." % String(key))
	for key in lhs_keys:
		if rhs_keys.find(key) < 0:
			return _assert(false, "Transport summary exposes unexpected key '%s' in baseline result." % String(key))
	for key in rhs_keys:
		if lhs_keys.find(key) < 0:
			return _assert(false, "Transport summary exposes unexpected key '%s' in permuted result." % String(key))
	var ok := true
	ok = _assert(int(lhs["pair_updates"]) == int(rhs["pair_updates"]), "Pair update count should remain invariant under neighbor ordering changes.") and ok
	for key in summary_fields:
		if key == "pair_updates":
			continue
		var lhs_values_variant = lhs.get(key, [])
		var rhs_values_variant = rhs.get(key, [])
		ok = _assert(_is_numeric_array(lhs_values_variant), "Transport summary field '%s' should be a numeric array in baseline result." % key) and ok
		ok = _assert(_is_numeric_array(rhs_values_variant), "Transport summary field '%s' should be a numeric array in permuted result." % key) and ok
		ok = _assert(_assert_numeric_array_sum_equivalence(lhs_values_variant, rhs_values_variant, tolerance),
			"Transport field '%s' should preserve aggregate value under neighbor ordering permutation." % key) and ok
	return ok

func _assert_transport_invalid_edge_regression(
	lhs_result: Dictionary,
	rhs_result: Dictionary,
	expected_pair_updates: int,
	tolerance: float = 1.0e-12
) -> bool:
	var lhs := _extract_transport_pair_summary(lhs_result)
	var rhs := _extract_transport_pair_summary(rhs_result)
	if not _assert(typeof(lhs) == TYPE_DICTIONARY && typeof(rhs) == TYPE_DICTIONARY, "Transport payload extraction must succeed for invalid-edge regression."):
		return false

	var ok := _assert_transport_payload_equivalence(lhs_result, rhs_result, tolerance)
	var lhs_pair_updates := int(lhs.get("pair_updates", -1))
	var rhs_pair_updates := int(rhs.get("pair_updates", -1))
	ok = _assert(lhs_pair_updates == rhs_pair_updates, "Invalid-edge regression should report identical pair update counts.") and ok
	ok = _assert(lhs_pair_updates == expected_pair_updates, "Invalid-edge regression should skip out-of-range topology entries and only update valid neighbor pairs.") and ok
	ok = _assert(_transport_fields_are_finite(lhs), "Invalid-edge regression should not emit NaN values in transport result.") and ok
	ok = _assert(_transport_fields_are_finite(rhs), "Invalid-edge regression should not emit NaN values in transport result.") and ok
	return ok

func _transport_fields_are_finite(summary: Dictionary) -> bool:
	const summary_fields := ["mass", "pressure", "temperature", "velocity", "density"]
	var ok := true
	for key in summary_fields:
		var values = summary.get(key, [])
		if not _assert(_is_numeric_array(values), "Transport summary field '%s' should be a numeric array for finite-value check." % key):
			ok = false
			continue
		for value in _coerce_numeric_array(values):
			var numeric := float(value)
			ok = _assert(numeric == numeric, "Transport summary field '%s' should not contain NaN." % key) and ok
	return ok

func _arrays_equal(lhs: Array, rhs: Array, tolerance: float = 1.0e-12) -> bool:
	if lhs.size() != rhs.size():
		return false
	for i in range(lhs.size()):
		if abs(float(lhs[i]) - float(rhs[i])) > tolerance:
			return false
	return true

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
