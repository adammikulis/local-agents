@tool
extends RefCounted

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const PIPELINE_STAGE_NAME := "wave_a_continuity"

const BASE_MASS := [1.0, 2.0]
const BASE_PRESSURE := [100.0, 110.0]
const BASE_TEMPERATURE := [300.0, 320.0]
const BASE_VELOCITY := [0.0, 1.0]
const BASE_DENSITY := [1.0, 2.0]
const BASE_TOPOLOGY := [[1], [0]]
const TRANSPORT_MASS := [1.5, 0.8, 1.2]
const TRANSPORT_PRESSURE := [110.0, 95.0, 102.0]
const TRANSPORT_TEMPERATURE := [295.0, 320.0, 305.0]
const TRANSPORT_VELOCITY := [1.0, -0.4, 0.6]
const TRANSPORT_DENSITY := [1.0, 1.1, 1.4]
const TRANSPORT_TOPOLOGY_ORDER_A := [[1, 2], [0, 2], [0, 1]]
const TRANSPORT_TOPOLOGY_ORDER_B := [[2, 1], [2, 0], [1, 0]]
const TRANSPORT_TOPOLOGY_INVALID_A := [[-1, 1, 2, 256, 1.5, 99], [2, 0, 999, 0.5], [0, 1, -7, 400]]
const TRANSPORT_TOPOLOGY_INVALID_B := [[2, 99, 1.5, -2, 1], [0, 2, 0.0, -1], [1, 0, 256, 3.14]]
const TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES := 3
const HOT_FIELDS := ["mass", "pressure", "temperature", "velocity", "density"]
const HANDLE_MODE_OPTIONAL_SUMMARY_KEYS := ["field_handle_marker", "field_handle_io"]
const HANDLE_MODE_RESOLVED_SOURCE := "field_buffers"
const HANDLE_MODE_EXPECTED_REFS := {
	"mass": "mass_density",
	"pressure": "pressure",
	"temperature": "temperature",
	"velocity": "momentum_x",
	"density": "density",
}
const WAVE_B_REGRESSION_SCENARIO_ORDER := ["impact", "flood", "fire", "cooling", "collapse", "mixed_material"]
const WAVE_B_REGRESSION_STEPS := 2
const WAVE_B_REPEATED_LOAD_STEPS := 8
const WAVE_B_FIELD_GROWTH_FACTOR := 25.0
const WAVE_B_FIELD_ABS_CAP := 1.0e6
const WAVE_B_BASE_MASS := [1.0, 1.1]
const WAVE_B_BASE_PRESSURE := [102.0, 118.0]
const WAVE_B_BASE_TEMPERATURE := [292.0, 308.0]
const WAVE_B_BASE_VELOCITY := [0.45, 0.55]
const WAVE_B_BASE_DENSITY := [1.0, 1.15]
const WAVE_B_BASE_TOPOLOGY := [[1], [0]]
const WAVE_B_SCENARIO_EXTRA_INPUTS := {
	"impact": {
		"shock_impulse": 4.0,
		"shock_distance": 2.5,
		"shock_gain": 1.2,
		"stress": 1.8e7,
		"cohesion": 0.62,
	},
	"flood": {
		"pressure_gradient": 1.5,
		"moisture": 0.86,
		"phase": 0,
		"porosity": 0.4,
		"porous_flow_channels": {
			"seepage": 0.22,
			"drainage": 0.18,
			"capillary": 0.25,
		},
		"neighbor_temperature": 296.0,
	},
	"fire": {
		"temperature": 900.0,
		"reactant_a": 1.2,
		"reactant_b": 0.8,
		"reaction_rate": 0.68,
		"fuel": 1.0,
		"oxygen": 0.24,
		"material_flammability": 0.92,
	},
	"cooling": {
		"ambient_temperature": 262.0,
		"velocity": 1.2,
		"temperature": 298.0,
		"thermal_diffusivity": 0.00008,
		"thermal_capacity": 2500.0,
		"thermal_conductivity": 250.0,
	},
	"collapse": {
		"stress": 2.8e8,
		"strain": 0.45,
		"damage": 0.11,
		"hardness": 0.22,
		"slope_angle_deg": 32.0,
		"normal_force": 1500.0,
	},
	"mixed_material": {
		"phase_transition_capacity": 0.35,
		"liquid_fraction": 0.18,
		"vapor_fraction": 0.02,
		"phase": 1,
		"temperature": 315.0,
		"reaction_channels": {
			"combustion": 0.32,
			"oxidation": 0.44,
			"decomposition": 0.28,
		},
		"phase_change_channels": {
			"melting": 0.07,
			"freezing": 0.0,
			"evaporation": 0.09,
		},
	},
}

func run_test(_tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for Wave-A continuity test.")
		return false

	var core := Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null.")
		return false

	if not _assert(bool(core.call("configure", {})), "LocalAgentsSimulationCore.configure() must succeed for test setup."):
		return false
	core.call("reset")

	var first_payload := _build_payload()
	var second_payload := first_payload.duplicate(true)
	var first_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, first_payload)
	var second_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, second_payload)
	var ok := true
	ok = _assert(_assert_physics_server_feedback_contract(first_result, "baseline scalar pre-reset", 0), "Baseline scalar pre-reset step should expose valid physics_server_feedback output.") and ok
	ok = _assert(_assert_physics_server_feedback_contract(second_result, "baseline scalar pre-reset", 1), "Baseline scalar pre-reset follow-up step should expose valid physics_server_feedback output.") and ok
	ok = _assert(String(first_result.get("field_handle_mode", "")) == "scalar", "Baseline scalar input should report field_handle_mode=scalar.")
	ok = _assert(String(second_result.get("field_handle_mode", "")) == "scalar", "Follow-up scalar input should report field_handle_mode=scalar.")
	var first_diagnostics := _extract_stage_field_input_diagnostics(first_result)
	ok = _assert(_assert_hot_field_resolution(first_diagnostics, HOT_FIELDS, true, false, false, "scalar", "", "frame_inputs_scalar"), "Base payload without handles should resolve hot fields from frame inputs.") and ok

	var first_mass := _extract_updated_mass(first_result)
	var second_mass := _extract_updated_mass(second_result)
	var override_payload := _build_override_payload()
	var third_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, override_payload)
	ok = _assert(_assert_physics_server_feedback_contract(third_result, "baseline scalar override", 2), "Override scalar step should expose valid physics_server_feedback output.") and ok
	var third_mass := _extract_updated_mass(third_result)
	var override_diagnostics := _extract_stage_field_input_diagnostics(third_result)
	ok = _assert(_assert_hot_field_resolution(override_diagnostics, HOT_FIELDS, true, false, false, "scalar", "", "field_buffers"), "Override payload hot fields should resolve from continuity field_buffers when handles are absent.") and ok
	ok = _assert(_assert_summary_key_set_stability(first_result, third_result, []), "Scalar-mode summary key set should stay stable across scalar-only execution transitions.")
	core.call("reset")
	var reset_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, _build_payload())
	var reset_mass := _extract_updated_mass(reset_result)
	if not _assert(first_mass.size() == BASE_MASS.size(), "First step must emit mass update arrays."):
		return false
	if not _assert(second_mass.size() == BASE_MASS.size(), "Second step must emit mass update arrays."):
		return false
	if not _assert(third_mass.size() == BASE_MASS.size(), "Third step with explicit field_buffers override must emit mass update arrays."):
		return false

	ok = _assert(not _arrays_equal(first_mass, second_mass), "Second execute_step must consume prior step updated fields, not restart from the unchanged input snapshot.") and ok
	ok = _assert(not _arrays_equal(first_mass, BASE_MASS), "First execute_step should evolve mass fields from its initial snapshot.") and ok
	ok = _assert(not _arrays_equal(second_mass, BASE_MASS), "Second execute_step should also evolve from prior fields, not initial mass snapshot.") and ok
	ok = _assert(not _arrays_equal(first_mass, third_mass), "Third execute_step should reflect explicit `field_buffers` override inputs.") and ok
	ok = _assert(third_mass[0] > 0.0, "Third execute_step result should be valid with explicit field buffer override input.") and ok
	ok = _assert(not _arrays_equal(third_mass, reset_mass), "Reset should clear carried continuity so subsequent execution reuses input snapshot baseline.") and ok
	ok = _assert(_assert_summary_key_set_stability(first_result, reset_result, []), "Summary key set should remain stable when returning to scalar mode after reset.")
	ok = _assert(String(reset_result.get("field_handle_mode", "")) == "scalar", "Reset-to-scalar input should report field_handle_mode=scalar.")
	core.call("reset")
	var handle_result: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_handle_first_payload())
	ok = _assert(_assert_physics_server_feedback_contract(handle_result, "handle-first", 0), "Handle-first step should expose valid physics_server_feedback output.") and ok
	var handle_diagnostics := _extract_stage_field_input_diagnostics(handle_result)
	ok = _assert(_assert_hot_handle_field_diagnostics(handle_diagnostics, HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Handle-first hot fields should resolve via handle with no scalar fallback.") and ok
	ok = _assert(String(handle_result.get("field_handle_mode", "")) == "field_handles", "Handle-first input should report field_handle_mode=field_handles.")
	ok = _assert(_assert_summary_key_set_stability(first_result, handle_result, HANDLE_MODE_OPTIONAL_SUMMARY_KEYS), "Summary key set should stay stable across scalar->field_handle mode transitions.")
	ok = _assert(handle_result.has("field_handle_marker"), "Handle mode should include deterministic field_handle_marker.")
	ok = _assert(handle_result.has("field_handle_io"), "Handle mode should include field_handle_io.")
	var handle_mass := _extract_updated_mass(handle_result)
	var handle_chain_result: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_handle_chain_payload())
	ok = _assert(String(handle_chain_result.get("field_handle_mode", "")) == "field_handles", "Handle-chain input should still be executed in field_handles mode.")
	var handle_chain_diagnostics := _extract_stage_field_input_diagnostics(handle_chain_result)
	var handle_chain_mass := _extract_updated_mass(handle_chain_result)
	ok = _assert(_assert_hot_handle_field_diagnostics(handle_chain_diagnostics, HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Chained handle payload should continue resolve hot fields via handle without fallback.") and ok
	ok = _assert(_assert_hot_handle_field_diagnostics(_extract_field_evolution_handle_resolution_diagnostics(handle_chain_result).get("by_field", {}), HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Chained handle step continuity should remain handle mode in field_evolution.") and ok
	ok = _assert(not _arrays_equal(handle_mass, handle_chain_mass), "Handle-mode chaining should evolve from previous carry-forward fields, not restart from the initial snapshot.") and ok
	var missing_diag := _extract_stage_field_input_diagnostics(core.call("execute_environment_stage", PIPELINE_STAGE_NAME, _build_missing_handles_payload()))
	ok = _assert(_assert_hot_field_resolution(missing_diag, HOT_FIELDS, false, false, false, "missing", "field_handles"), "Invalid handles without compatibility should be missing for all hot fields.") and ok
	var compat_diag := _extract_stage_field_input_diagnostics(core.call("execute_environment_stage", PIPELINE_STAGE_NAME, _build_scalar_compat_fallback_payload()))
	ok = _assert(_assert_hot_field_resolution(compat_diag, HOT_FIELDS, true, false, true, "scalar_fallback", "scalar_fallback", "frame_inputs_scalar"), "Compatibility-mode invalid-handle payload should trigger explicit scalar fallback diagnostics for all hot fields.") and ok
	core.call("reset")
	var scalar_field_evolution := _extract_field_evolution_handle_resolution_diagnostics(core.call("execute_environment_stage", PIPELINE_STAGE_NAME, _build_payload()))
	var scalar_by_field := scalar_field_evolution.get("by_field", {})
	var scalar_mass_diag: Dictionary = scalar_by_field.get("mass", {})
	ok = _assert(String(scalar_mass_diag.get("mode", "")) == "scalar", "Scalar-only field evolution should mark mass mode as scalar.") and ok
	ok = _assert(not bool(scalar_mass_diag.get("resolved_via_handle", false)), "Scalar-only field evolution should not resolve via handle.") and ok
	var scalar_fallback_found := _has_scalar_fallback_used(compat_diag)
	ok = _assert(scalar_fallback_found, "Scalar fallback path should mark at least one hot field with fallback diagnostics.") and ok
	core.call("reset")
	var transport_result_a: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_ORDER_A))
	var transport_result_b: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_ORDER_B))
	ok = _assert(
		_assert_transport_payload_equivalence(
			transport_result_a,
			transport_result_b,
			1.0e-12),
		"Transport neighbor edge-order permutations must produce identical updated fields and pair update summaries.") and ok
	var transport_invalid_a: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_INVALID_A))
	var transport_invalid_b: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		_build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_INVALID_B))
	ok = _assert(
		_assert_transport_invalid_edge_regression(
			transport_invalid_a,
			transport_invalid_b,
			TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES,
			1.0e-12),
		"Transport neighbor topologies with invalid edge entries must be deterministic and avoid NaN/extra pair updates.") and ok
	ok = _assert(_test_reordered_contact_rows_with_obstacle_motion(core), "Reordered obstacle-motion contact rows should not affect simulation determinism.") and ok
	ok = _assert(_test_obstacle_motion_scale_affects_boundary_effect(core), "Moving-obstacle speed scaling should impact effective_obstacle_attenuation while default scale keeps it unchanged.") and ok

	if ok:
		ok = _assert(_test_wave_b_regression_scenarios(core), "Wave-A regression coverage for impact/flood/fire/cooling/collapse/mixed-material should be deterministic, finite, and key-stable.") and ok
		ok = _assert(_test_repeated_load_terrain_stability(core), "Wave-A terrain repeated-load stability should stay bounded and replay-coherent after reset.") and ok
		print("Wave-A continuity runtime test passed for two-step field-buffer carry and row-260/263 regression coverage.")
	return ok

func _test_wave_b_regression_scenarios(core: Object) -> bool:
	var ok := true
	var fields := ["mass", "pressure", "temperature", "velocity", "density"]
	for scenario_tag in WAVE_B_REGRESSION_SCENARIO_ORDER:
		core.call("reset")
		var payload := _build_wave_b_regression_payload(scenario_tag)
		var first_results := _execute_wave_b_payload_steps(core, payload, WAVE_B_REGRESSION_STEPS)
		core.call("reset")
		var second_results := _execute_wave_b_payload_steps(core, payload, WAVE_B_REGRESSION_STEPS)
		if first_results.size() != WAVE_B_REGRESSION_STEPS or second_results.size() != WAVE_B_REGRESSION_STEPS:
			ok = _assert(false, "Row-260 scenario '%s' did not produce the expected number of steps." % String(scenario_tag)) and ok
			continue
		for step_index in range(WAVE_B_REGRESSION_STEPS):
			var lhs := first_results[step_index]
			var rhs := second_results[step_index]
			ok = _assert(_assert_wave_b_result_finite(lhs, scenario_tag, step_index), "Row-260 scenario '%s' step %d should contain finite updated fields and summary numerics." % [String(scenario_tag), step_index]) and ok
			ok = _assert(_assert_wave_b_result_finite(rhs, scenario_tag, step_index), "Row-260 scenario '%s' replay step %d should contain finite updated fields and summary numerics." % [String(scenario_tag), step_index]) and ok
			var lhs_pipeline := lhs.get("pipeline", {})
			var rhs_pipeline := rhs.get("pipeline", {})
			if not _assert(lhs_pipeline is Dictionary, "Row-260 scenario '%s' step %d should expose a pipeline result." % [String(scenario_tag), step_index]):
				continue
			if not _assert(rhs_pipeline is Dictionary, "Row-260 scenario '%s' replay step %d should expose a pipeline result." % [String(scenario_tag), step_index]):
				continue
			var lhs_field_evolution := lhs_pipeline.get("field_evolution", {})
			var rhs_field_evolution := rhs_pipeline.get("field_evolution", {})
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
			var lhs_mass_drift = _coerce_float(lhs_pipeline.get("field_mass_drift_proxy", 0.0))
			var rhs_mass_drift = _coerce_float(rhs_pipeline.get("field_mass_drift_proxy", 0.0))
			var lhs_energy_drift = _coerce_float(lhs_pipeline.get("field_energy_drift_proxy", 0.0))
			var rhs_energy_drift = _coerce_float(rhs_pipeline.get("field_energy_drift_proxy", 0.0))
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
	var no_reset_results := _execute_wave_b_payload_steps(core, payload, WAVE_B_REPEATED_LOAD_STEPS)
	var previous_step_max := {
		"mass": 0.0,
		"pressure": 0.0,
		"temperature": 0.0,
		"velocity": 0.0,
		"density": 0.0,
	}
	var ok := true
	var fields := ["mass", "pressure", "temperature", "velocity", "density"]
	if no_reset_results.size() != WAVE_B_REPEATED_LOAD_STEPS:
		return _assert(false, "Row-263 repeated-load check should run exactly %d steps." % WAVE_B_REPEATED_LOAD_STEPS)
	for result_index in range(no_reset_results.size()):
		var current := no_reset_results[result_index]
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
			ok = _assert(max_abs < WAVE_B_FIELD_ABS_CAP, "Row-263 repeated-load step %d field '%s' should stay within numeric cap." % [result_index, field]) and ok
		if result_index > 0:
			var prior_summary := _extract_transport_pair_summary(no_reset_results[result_index - 1])
			for field in fields:
				var previous_max := float(previous_step_max.get(field, 0.0))
				var current_max := float(current_step_max.get(field, 0.0))
				var growth_limit := max(previous_max * WAVE_B_FIELD_GROWTH_FACTOR, 1.0)
				ok = _assert(current_max <= growth_limit, "Row-263 repeated-load should not grow field '%s' explosively from step %d to %d." % [field, result_index - 1, result_index]) and ok
				previous_step_max[field] = max(previous_max, current_max)
			ok = _assert(_assert_summary_key_set_stability(prior_summary, pair_summary, []) and
				_assert_summary_key_set_stability(pair_summary, prior_summary, []),
					"Row-263 repeated-load should preserve pair-summary keys between consecutive steps %d and %d." % [result_index - 1, result_index]) and ok
			for diagnostics_field in ["field_mass_drift_proxy", "field_energy_drift_proxy"]:
				var drift_value = 0.0
				if current.has("pipeline") and current.get("pipeline") is Dictionary:
					drift_value = float(current.get("pipeline").get(diagnostics_field, 0.0))
				ok = _assert(_is_scalar_finite(drift_value, "repeated_load step=%d %s" % [result_index, diagnostics_field]),
					"Row-263 repeated-load summary %s should remain finite at step %d." % [diagnostics_field, result_index]) and ok
				ok = _assert(abs(drift_value) <= WAVE_B_FIELD_ABS_CAP, "Row-263 repeated-load summary %s should remain bounded at step %d." % [diagnostics_field, result_index]) and ok
	# Replay after reset and verify deterministic coherence per step.
	core.call("reset")
	var replay_results := _execute_wave_b_payload_steps(core, payload, WAVE_B_REPEATED_LOAD_STEPS)
	if not _assert(replay_results.size() == no_reset_results.size(), "Row-263 repeated-load replay should preserve step count."):
		return false
	for result_index in range(no_reset_results.size()):
		var original := no_reset_results[result_index]
		var replayed := replay_results[result_index]
		ok = _assert_wave_b_result_finite(replayed, "repeated_load_replay", result_index) and ok
		var original_pair := _extract_transport_pair_summary(original)
		var replay_pair := _extract_transport_pair_summary(replayed)
		ok = _assert(_assert_summary_key_set_stability(original_pair, replay_pair, []) and _assert_summary_key_set_stability(replay_pair, original_pair, []), "Row-263 repeated-load replay should preserve summary key set at step %d." % result_index) and ok
		for field in fields:
			ok = _assert(_arrays_equal(original_pair.get(field, []), replay_pair.get(field, []), 1.0e-12),
				"Row-263 repeated-load replay should match original field '%s' at step %d." % [field, result_index] ) and ok
		ok = _assert(int(original_pair.get("pair_updates", -1)) == int(replay_pair.get("pair_updates", -1)),
			"Row-263 repeated-load replay should match pair_updates at step %d." % result_index) and ok
	return ok

func _build_wave_b_regression_payload(scenario_tag: String) -> Dictionary:
	var payload := {
		"delta": 1.0,
		"inputs": {
			"mass_field": WAVE_B_BASE_MASS.duplicate(true),
			"pressure_field": WAVE_B_BASE_PRESSURE.duplicate(true),
			"temperature_field": WAVE_B_BASE_TEMPERATURE.duplicate(true),
			"velocity_field": WAVE_B_BASE_VELOCITY.duplicate(true),
			"density_field": WAVE_B_BASE_DENSITY.duplicate(true),
			"neighbor_topology": WAVE_B_BASE_TOPOLOGY.duplicate(true),
		}
	}
	var scenario_overrides := WAVE_B_SCENARIO_EXTRA_INPUTS.get(scenario_tag, {})
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
		results.append(core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true)))
	return results

func _assert_physics_server_feedback_contract(step_result: Dictionary, scenario_name: String, step_index: int) -> bool:
	var ok := true
	var feedback := step_result.get("physics_server_feedback", {})
	var pipeline := step_result.get("pipeline", {})
	if not _assert(feedback is Dictionary, "Wave-B scenario '%s' step %d should include a top-level physics_server_feedback dictionary." % [scenario_name, step_index]):
		return false
	if not _assert(pipeline is Dictionary, "Wave-B scenario '%s' step %d should include a pipeline dictionary for physics-server feedback verification." % [scenario_name, step_index]):
		return false
	var pipeline_feedback := pipeline.get("physics_server_feedback", {})
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

	var failure_feedback := feedback.get("failure_feedback", {})
	if failure_feedback is Dictionary:
		var failure_feedback_keys := ["status", "reason", "active_stage_count", "watch_stage_count", "dominant_mode", "dominant_stage_index", "active_modes"]
		for key in failure_feedback_keys:
			ok = _assert(failure_feedback.has(key), "Physics-server feedback should expose failure_feedback.%s." % key) and ok
		ok = _assert(failure_feedback.get("status") is String, "failure_feedback.status should be a string.") and ok
		ok = _assert(failure_feedback.get("reason") is String, "failure_feedback.reason should be a string.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("active_stage_count", 0.0), "physics_server_feedback.failure_feedback.active_stage_count"), "failure_feedback.active_stage_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("watch_stage_count", 0.0), "physics_server_feedback.failure_feedback.watch_stage_count"), "failure_feedback.watch_stage_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_feedback.get("dominant_stage_index", 0.0), "physics_server_feedback.failure_feedback.dominant_stage_index"), "failure_feedback.dominant_stage_index should be finite.") and ok
	var failure_source := feedback.get("failure_source", {})
	if failure_source is Dictionary:
		var failure_source_keys := ["source", "status", "reason", "overstress_ratio_max", "active_count", "watch_count"]
		for key in failure_source_keys:
			ok = _assert(failure_source.has(key), "Physics-server feedback should expose failure_source.%s." % key) and ok
		ok = _assert(_is_scalar_finite(failure_source.get("overstress_ratio_max", 0.0), "physics_server_feedback.failure_source.overstress_ratio_max"), "failure_source.overstress_ratio_max should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_source.get("active_count", 0.0), "physics_server_feedback.failure_source.active_count"), "failure_source.active_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(failure_source.get("watch_count", 0.0), "physics_server_feedback.failure_source.watch_count"), "failure_source.watch_count should be finite.") and ok
	var voxel_emission := feedback.get("voxel_emission", {})
	if voxel_emission is Dictionary:
		var voxel_emission_keys := ["status", "reason", "target_domain", "dominant_mode", "active_failure_count", "planned_op_count"]
		for key in voxel_emission_keys:
			ok = _assert(voxel_emission.has(key), "Physics-server feedback should expose voxel_emission.%s." % key) and ok
		ok = _assert(voxel_emission.get("status") is String, "voxel_emission.status should be a string.") and ok
		ok = _assert(voxel_emission.get("reason") is String, "voxel_emission.reason should be a string.") and ok
		ok = _assert(voxel_emission.get("target_domain") is String, "voxel_emission.target_domain should be a string.") and ok
		ok = _assert(_is_scalar_finite(voxel_emission.get("planned_op_count", 0.0), "physics_server_feedback.voxel_emission.planned_op_count"), "voxel_emission.planned_op_count should be finite.") and ok
		ok = _assert(_is_scalar_finite(voxel_emission.get("active_failure_count", 0.0), "physics_server_feedback.voxel_emission.active_failure_count"), "voxel_emission.active_failure_count should be finite.") and ok

	var destruction_feedback := feedback.get("destruction", {})
	if destruction_feedback is Dictionary:
		var required_destruction_metrics := ["mass_loss_total", "damage", "damage_delta_total", "damage_next_total", "friction_force_total", "friction_abs_force_max", "friction_dissipation_total", "fracture_energy_total", "resistance_avg", "resistance_max", "slope_failure_ratio_max"]
		for key in required_destruction_metrics:
			ok = _assert(destruction_feedback.has(key), "Physics-server feedback should expose destruction metric '%s'." % key) and ok
			ok = _assert(_is_scalar_finite(destruction_feedback.get(key, 0.0), "physics_server_feedback.destruction.%s" % key), "Physics-server feedback destruction metric '%s' should be finite." % key) and ok

	var coupling := feedback.get("failure_coupling", {})
	if coupling is Dictionary && coupling.size() > 0:
		var coupling_keys := ["damage_to_voxel_scalar", "pressure_to_mechanics_scalar", "reaction_to_thermal_scalar"]
		var saw_valid_coupling := false
		for key in coupling_keys:
			if coupling.has(key):
				ok = _assert(_is_scalar_finite(coupling.get(key, 0.0), "physics_server_feedback.failure_coupling.%s" % key), "Physics-server feedback should expose failure coupling key '%s' as a finite scalar." % key) and ok
				saw_valid_coupling = true
		ok = _assert(saw_valid_coupling, "Physics-server feedback should expose at least one recognized failure coupling scalar when failure_coupling is present.") and ok

	var pipeline_destruction = pipeline.get("destruction", [])
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

	var failure_emission := step_result.get("voxel_failure_emission", {})
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
	var pipeline := step_result.get("pipeline", {})
	if not (pipeline is Dictionary):
		return _assert(false, "Wave-B scenario '%s' step %d should include a pipeline dictionary." % [scenario_name, step_index])
	ok = _assert(_assert_physics_server_feedback_contract(step_result, scenario_name, step_index), "Wave-B scenario '%s' step %d should expose valid physics_server_feedback output." % [scenario_name, step_index]) and ok
	var pipeline_path := "pipeline"
	var field_evolution := pipeline.get("field_evolution", {})
	var nonfinite_path := _find_nonfinite_value_path(field_evolution, "%s/field_evolution" % pipeline_path)
	if nonfinite_path != "":
		ok = _assert(false, "Wave-B scenario '%s' step %d has non-finite value in field_evolution at %s." % [scenario_name, step_index, nonfinite_path]) and ok
	var nonfinite_summary_path := _find_nonfinite_value_path(
			{"field_mass_drift_proxy": pipeline.get("field_mass_drift_proxy", 0.0), "field_energy_drift_proxy": pipeline.get("field_energy_drift_proxy", 0.0)},
		"%s/summaries" % pipeline_path)
	if nonfinite_summary_path != "":
		ok = _assert(false, "Wave-B scenario '%s' step %d has non-finite summary value at %s." % [scenario_name, step_index, nonfinite_summary_path]) and ok
	if not _assert(field_evolution is Dictionary, "Wave-B scenario '%s' step %d should expose a field_evolution dictionary." % [scenario_name, step_index]):
		return false
	var updated_fields := field_evolution.get("updated_fields", {})
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
	var payload_a: Dictionary = _build_wave_a_obstacle_motion_payload(ordered_rows)
	var payload_b: Dictionary = _build_wave_a_obstacle_motion_payload(reordered_rows)
	var result_a: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload_a)
	var result_b: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload_b)
	var mass_a := _extract_updated_mass(result_a)
	var mass_b := _extract_updated_mass(result_b)
	var boundary_a := _extract_stage_boundary(result_a, "pressure")
	var boundary_b := _extract_stage_boundary(result_b, "pressure")
	var ok := true
	ok = _assert(_arrays_equal(mass_a, mass_b, 1.0e-12), "Reordered obstacle-motion contact rows should produce identical mass updates.") and ok
	ok = _assert(_assert_boundary_payloads_match(boundary_a, boundary_b, 1.0e-12), "Reordered obstacle-motion contact rows should produce deterministic boundary diagnostics.") and ok
	return ok

func _test_obstacle_motion_scale_affects_boundary_effect(core: Object) -> bool:
	core.call("reset")
	var obstacle_rows := [_build_obstacle_motion_row_for_scale_test()]
	var baseline_payload := _build_wave_a_obstacle_motion_payload(obstacle_rows, 0.35)
	var scaled_payload := _build_wave_a_obstacle_motion_payload(obstacle_rows, 0.35, 0.75)
	var baseline_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, baseline_payload)
	var scaled_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, scaled_payload)
	var baseline_boundary := _extract_stage_boundary(baseline_result, "pressure")
	var scaled_boundary := _extract_stage_boundary(scaled_result, "pressure")
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

func _build_wave_a_obstacle_motion_payload(rows: Array, obstacle_attenuation: float, moving_obstacle_speed_scale: Variant = null) -> Dictionary:
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

func _extract_stage_boundary(step_result: Dictionary, stage_name: String) -> Dictionary:
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload for boundary extraction.")
		return {}
	var stages: Array = pipeline.get(stage_name, [])
	if typeof(stages) != TYPE_ARRAY:
		push_error("Wave-A continuity step result missing '%s' stage array for boundary extraction." % stage_name)
		return {}
	if stages.is_empty():
		push_error("Wave-A continuity step result has empty '%s' stage array for boundary extraction." % stage_name)
		return {}
	var stage_payload_variant = stages[0]
	if typeof(stage_payload_variant) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result '%s' stage payload is invalid for boundary extraction." % stage_name)
		return {}
	var boundary: Dictionary = stage_payload_variant.get("boundary", {})
	if typeof(boundary) != TYPE_DICTIONARY:
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
	if not _assert(boundary.has(key), "Boundary payload missing '%s'." % key):
		return false
	return _assert(
		absf(float(boundary.get(key, 0.0)) - expected) <= tolerance,
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
			"mass_field": BASE_MASS.duplicate(true),
			"pressure_field": BASE_PRESSURE.duplicate(true),
			"temperature_field": BASE_TEMPERATURE.duplicate(true),
			"velocity_field": BASE_VELOCITY.duplicate(true),
			"density_field": BASE_DENSITY.duplicate(true),
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
		}
	}

func _build_transport_neighborhood_payload(topology: Array) -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"mass_field": TRANSPORT_MASS.duplicate(true),
			"pressure_field": TRANSPORT_PRESSURE.duplicate(true),
			"temperature_field": TRANSPORT_TEMPERATURE.duplicate(true),
			"velocity_field": TRANSPORT_VELOCITY.duplicate(true),
			"density_field": TRANSPORT_DENSITY.duplicate(true),
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
				"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
			},
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
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
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
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
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
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
				"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
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
