@tool
extends "res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime_helpers.gd"


func _test_wave_b_regression_scenarios(core: Object) -> bool:
	var ok := true
	var fields := ["mass", "pressure", "temperature", "velocity", "density"]
	for scenario_tag in CFG.WAVE_B_REGRESSION_SCENARIO_ORDER:
		core.call("reset")
		var payload := _build_wave_b_regression_payload(scenario_tag)
		var first_results := _execute_wave_b_payload_steps(core, payload, CFG.WAVE_B_REGRESSION_STEPS)
		core.call("reset")
		var second_results := _execute_wave_b_payload_steps(core, payload, CFG.WAVE_B_REGRESSION_STEPS)
		if first_results.size() != CFG.WAVE_B_REGRESSION_STEPS or second_results.size() != CFG.WAVE_B_REGRESSION_STEPS:
			ok = _assert(false, "Row-260 scenario '%s' did not produce the expected number of steps." % String(scenario_tag)) and ok
			continue
		for step_index in range(CFG.WAVE_B_REGRESSION_STEPS):
			var lhs: Dictionary = first_results[step_index]
			var rhs: Dictionary = second_results[step_index]
			ok = _assert(_assert_wave_b_result_finite(lhs, scenario_tag, step_index), "Row-260 scenario '%s' step %d should contain finite updated fields and summary numerics." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_wave_b_result_finite(rhs, scenario_tag, step_index), "Row-260 scenario '%s' replay step %d should contain finite updated fields and summary numerics." % [String(scenario_tag), step_index]) and ok
			var lhs_pipeline: Dictionary = _extract_pipeline_payload(lhs)
			var rhs_pipeline: Dictionary = _extract_pipeline_payload(rhs)
			if not _assert(lhs_pipeline is Dictionary, "Row-260 scenario '%s' step %d should expose a pipeline result." % [String(scenario_tag), step_index]):
				continue
			if not _assert(rhs_pipeline is Dictionary, "Row-260 scenario '%s' replay step %d should expose a pipeline result." % [String(scenario_tag), step_index]):
				continue
			var lhs_field_evolution = _extract_payload_with_fallback([lhs_pipeline], "field_evolution", {})
			var rhs_field_evolution = _extract_payload_with_fallback([rhs_pipeline], "field_evolution", {})
			ok = _assert(lhs_field_evolution is Dictionary, "Row-260 scenario '%s' step %d should expose a field_evolution result." % [String(scenario_tag), step_index]) and ok
			ok = _assert(rhs_field_evolution is Dictionary, "Row-260 scenario '%s' replay step %d should expose a field_evolution result." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_summary_key_set_stability(lhs, rhs, []) and _assert_summary_key_set_stability(rhs, lhs, []), "Row-260 scenario '%s' step %d should preserve summary key stability across payload replay." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_summary_key_set_stability(lhs_pipeline, rhs_pipeline, []) and _assert_summary_key_set_stability(rhs_pipeline, lhs_pipeline, []), "Row-260 scenario '%s' step %d should preserve pipeline key stability across payload replay." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_summary_key_set_stability(lhs_field_evolution, rhs_field_evolution, []) and _assert_summary_key_set_stability(rhs_field_evolution, lhs_field_evolution, []), "Row-260 scenario '%s' step %d should preserve field_evolution key stability across payload replay." % [String(scenario_tag), step_index]) and ok
			var lhs_pair := _extract_transport_pair_summary(lhs)
			var rhs_pair := _extract_transport_pair_summary(rhs)
			ok = _assert(lhs_pair.size() == rhs_pair.size(), "Row-260 scenario '%s' step %d should expose matching pair summary payload fields." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_summary_key_set_stability(lhs_pair, rhs_pair, []) and _assert_summary_key_set_stability(rhs_pair, lhs_pair, []), "Row-260 scenario '%s' step %d should preserve pair summary key stability across payload replay." % [String(scenario_tag), step_index]) and ok
			for field in fields:
				var lhs_values = lhs_pair.get(field, [])
				var rhs_values = rhs_pair.get(field, [])
				ok = _assert(lhs_values is Array or lhs_values is PackedFloat32Array or lhs_values is PackedFloat64Array, "Row-260 scenario '%s' step %d should expose updated field '%s' array." % [String(scenario_tag), step_index, field]) and ok
				ok = _assert(rhs_values is Array or rhs_values is PackedFloat32Array or rhs_values is PackedFloat64Array, "Row-260 replay scenario '%s' step %d should expose updated field '%s' array." % [String(scenario_tag), step_index, field]) and ok
				ok = _assert(_arrays_equal(lhs_values, rhs_values, 1.0e-12), "Row-260 scenario '%s' step %d should be deterministic for field '%s'." % [String(scenario_tag), step_index, field]) and ok
				ok = _assert(_arrays_are_finite(lhs_values, "Wave-B scenario %s step %d field %s" % [String(scenario_tag), step_index, field]), "Row-260 scenario '%s' step %d field '%s' should not contain non-finite values." % [String(scenario_tag), step_index, field]) and ok
				ok = _assert(_arrays_are_finite(rhs_values, "Row-260 scenario %s replay step %d field %s" % [String(scenario_tag), step_index, field]), "Row-260 replay scenario '%s' step %d field '%s' should not contain non-finite values." % [String(scenario_tag), step_index, field]) and ok
			ok = _assert(_assert_transport_pair_value(lhs_pair, "pair_updates"), "Row-260 scenario '%s' step %d should expose pair_updates for comparison." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_transport_pair_value(rhs_pair, "pair_updates"), "Row-260 replay scenario '%s' step %d should expose pair_updates for comparison." % [String(scenario_tag), step_index]) and ok
			ok = _assert(int(lhs_pair.get("pair_updates", -1)) == int(rhs_pair.get("pair_updates", -1)), "Row-260 scenario '%s' step %d should produce finite identical pair_updates." % [String(scenario_tag), step_index]) and ok
			var lhs_mass_drift = _coerce_float(_extract_payload_with_fallback([lhs_pipeline], "field_mass_drift_proxy", 0.0))
			var rhs_mass_drift = _coerce_float(_extract_payload_with_fallback([rhs_pipeline], "field_mass_drift_proxy", 0.0))
			var lhs_energy_drift = _coerce_float(_extract_payload_with_fallback([lhs_pipeline], "field_energy_drift_proxy", 0.0))
			var rhs_energy_drift = _coerce_float(_extract_payload_with_fallback([rhs_pipeline], "field_energy_drift_proxy", 0.0))
			ok = _assert(_is_scalar_finite(lhs_mass_drift, "scenario=%s step=%d mass_drift_proxy" % [String(scenario_tag), step_index]), "Row-260 scenario '%s' step %d should expose finite field_mass_drift_proxy." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_is_scalar_finite(rhs_mass_drift, "scenario=%s replay step=%d mass_drift_proxy" % [String(scenario_tag), step_index]), "Row-260 replay scenario '%s' step %d should expose finite field_mass_drift_proxy." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_is_scalar_finite(lhs_energy_drift, "scenario=%s step=%d energy_drift_proxy" % [String(scenario_tag), step_index]), "Row-260 scenario '%s' step %d should expose finite field_energy_drift_proxy." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_is_scalar_finite(rhs_energy_drift, "scenario=%s replay step=%d energy_drift_proxy" % [String(scenario_tag), step_index]), "Row-260 replay scenario '%s' step %d should expose finite field_energy_drift_proxy." % [String(scenario_tag), step_index]) and ok
			ok = _assert(abs(lhs_mass_drift - rhs_mass_drift) <= 1.0e-12, "Row-260 scenario '%s' step %d should replay identical field_mass_drift_proxy." % [String(scenario_tag), step_index]) and ok
			ok = _assert(abs(lhs_energy_drift - rhs_energy_drift) <= 1.0e-12, "Row-260 scenario '%s' step %d should replay identical field_energy_drift_proxy." % [String(scenario_tag), step_index]) and ok
	return ok

func _test_repeated_load_terrain_stability(core: Object) -> bool:
	var payload := _build_wave_b_regression_payload("impact")
	core.call("reset")
	var no_reset_results := _execute_wave_b_payload_steps(core, payload, CFG.WAVE_B_REPEATED_LOAD_STEPS)
	var previous_step_max := {
		"mass": 0.0,
		"pressure": 0.0,
		"temperature": 0.0,
		"velocity": 0.0,
		"density": 0.0,
	}
	var ok := true
	var fields := ["mass", "pressure", "temperature", "velocity", "density"]
	if no_reset_results.size() != CFG.WAVE_B_REPEATED_LOAD_STEPS:
		return _assert(false, "Row-263 repeated-load check should run exactly %d steps." % CFG.WAVE_B_REPEATED_LOAD_STEPS)
	for result_index in range(no_reset_results.size()):
		var current: Dictionary = no_reset_results[result_index]
		ok = _assert(_assert_wave_b_result_finite(current, "repeated_load", result_index), "Row-263 repeated-load step %d should remain finite." % result_index) and ok
		var pair_summary := _extract_transport_pair_summary(current)
		var current_step_max := {
			"mass": 0.0,
			"pressure": 0.0,
			"temperature": 0.0,
			"velocity": 0.0,
			"density": 0.0,
		}
		for field in fields:
			var values := pair_summary.get(field, [])
			ok = _assert(values is Array or values is PackedFloat32Array or values is PackedFloat64Array, "Row-263 repeated-load step %d field '%s' should expose numeric payload." % [result_index, field]) and ok
			ok = _assert(_arrays_are_finite(values, "repeated_load step_%d %s" % [result_index, field]), "Row-263 repeated-load step %d should keep updated field '%s' finite." % [result_index, field]) and ok
			var max_abs := _max_abs_float_array(values)
			current_step_max[field] = max_abs
			ok = _assert(max_abs < CFG.WAVE_B_FIELD_ABS_CAP, "Row-263 repeated-load step %d field '%s' should stay within numeric cap." % [result_index, field]) and ok
		if result_index > 0:
			var prior_summary := _extract_transport_pair_summary(no_reset_results[result_index - 1])
			for field in fields:
				var previous_max := float(previous_step_max.get(field, 0.0))
				var current_max := float(current_step_max.get(field, 0.0))
				var growth_limit := max(previous_max * CFG.WAVE_B_FIELD_GROWTH_FACTOR, 1.0)
				ok = _assert(current_max <= growth_limit, "Row-263 repeated-load should not grow field '%s' explosively from step %d to %d." % [field, result_index - 1, result_index]) and ok
				previous_step_max[field] = max(previous_max, current_max)
			ok = _assert(_assert_summary_key_set_stability(prior_summary, pair_summary, []) and
				_assert_summary_key_set_stability(pair_summary, prior_summary, []),
					"Row-263 repeated-load should preserve pair-summary keys between consecutive steps %d and %d." % [result_index - 1, result_index]) and ok
			var current_pipeline := _extract_pipeline_payload(current)
			for diagnostics_field in ["field_mass_drift_proxy", "field_energy_drift_proxy"]:
				var drift_value = 0.0
				if current_pipeline is Dictionary:
					drift_value = float(_extract_payload_with_fallback([current_pipeline], diagnostics_field, 0.0))
				ok = _assert(_is_scalar_finite(drift_value, "repeated_load step=%d %s" % [result_index, diagnostics_field]),
					"Row-263 repeated-load summary %s should remain finite at step %d." % [diagnostics_field, result_index]) and ok
				ok = _assert(abs(drift_value) <= CFG.WAVE_B_FIELD_ABS_CAP, "Row-263 repeated-load summary %s should remain bounded at step %d." % [diagnostics_field, result_index]) and ok
		# Replay after reset and verify deterministic coherence per step.
		core.call("reset")
		var replay_results := _execute_wave_b_payload_steps(core, payload, CFG.WAVE_B_REPEATED_LOAD_STEPS)
		if not _assert(replay_results.size() == no_reset_results.size(), "Row-263 repeated-load replay should preserve step count."):
			return false
		for replay_index in range(no_reset_results.size()):
			var original: Dictionary = no_reset_results[replay_index]
			var replayed: Dictionary = replay_results[replay_index]
			ok = _assert_wave_b_result_finite(replayed, "repeated_load_replay", replay_index) and ok
			var original_pair := _extract_transport_pair_summary(original)
			var replay_pair := _extract_transport_pair_summary(replayed)
			ok = _assert(_assert_summary_key_set_stability(original_pair, replay_pair, []) and _assert_summary_key_set_stability(replay_pair, original_pair, []), "Row-263 repeated-load replay should preserve summary key set at step %d." % replay_index) and ok
			for field in fields:
				ok = _assert(_arrays_equal(original_pair.get(field, []), replay_pair.get(field, []), 1.0e-12),
					"Row-263 repeated-load replay should match original field '%s' at step %d." % [field, replay_index] ) and ok
			ok = _assert(int(original_pair.get("pair_updates", -1)) == int(replay_pair.get("pair_updates", -1)),
				"Row-263 repeated-load replay should match pair_updates at step %d." % replay_index) and ok
			return ok
	return ok

func _build_wave_b_regression_payload(scenario_tag: String) -> Dictionary:
	var payload := {
		"delta": 1.0,
		"inputs": {
			"mass_field": CFG.WAVE_B_BASE_MASS.duplicate(true),
			"pressure_field": CFG.WAVE_B_BASE_PRESSURE.duplicate(true),
			"temperature_field": CFG.WAVE_B_BASE_TEMPERATURE.duplicate(true),
			"velocity_field": CFG.WAVE_B_BASE_VELOCITY.duplicate(true),
			"density_field": CFG.WAVE_B_BASE_DENSITY.duplicate(true),
			"neighbor_topology": CFG.WAVE_B_BASE_TOPOLOGY.duplicate(true),
		}
	}
	var scenario_overrides := CFG.WAVE_B_SCENARIO_EXTRA_INPUTS.get(scenario_tag, {})
	if scenario_overrides is Dictionary:
		for key in scenario_overrides.keys():
			var override_value = scenario_overrides.get(key)
			if override_value is Array || override_value is Dictionary:
				payload["inputs"][key] = override_value.duplicate(true)
			else:
				payload["inputs"][key] = override_value
	return payload

func _execute_wave_b_payload_steps(core: Object, payload: Dictionary, steps: int) -> Array:
	var results: Array = []
	for _i in range(steps):
		results.append(core.call("execute_environment_stage", CFG.PIPELINE_STAGE_NAME, payload.duplicate(true)))
	return results

func _assert_physics_server_feedback_contract(step_result: Dictionary, scenario_name: String, step_index: int) -> bool:
	var ok := true
	var feedback = _extract_payload_with_fallback([step_result], "physics_server_feedback", {})
	var pipeline = _extract_pipeline_payload(step_result)
	if not (feedback is Dictionary) or feedback.is_empty():
		feedback = _extract_payload_with_fallback([pipeline], "physics_server_feedback", {})
	if not _assert(feedback is Dictionary, "Wave-B scenario '%s' step %d should include a top-level physics_server_feedback dictionary." % [scenario_name, step_index]):
		return false
	if not _assert(pipeline is Dictionary, "Wave-B scenario '%s' step %d should include a pipeline dictionary for physics-server feedback verification." % [scenario_name, step_index]):
		return false
	var pipeline_feedback: Dictionary = _extract_payload_with_fallback([pipeline], "physics_server_feedback", {})
	if _assert(pipeline_feedback is Dictionary, "Wave-B scenario '%s' step %d should include pipeline.physics_server_feedback dictionary." % [scenario_name, step_index]):
		ok = _assert(String(feedback.get("schema", "")) == String(pipeline_feedback.get("schema", "")), "Physics-server feedback schema should be consistent between result root and pipeline payload.") and ok
		ok = _assert(bool(feedback.get("enabled", false)) == bool(pipeline_feedback.get("enabled", false)), "Physics-server feedback enabled flag should be consistent between result root and pipeline payload.") and ok
		ok = _assert(int(feedback.get("destruction_feedback_count", -1)) == int(pipeline_feedback.get("destruction_feedback_count", -1)), "Physics-server feedback destruction_feedback_count should be consistent between result root and pipeline payload.") and ok

	for key in ["schema", "destruction_stage_count", "destruction_feedback_count", "has_feedback", "coupling_markers_present"]:
		ok = _assert(feedback.has(key), "Physics-server feedback should expose key '%s'." % key) and ok
	ok = _assert(feedback.has("failure_feedback"), "Physics-server feedback should expose failure_feedback.") and ok
	ok = _assert(feedback.has("failure_source"), "Physics-server feedback should expose failure_source.") and ok
	ok = _assert(feedback.has("voxel_emission"), "Physics-server feedback should expose voxel_emission.") and ok
	ok = _assert(feedback.get("enabled") is bool, "Physics-server feedback should expose enabled as bool.") and ok
	ok = _assert(feedback.get("has_feedback") is bool, "Physics-server feedback should expose has_feedback as bool.") and ok
	ok = _assert(feedback.get("coupling_markers_present") is bool, "Physics-server feedback should expose coupling_markers_present as bool.") and ok
	ok = _assert(_is_scalar_finite(feedback.get("destruction_stage_count", 0.0), "physics_server_feedback.destruction_stage_count"), "Physics-server feedback should expose finite destruction_stage_count.") and ok
	ok = _assert(_is_scalar_finite(feedback.get("destruction_feedback_count", 0.0), "physics_server_feedback.destruction_feedback_count"), "Physics-server feedback should expose finite destruction_feedback_count.") and ok

	var failure_feedback: Dictionary = feedback.get("failure_feedback", {})
	if failure_feedback is Dictionary:
		var failure_feedback_keys := ["status", "reason", "active_stage_count", "watch_stage_count", "dominant_mode", "dominant_stage_index", "active_modes"]
		for key in failure_feedback_keys:
			ok = _assert(failure_feedback.has(key), "Physics-server feedback should expose failure_feedback.%s." % key) and ok
		ok = _assert(failure_feedback.get("status") is String, "failure_feedback.status should be a string.") and ok
		ok = _assert(failure_feedback.get("reason") is String, "failure_feedback.reason should be a string.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("active_stage_count", 0.0), "physics_server_feedback.failure_feedback.active_stage_count"), "failure_feedback.active_stage_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("watch_stage_count", 0.0), "physics_server_feedback.failure_feedback.watch_stage_count"), "failure_feedback.watch_stage_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("dominant_stage_index", 0.0), "physics_server_feedback.failure_feedback.dominant_stage_index"), "failure_feedback.dominant_stage_index should be finite.") and ok
	var failure_source: Dictionary = feedback.get("failure_source", {})
	if failure_source is Dictionary:
		var failure_source_keys := ["source", "status", "reason", "overstress_ratio_max", "active_count", "watch_count"]
		for key in failure_source_keys:
			ok = _assert(failure_source.has(key), "Physics-server feedback should expose failure_source.%s." % key) and ok
		ok = _assert(_is_scalar_finite(failure_source.get("overstress_ratio_max", 0.0), "physics_server_feedback.failure_source.overstress_ratio_max"), "failure_source.overstress_ratio_max should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_source.get("active_count", 0.0), "physics_server_feedback.failure_source.active_count"), "failure_source.active_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_source.get("watch_count", 0.0), "physics_server_feedback.failure_source.watch_count"), "failure_source.watch_count should be finite.") and ok
	var voxel_emission: Dictionary = feedback.get("voxel_emission", {})
	if voxel_emission is Dictionary:
		var voxel_emission_keys := ["status", "reason", "target_domain", "dominant_mode", "active_failure_count", "planned_op_count"]
		for key in voxel_emission_keys:
			ok = _assert(voxel_emission.has(key), "Physics-server feedback should expose voxel_emission.%s." % key) and ok
		ok = _assert(voxel_emission.get("status") is String, "voxel_emission.status should be a string.") and ok
		ok = _assert(voxel_emission.get("reason") is String, "voxel_emission.reason should be a string.") and ok
		ok = _assert(voxel_emission.get("target_domain") is String, "voxel_emission.target_domain should be a string.") and ok
		ok = _assert(_is_scalar_finite(voxel_emission.get("planned_op_count", 0.0), "physics_server_feedback.voxel_emission.planned_op_count"), "voxel_emission.planned_op_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(voxel_emission.get("active_failure_count", 0.0), "physics_server_feedback.voxel_emission.active_failure_count"), "voxel_emission.active_failure_count should be finite.") and ok

	var destruction_feedback: Dictionary = feedback.get("destruction", {})
	if destruction_feedback is Dictionary:
		var required_destruction_metrics := ["mass_loss_total", "damage", "damage_delta_total", "damage_next_total", "friction_force_total", "friction_abs_force_max", "friction_dissipation_total", "fracture_energy_total", "resistance_avg", "resistance_max", "slope_failure_ratio_max"]
		for key in required_destruction_metrics:
			ok = _assert(destruction_feedback.has(key), "Physics-server feedback should expose destruction metric '%s'." % key) and ok
			ok = _assert(_is_scalar_finite(destruction_feedback.get(key, 0.0), "physics_server_feedback.destruction.%s" % key), "Physics-server feedback destruction metric '%s' should be finite." % key) and ok

	var coupling: Dictionary = feedback.get("failure_coupling", {})
	if coupling is Dictionary && coupling.size() > 0:
		var coupling_keys := ["damage_to_voxel_scalar", "pressure_to_mechanics_scalar", "reaction_to_thermal_scalar"]
		var saw_valid_coupling := false
		for key in coupling_keys:
			if coupling.has(key):
				ok = _assert(_is_scalar_finite(coupling.get(key, 0.0), "physics_server_feedback.failure_coupling.%s" % key), "Physics-server feedback should expose failure coupling key '%s' as a finite scalar." % key) and ok
				saw_valid_coupling = true
		ok = _assert(saw_valid_coupling, "Physics-server feedback should expose at least one recognized failure coupling scalar when failure_coupling is present.") and ok

	var pipeline_destruction = _extract_payload_with_fallback([pipeline], "destruction", [])
	if pipeline_destruction is Array && pipeline_destruction.size() > 0:
		var found_stage_feedback := false
		for stage_variant in pipeline_destruction:
			if stage_variant is Dictionary:
				var stage := stage_variant as Dictionary
				if int(feedback.get("destruction_feedback_count", 0)) > 0:
					ok = _assert(stage.has("resistance"), "Destruction stage result should include resistance.") and ok
					ok = _assert(stage.has("resistance_raw"), "Destruction stage result should include resistance_raw.") and ok
					ok = _assert(stage.has("failure_status"), "Destruction stage result should include failure_status.") and ok
					ok = _assert(stage.has("failure_reason"), "Destruction stage result should include failure_reason.") and ok
					ok = _assert(stage.has("failure_mode"), "Destruction stage result should include failure_mode.") and ok
					ok = _assert(stage.has("friction_state"), "Destruction stage result should include friction_state.") and ok
					ok = _assert(stage.has("friction_state_code"), "Destruction stage result should include friction_state_code.") and ok
					ok = _assert(stage.has("overstress_ratio"), "Destruction stage result should include overstress_ratio.") and ok
					ok = _assert(_is_scalar_finite(stage.get("resistance", 0.0), "destruction[0].resistance"), "Destruction stage resistance should be finite.") and ok
					ok = _assert(_is_scalar_finite(stage.get("resistance_raw", 0.0), "destruction[0].resistance_raw"), "Destruction stage resistance_raw should be finite.") and ok
				ok = _assert(_is_scalar_finite(stage.get("mass_loss", 0.0), "destruction_stage.mass_loss"), "Destruction stage mass_loss should be finite.") and ok
				ok = _assert(_is_scalar_finite(stage.get("damage", 0.0), "destruction_stage.damage"), "Destruction stage damage should be finite.") and ok
				ok = _assert(_is_scalar_finite(stage.get("friction_force", 0.0), "destruction_stage.friction_force"), "Destruction stage friction_force should be finite.") and ok
				found_stage_feedback = true
		ok = _assert(found_stage_feedback, "Physics-server feedback should see at least one destruction stage payload when destruction stages execute.") and ok

	var failure_emission = _extract_payload_with_fallback([step_result], "voxel_failure_emission", {})
	if (failure_emission is Dictionary and failure_emission.is_empty()) or not (failure_emission is Dictionary):
		failure_emission = _extract_payload_with_fallback([pipeline], "voxel_failure_emission", {})
	ok = _assert(failure_emission is Dictionary, "Wave-B scenario '%s' step %d should include root voxel_failure_emission dictionary." % [scenario_name, step_index]) and ok
	if failure_emission is Dictionary:
		ok = _assert(failure_emission.has("status"), "Root voxel_failure_emission should expose status.") and ok
		ok = _assert(failure_emission.has("reason"), "Root voxel_failure_emission should expose reason.") and ok
		ok = _assert(failure_emission.has("target_domain"), "Root voxel_failure_emission should expose target_domain.") and ok
		ok = _assert(failure_emission.has("planned_op_count"), "Root voxel_failure_emission should expose planned_op_count.") and ok
		ok = _assert(failure_emission.has("stage_name"), "Root voxel_failure_emission should expose stage_name.") and ok
		ok = _assert(failure_emission.has("op_payloads"), "Root voxel_failure_emission should expose op_payloads.") and ok
		if failure_emission.get("planned_op_count", 0) > 0:
			ok = _assert(failure_emission.get("execution") is Dictionary, "Root voxel_failure_emission should expose execution details when ops are planned.") and ok

	return ok

func _assert_wave_b_result_finite(step_result: Dictionary, scenario_name: String, step_index: int) -> bool:
	var ok := true
	var pipeline := _extract_pipeline_payload(step_result)
	if not (pipeline is Dictionary):
		return _assert(false, "Wave-B scenario '%s' step %d should include a pipeline dictionary." % [scenario_name, step_index])
	ok = _assert(_assert_physics_server_feedback_contract(step_result, scenario_name, step_index), "Wave-B scenario '%s' step %d should expose valid physics_server_feedback output." % [scenario_name, step_index]) and ok
	var pipeline_path := "pipeline"
	var field_evolution := _extract_payload_with_fallback([pipeline], "field_evolution", {})
	var nonfinite_path := _find_nonfinite_value_path(field_evolution, "%s/field_evolution" % pipeline_path)
	if nonfinite_path != "":
		ok = _assert(false, "Wave-B scenario '%s' step %d has non-finite value in field_evolution at %s." % [scenario_name, step_index, nonfinite_path]) and ok
	var nonfinite_summary_path := _find_nonfinite_value_path(
		{"field_mass_drift_proxy": _extract_payload_with_fallback([pipeline], "field_mass_drift_proxy", 0.0), "field_energy_drift_proxy": _extract_payload_with_fallback([pipeline], "field_energy_drift_proxy", 0.0)},
			"%s/summaries" % pipeline_path)
	if nonfinite_summary_path != "":
		ok = _assert(false, "Wave-B scenario '%s' step %d has non-finite summary value at %s." % [scenario_name, step_index, nonfinite_summary_path]) and ok
	if not _assert(field_evolution is Dictionary, "Wave-B scenario '%s' step %d should expose a field_evolution dictionary." % [scenario_name, step_index]):
		return false
	var updated_fields: Dictionary = field_evolution.get("updated_fields", {})
	if not _assert(updated_fields is Dictionary, "Wave-B scenario '%s' step %d should expose updated_fields dictionary." % [scenario_name, step_index]):
		return false
	for field in ["mass", "pressure", "temperature", "velocity", "density"]:
		var values = updated_fields.get(field, [])
		ok = _assert(values is Array or values is PackedFloat32Array or values is PackedFloat64Array, "Wave-B scenario '%s' step %d should expose numeric values for field '%s'." % [scenario_name, step_index, field]) and ok
		ok = _assert(_arrays_are_finite(values, "Wave-B scenario %s step %d field %s" % [scenario_name, step_index, field]), "Wave-B scenario '%s' step %d should expose finite values for field '%s'." % [scenario_name, step_index, field]) and ok
	return ok

func _assert_transport_pair_value(pair_summary: Dictionary, key: String) -> bool:
	var value_variant = pair_summary.get(key)
	if not (value_variant is int or value_variant is float):
		return false
	return _is_scalar_finite(value_variant, "pair_summary[%s]" % key)

func _is_scalar_finite(value: Variant, label: String) -> bool:
	if value is int:
		return true
	if value is float:
		var numeric = float(value)
		if numeric != numeric || numeric == INF || numeric == -INF:
			return _assert(false, "%s must be finite number." % label)
		return true
	return _assert(false, "%s must be numeric." % label)

func _find_nonfinite_value_path(value: Variant, path: String) -> String:
	if value is int:
		return ""
	if value is float:
		var numeric = float(value)
		if numeric != numeric || numeric == INF || numeric == -INF:
			return path
		return ""
	if value is Vector3:
		var vector3_value := value as Vector3
		var x := float(vector3_value.x)
		var y := float(vector3_value.y)
		var z := float(vector3_value.z)
		if x != x || x == INF || x == -INF:
			return "%s/x" % path
		if y != y || y == INF || y == -INF:
			return "%s/y" % path
		if z != z || z == INF || z == -INF:
			return "%s/z" % path
		return ""
	if value is Vector2:
		var vector2_value := value as Vector2
		var x := float(vector2_value.x)
		var y := float(vector2_value.y)
		if x != x || x == INF || x == -INF:
			return "%s/x" % path
		if y != y || y == INF || y == -INF:
			return "%s/y" % path
		return ""
	if value is Array:
		var values := value as Array
		for index in range(values.size()):
			var child_path = "%s[%d]" % [path, index]
			var child = values[index]
			var result = _find_nonfinite_value_path(child, child_path)
			if result != "":
				return result
		return ""
	if value is PackedFloat32Array || value is PackedFloat64Array:
		var count = value.size()
		for index in range(count):
			var child_path = "%s[%d]" % [path, index]
			var child = value[index]
			var result = _find_nonfinite_value_path(child, child_path)
			if result != "":
				return result
		return ""
	if value is Dictionary:
		var container := value as Dictionary
		for key in container.keys():
			var child_path = "%s/%s" % [path, String(key)]
			var child = container.get(key)
			var result = _find_nonfinite_value_path(child, child_path)
			if result != "":
				return result
		return ""
	return ""

func _max_abs_float_array(values: Variant) -> float:
	if not (values is Array || values is PackedFloat32Array || values is PackedFloat64Array):
		return 0.0
	var result := 0.0
	for value in values:
		if value is int || value is float:
			result = max(result, abs(float(value)))
	return result

func _arrays_are_finite(values: Variant, label: String) -> bool:
	if not (values is Array || values is PackedFloat32Array || values is PackedFloat64Array):
		return _assert(false, "%s should be an array." % label)
	for value in values:
		if not _is_scalar_finite(value, label):
			return false
	return true

func _coerce_float(value: Variant) -> float:
	if value is int:
		return float(value)
	if value is float:
		return float(value)
	return 0.0

func _test_reordered_contact_rows_with_obstacle_motion(core: Object) -> bool:
	core.call("reset")
	var ordered_rows := _build_obstacle_motion_rows_for_determinism()
	var reordered_rows := ordered_rows.duplicate(true)
	reordered_rows.reverse()
	var payload_a: Dictionary = _build_wave_a_obstacle_motion_payload(ordered_rows, 0.35)
	var payload_b: Dictionary = _build_wave_a_obstacle_motion_payload(reordered_rows, 0.35)
	var result_a: Dictionary = core.call("execute_environment_stage", CFG.PIPELINE_STAGE_NAME, payload_a)
	var result_b: Dictionary = core.call("execute_environment_stage", CFG.PIPELINE_STAGE_NAME, payload_b)
	var mass_a := _extract_updated_mass(result_a)
	var mass_b := _extract_updated_mass(result_b)
	var boundary_a := _extract_stage_boundary(result_a, "pressure", false)
	var boundary_b := _extract_stage_boundary(result_b, "pressure", false)
	var has_boundary_a := not boundary_a.is_empty()
	var has_boundary_b := not boundary_b.is_empty()
	var ok := true
	ok = _assert(_assert_numeric_array_sum_and_mean_equivalence(mass_a, mass_b, 1.0e-12), "Reordered obstacle-motion contact rows should produce equivalent aggregate mass updates.") and ok
	if has_boundary_a != has_boundary_b:
		return _assert(false, "Reordered obstacle-motion contact rows should either include boundary diagnostics on both paths or neither.")
	if has_boundary_a:
		ok = _assert(_assert_boundary_payloads_match(boundary_a, boundary_b, 1.0e-12), "Reordered obstacle-motion contact rows should produce deterministic boundary diagnostics.") and ok
	return ok

func _test_obstacle_motion_scale_affects_boundary_effect(core: Object) -> bool:
	core.call("reset")
	var obstacle_rows := [_build_obstacle_motion_row_for_scale_test()]
	var baseline_payload := _build_wave_a_obstacle_motion_payload(obstacle_rows, 0.35)
	var scaled_payload := _build_wave_a_obstacle_motion_payload(obstacle_rows, 0.35, 0.75)
	var baseline_result: Dictionary = core.call("execute_environment_stage", CFG.PIPELINE_STAGE_NAME, baseline_payload)
	var scaled_result: Dictionary = core.call("execute_environment_stage", CFG.PIPELINE_STAGE_NAME, scaled_payload)
	var baseline_boundary := _extract_stage_boundary(baseline_result, "pressure", false)
	var scaled_boundary := _extract_stage_boundary(scaled_result, "pressure", false)
	var has_baseline_boundary := not baseline_boundary.is_empty()
	var has_scaled_boundary := not scaled_boundary.is_empty()
	if has_baseline_boundary != has_scaled_boundary:
		return _assert(false, "Moving-obstacle scaling diagnostics should either include boundary payloads for both results or neither.")
	if not has_baseline_boundary:
		return true
	var obstacle_velocity := absf(float(baseline_boundary.get("obstacle_velocity", 0.0)))
	var expected_baseline := 0.35
	var expected_scaled := minf(1.0, maxf(0.0, 0.35 + obstacle_velocity * 0.75))
	var ok := true
	ok = _assert(_assert_scalar_value(baseline_boundary, "effective_obstacle_attenuation", expected_baseline, 1.0e-12), "Default moving_obstacle_speed_scale (0) must keep effective attenuation at static value.") and ok
	ok = _assert(_assert_scalar_value(scaled_boundary, "effective_obstacle_attenuation", expected_scaled, 1.0e-12), "Non-default moving_obstacle_speed_scale must increase effective attenuation by |obstacle_velocity| * scale.") and ok
	ok = _assert(not is_equal_approx(float(baseline_boundary.get("effective_obstacle_attenuation", 0.0)), float(scaled_boundary.get("effective_obstacle_attenuation", 0.0))), "Moving-obstacle scaling should change effective attenuation output.") and ok
	return ok

func _build_obstacle_motion_rows_for_determinism() -> Array:
	return [
		{
			"contact_impulse": 4.0,
			"contact_normal": Vector3(1.0, 0.0, 0.0),
			"contact_point": Vector3(2.0, 0.5, 0.0),
			"body_velocity": 3.5,
			"obstacle_velocity": 1.75,
			"obstacle_trajectory": Vector3(0.0, 1.0, 0.0),
			"body_id": 3,
			"rigid_obstacle_mask": 1,
		},
		{
			"contact_impulse": 1.5,
			"contact_normal": Vector3(0.0, 1.0, 0.0),
			"contact_point": Vector3(1.5, 2.0, 0.5),
			"body_velocity": 2.0,
			"obstacle_velocity": 0.9,
			"obstacle_trajectory": Vector3(1.0, 0.0, 0.0),
			"body_id": 1,
			"rigid_obstacle_mask": 2,
		},
	]

func _build_obstacle_motion_row_for_scale_test() -> Dictionary:
	return {
		"contact_impulse": 6.0,
		"contact_normal": Vector3(0.0, 1.0, 0.0),
		"contact_point": Vector3(0.5, 0.5, 1.0),
		"body_velocity": 2.5,
		"obstacle_velocity": 1.8,
		"obstacle_trajectory": Vector3(1.0, 0.0, 1.0),
		"body_id": 7,
		"rigid_obstacle_mask": 3,
	}

func _build_wave_a_obstacle_motion_payload(rows: Array, obstacle_attenuation: float = 0.35, moving_obstacle_speed_scale: Variant = null) -> Dictionary:
	var payload := _build_payload()
	payload["physics_contacts"] = rows.duplicate(true)
	var inputs: Dictionary = payload.get("inputs", {})
	if typeof(inputs) != TYPE_DICTIONARY:
		inputs = {}
	inputs["obstacle_attenuation"] = obstacle_attenuation
	if moving_obstacle_speed_scale != null:
		inputs["moving_obstacle_speed_scale"] = moving_obstacle_speed_scale
	payload["inputs"] = inputs
	return payload

func _extract_stage_boundary(step_result: Dictionary, stage_name: String, require_boundary: bool = true) -> Dictionary:
	var pipeline: Dictionary = _extract_pipeline_payload(step_result)
	if typeof(pipeline) != TYPE_DICTIONARY:
		if require_boundary:
			push_error("Wave-A continuity step result missing pipeline payload for boundary extraction.")
		return {}
	var stages_payload := _extract_payload_with_fallback([pipeline], stage_name, null)
	var stages: Array = []
	if stages_payload is Array:
		stages = stages_payload
	elif stages_payload is Dictionary:
		stages = [stages_payload]
	else:
		if require_boundary:
			push_error("Wave-A continuity step result missing '%s' stage array for boundary extraction." % stage_name)
		return {}
	if stages.is_empty():
		if require_boundary:
			push_error("Wave-A continuity step result has empty '%s' stage array for boundary extraction." % stage_name)
		return {}
	var stage_payload_variant = _coerce_dictionary_payload(stages[0], {})
	if stage_payload_variant.is_empty():
		if require_boundary:
			push_error("Wave-A continuity step result '%s' stage payload is invalid for boundary extraction." % stage_name)
		return {}
	var boundary_payload := _extract_payload_with_fallback([stage_payload_variant], "boundary", {})
	var boundary: Dictionary = _coerce_dictionary_payload(boundary_payload, {})
	if boundary.is_empty():
		if require_boundary:
			push_error("Wave-A continuity step result '%s' boundary payload is missing." % stage_name)
		return {}
	return boundary

func _assert_boundary_payloads_match(lhs: Dictionary, rhs: Dictionary, tolerance: float) -> bool:
	var scalar_keys := [
		"obstacle_attenuation",
		"obstacle_velocity",
		"moving_obstacle_speed_scale",
		"effective_obstacle_attenuation",
		"directional_multiplier",
		"scalar_multiplier",
		"mode",
	]
	var ok := true
	for key in scalar_keys:
		ok = _assert(lhs.has(key), "Boundary payload missing '%s'." % String(key)) and ok
		ok = _assert(rhs.has(key), "Reordered boundary payload missing '%s'." % String(key)) and ok
		if key != "mode":
			ok = _assert(
				absf(float(lhs.get(key, 0.0)) - float(rhs.get(key, 0.0))) <= tolerance,
				"Boundary payload field '%s' should be deterministic after row reorder." % String(key)
			) and ok
		else:
			ok = _assert(String(lhs.get(key, "")) == String(rhs.get(key, "")), "Boundary mode should remain stable after row reorder.") and ok
	var lhs_trajectory := _as_vector3(lhs.get("obstacle_trajectory", Vector3.ZERO))
	var rhs_trajectory := _as_vector3(rhs.get("obstacle_trajectory", Vector3.ZERO))
	ok = _assert(_assert_vectors_equal(lhs_trajectory, rhs_trajectory, tolerance), "Boundary obstacle_trajectory should be deterministic after row reorder.") and ok
	return ok

func _assert_scalar_value(boundary: Dictionary, key: String, expected: float, tolerance: float) -> bool:
	var observed_value = _extract_payload_with_fallback([boundary], key, null)
	if observed_value == null:
		return _assert(false, "Boundary payload missing '%s'." % key)
	return _assert(
		absf(_coerce_scalar_float(observed_value, 0.0) - expected) <= tolerance,
		"Boundary field '%s' should match expected value." % key
	)

func _assert_vectors_equal(lhs: Vector3, rhs: Vector3, tolerance: float) -> bool:
	return absf(lhs.x - rhs.x) <= tolerance and absf(lhs.y - rhs.y) <= tolerance and absf(lhs.z - rhs.z) <= tolerance

func _as_vector3(raw_value) -> Vector3:
	if raw_value is Vector3:
		return raw_value as Vector3
	if raw_value is Vector2:
		return Vector3(float(raw_value.x), float(raw_value.y), 0.0)
	if raw_value is Array:
		var array_value: Array = raw_value
		if array_value.size() >= 3:
			return Vector3(float(array_value[0]), float(array_value[1]), float(array_value[2]))
		if array_value.size() >= 2:
			return Vector3(float(array_value[0]), float(array_value[1]), 0.0)
		return Vector3.ZERO
	if raw_value is Dictionary:
		var row = raw_value as Dictionary
		return Vector3(float(row.get("x", 0.0)), float(row.get("y", 0.0)), float(row.get("z", 0.0)))
	return Vector3.ZERO
