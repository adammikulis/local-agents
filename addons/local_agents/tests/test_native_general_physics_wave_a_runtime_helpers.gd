@tool
extends RefCounted

const CFG := preload("res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime_constants.gd")

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
		var expected_handle := String(expected_handle_refs.get(field_name, ""))
		if not expected_handle.is_empty():
			ok = _assert(String(field_diag.get("resolved_handle", "")) == expected_handle, "Hot handle field '%s' should resolve via expected handle '%s'." % [String(field_name), expected_handle]) and ok
			ok = _assert(String(field_diag.get("resolved_handle_ref", "")) == expected_handle, "Hot handle field '%s' should report resolved_handle_ref '%s'." % [String(field_name), expected_handle]) and ok
	return ok

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
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload.")
		return {}
	var diagnostics: Dictionary = pipeline.get("stage_field_input_diagnostics", {})
	if typeof(diagnostics) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing stage_field_input_diagnostics payload.")
		return {}
	return diagnostics

func _extract_field_evolution_handle_resolution_diagnostics(step_result: Dictionary) -> Dictionary:
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload.")
		return {}
	var field_evolution: Dictionary = pipeline.get("field_evolution", {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return {}
	var diagnostics: Dictionary = field_evolution.get("handle_resolution_diagnostics", {})
	if typeof(diagnostics) != TYPE_DICTIONARY:
		push_error("Wave-A continuity field_evolution missing handle_resolution_diagnostics payload.")
		return {}
	return diagnostics

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
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload.")
		return []
	var field_evolution: Dictionary = pipeline.get("field_evolution", {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return []
	var updated_fields: Dictionary = field_evolution.get("updated_fields", {})
	if typeof(updated_fields) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing updated_fields payload.")
		return []
	var mass_variant = updated_fields.get("mass", [])
	if typeof(mass_variant) != TYPE_ARRAY:
		push_error("Wave-A continuity step result missing updated mass field array.")
		return []
	return mass_variant

func _extract_transport_pair_summary(step_result: Dictionary) -> Dictionary:
	var result := {}
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload.")
		return result
	var field_evolution: Dictionary = pipeline.get("field_evolution", {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return result
	var updated_fields: Dictionary = field_evolution.get("updated_fields", {})
	if typeof(updated_fields) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing updated_fields payload.")
		return result
	result["pair_updates"] = int(field_evolution.get("pair_updates", -1))
	result["mass"] = updated_fields.get("mass", [])
	result["pressure"] = updated_fields.get("pressure", [])
	result["temperature"] = updated_fields.get("temperature", [])
	result["velocity"] = updated_fields.get("velocity", [])
	result["density"] = updated_fields.get("density", [])
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

	var summary_fields := ["mass", "pressure", "temperature", "velocity", "density", "pair_updates"]
	var lhs_keys := _sorted_keys(lhs)
	var rhs_keys := _sorted_keys(rhs)
	for key in summary_fields:
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
		var lhs_values = lhs.get(key, [])
		var rhs_values = rhs.get(key, [])
		ok = _assert(typeof(lhs_values) == TYPE_ARRAY, "Transport summary field '%s' should be an array in baseline result." % key) and ok
		ok = _assert(typeof(rhs_values) == TYPE_ARRAY, "Transport summary field '%s' should be an array in permuted result." % key) and ok
		ok = _assert(_arrays_equal(lhs_values, rhs_values, tolerance), "Transport field '%s' should be identical under neighbor ordering permutation." % key) and ok
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
		if not _assert(typeof(values) == TYPE_ARRAY, "Transport summary field '%s' should be an array for finite-value check." % key):
			ok = false
			continue
		for value in values:
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
