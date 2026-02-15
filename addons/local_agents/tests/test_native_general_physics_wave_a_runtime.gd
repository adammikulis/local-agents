@tool
extends RefCounted

const ExtensionLoader: Script = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimeParams: Script = preload("res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime_constants.gd")
const RuntimeLogic: Script = preload("res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime_logic.gd")

const PIPELINE_STAGE_NAME := RuntimeParams.PIPELINE_STAGE_NAME
const HOT_FIELDS := RuntimeParams.HOT_FIELDS
const HANDLE_MODE_OPTIONAL_SUMMARY_KEYS := RuntimeParams.HANDLE_MODE_OPTIONAL_SUMMARY_KEYS
const HANDLE_MODE_RESOLVED_SOURCE := RuntimeParams.HANDLE_MODE_RESOLVED_SOURCE
const HANDLE_MODE_EXPECTED_REFS := RuntimeParams.HANDLE_MODE_EXPECTED_REFS
const TRANSPORT_TOPOLOGY_ORDER_A := RuntimeParams.TRANSPORT_TOPOLOGY_ORDER_A
const TRANSPORT_TOPOLOGY_ORDER_B := RuntimeParams.TRANSPORT_TOPOLOGY_ORDER_B
const TRANSPORT_TOPOLOGY_INVALID_A := RuntimeParams.TRANSPORT_TOPOLOGY_INVALID_A
const TRANSPORT_TOPOLOGY_INVALID_B := RuntimeParams.TRANSPORT_TOPOLOGY_INVALID_B
const TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES := RuntimeParams.TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES
const WAVE_B_REGRESSION_STEPS := RuntimeParams.WAVE_B_REGRESSION_STEPS
const WAVE_B_REPEATED_LOAD_STEPS := RuntimeParams.WAVE_B_REPEATED_LOAD_STEPS

func run_test(_tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for Wave-A continuity test.")
		return false

	var core: Object = Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null.")
		return false

	var runtime: RefCounted = RuntimeLogic.new()
	if not runtime._assert(bool(core.call("configure", {})), "LocalAgentsSimulationCore.configure() must succeed for test setup."):
		return false
	core.call("reset")

	var first_payload: Dictionary = runtime._build_payload()
	var second_payload: Dictionary = first_payload.duplicate(true)
	var first_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, first_payload)
	var second_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, second_payload)
	var ok := true
	ok = runtime._assert(runtime._assert_physics_server_feedback_contract(first_result, "baseline scalar pre-reset", 0), "Baseline scalar pre-reset step should expose valid physics_server_feedback output.") and ok
	ok = runtime._assert(runtime._assert_physics_server_feedback_contract(second_result, "baseline scalar pre-reset", 1), "Baseline scalar pre-reset follow-up step should expose valid physics_server_feedback output.") and ok
	ok = runtime._assert(String(runtime._extract_field_handle_metadata_value(first_result, "field_handle_mode")) == "scalar", "Baseline scalar input should report field_handle_mode=scalar.")
	ok = runtime._assert(String(runtime._extract_field_handle_metadata_value(second_result, "field_handle_mode")) == "scalar", "Follow-up scalar input should report field_handle_mode=scalar.")
	var first_diagnostics: Dictionary = runtime._extract_stage_field_input_diagnostics(first_result)
	ok = runtime._assert(runtime._assert_hot_field_resolution(first_diagnostics, HOT_FIELDS, true, false, false, "scalar", "", "frame_inputs_scalar"), "Base payload without handles should resolve hot fields from frame inputs.") and ok

	var first_mass: Array = runtime._extract_updated_mass(first_result)
	var second_mass: Array = runtime._extract_updated_mass(second_result)
	var override_payload: Dictionary = runtime._build_override_payload()
	var third_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, override_payload)
	ok = runtime._assert(runtime._assert_physics_server_feedback_contract(third_result, "baseline scalar override", 2), "Override scalar step should expose valid physics_server_feedback output.") and ok
	var third_mass: Array = runtime._extract_updated_mass(third_result)
	var override_diagnostics: Dictionary = runtime._extract_stage_field_input_diagnostics(third_result)
	ok = runtime._assert(runtime._assert_hot_field_resolution(override_diagnostics, HOT_FIELDS, true, false, false, "scalar", "", "field_buffers"), "Override payload hot fields should resolve from continuity field_buffers when handles are absent.") and ok
	ok = runtime._assert(runtime._assert_summary_key_set_stability(first_result, third_result, []), "Scalar-mode summary key set should stay stable across scalar-only execution transitions.")
	core.call("reset")
	var reset_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, runtime._build_payload())
	var reset_mass: Array = runtime._extract_updated_mass(reset_result)
	if not runtime._assert(first_mass.size() == first_payload.get("inputs").get("mass_field").size(), "First step must emit mass update arrays."):
		return false
	if not runtime._assert(second_mass.size() == first_payload.get("inputs").get("mass_field").size(), "Second step must emit mass update arrays."):
		return false
	if not runtime._assert(third_mass.size() == first_payload.get("inputs").get("mass_field").size(), "Third step with explicit field_buffers override must emit mass update arrays."):
		return false

	ok = runtime._assert(not runtime._arrays_equal(first_mass, second_mass), "Second execute_step must consume prior step updated fields, not restart from the unchanged input snapshot.") and ok
	ok = runtime._assert(not runtime._arrays_equal(first_mass, first_payload.get("inputs").get("mass_field")), "First execute_step should evolve mass fields from its initial snapshot.") and ok
	ok = runtime._assert(not runtime._arrays_equal(second_mass, first_payload.get("inputs").get("mass_field")), "Second execute_step should also evolve from prior fields, not initial mass snapshot.") and ok
	ok = runtime._assert(not runtime._arrays_equal(first_mass, third_mass), "Third execute_step should reflect explicit `field_buffers` override inputs.") and ok
	ok = runtime._assert(third_mass[0] > 0.0, "Third execute_step result should be valid with explicit field buffer override input.") and ok
	ok = runtime._assert(not runtime._arrays_equal(third_mass, reset_mass), "Reset should clear carried continuity so subsequent execution reuses input snapshot baseline.") and ok
	ok = runtime._assert(runtime._assert_summary_key_set_stability(first_result, reset_result, []), "Summary key set should remain stable when returning to scalar mode after reset.")
	ok = runtime._assert(String(runtime._extract_field_handle_metadata_value(reset_result, "field_handle_mode")) == "scalar", "Reset-to-scalar input should report field_handle_mode=scalar.")
	core.call("reset")
	var handle_result: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_handle_first_payload())
	ok = runtime._assert(runtime._assert_physics_server_feedback_contract(handle_result, "handle-first", 0), "Handle-first step should expose valid physics_server_feedback output.") and ok
	var handle_diagnostics: Dictionary = runtime._extract_stage_field_input_diagnostics(handle_result)
	ok = runtime._assert(runtime._assert_hot_handle_field_diagnostics(handle_diagnostics, HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Handle-first hot fields should resolve via handle with no scalar fallback.") and ok
	ok = runtime._assert(String(runtime._extract_field_handle_metadata_value(handle_result, "field_handle_mode")) == "field_handles", "Handle-first input should report field_handle_mode=field_handles.")
	ok = runtime._assert(runtime._assert_summary_key_set_stability(first_result, handle_result, HANDLE_MODE_OPTIONAL_SUMMARY_KEYS), "Summary key set should stay stable across scalar->field_handle mode transitions.")
	ok = runtime._assert(runtime._extract_field_handle_metadata_value(handle_result, "field_handle_marker") != null, "Handle mode should include deterministic field_handle_marker.")
	ok = runtime._assert(runtime._extract_field_handle_metadata_value(handle_result, "field_handle_io") != null, "Handle mode should include field_handle_io.")
	var handle_mass: Array = runtime._extract_updated_mass(handle_result)
	var handle_chain_result: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_handle_chain_payload())
	ok = runtime._assert(String(runtime._extract_field_handle_metadata_value(handle_chain_result, "field_handle_mode")) == "field_handles", "Handle-chain input should still be executed in field_handles mode.")
	var handle_chain_diagnostics: Dictionary = runtime._extract_stage_field_input_diagnostics(handle_chain_result)
	var handle_chain_mass: Array = runtime._extract_updated_mass(handle_chain_result)
	ok = runtime._assert(runtime._assert_hot_handle_field_diagnostics(handle_chain_diagnostics, HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Chained handle payload should continue resolve hot fields via handle without fallback.") and ok
	ok = runtime._assert(runtime._assert_hot_handle_field_diagnostics(runtime._extract_field_evolution_handle_resolution_diagnostics(handle_chain_result).get("by_field", {}), HOT_FIELDS, HANDLE_MODE_RESOLVED_SOURCE, HANDLE_MODE_EXPECTED_REFS), "Chained handle step continuity should remain handle mode in field_evolution.") and ok
	var handle_mass_sum: float = runtime._sum_numeric_array(handle_mass)
	var handle_chain_mass_sum: float = runtime._sum_numeric_array(handle_chain_mass)
	var handle_mass_mean: float = runtime._mean_numeric_array(handle_mass)
	var handle_chain_mass_mean: float = runtime._mean_numeric_array(handle_chain_mass)
	ok = runtime._assert(handle_mass_sum == handle_mass_sum && handle_mass_sum != INF && handle_mass_sum != -INF, "Handle-mode mass sum should remain finite.") and ok
	ok = runtime._assert(handle_chain_mass_sum == handle_chain_mass_sum && handle_chain_mass_sum != INF && handle_chain_mass_sum != -INF, "Handle-chain mass sum should remain finite.") and ok
	ok = runtime._assert(handle_mass_mean == handle_mass_mean && handle_mass_mean != INF && handle_mass_mean != -INF, "Handle-mode mass mean should remain finite.") and ok
	ok = runtime._assert(handle_chain_mass_mean == handle_chain_mass_mean && handle_chain_mass_mean != INF && handle_chain_mass_mean != -INF, "Handle-chain mass mean should remain finite.") and ok
	ok = runtime._assert(runtime._assert_numeric_array_sum_and_mean_equivalence(handle_mass, handle_chain_mass, 1.0e-12), "Handle-mode chaining should preserve aggregate mass in field_handles continuity.") and ok
	var missing_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, runtime._build_missing_handles_payload())
	var missing_diag: Dictionary = runtime._extract_stage_field_input_diagnostics(missing_result)
	ok = runtime._assert(runtime._assert_hot_field_resolution(missing_diag, HOT_FIELDS, false, false, false, "missing", "field_handles"), "Invalid handles without compatibility should be missing for all hot fields.") and ok
	var compat_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, runtime._build_scalar_compat_fallback_payload())
	var compat_diag: Dictionary = runtime._extract_stage_field_input_diagnostics(compat_result)
	ok = runtime._assert(runtime._assert_hot_field_resolution(compat_diag, HOT_FIELDS, true, false, true, "scalar_fallback", "scalar_fallback", "frame_inputs_scalar"), "Compatibility-mode invalid-handle payload should trigger explicit scalar fallback diagnostics for all hot fields.") and ok
	core.call("reset")
	var scalar_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, runtime._build_payload())
	var scalar_field_evolution: Dictionary = runtime._extract_field_evolution_handle_resolution_diagnostics(scalar_result)
	var scalar_by_field: Dictionary = scalar_field_evolution.get("by_field", {})
	var scalar_mass_diag: Dictionary = scalar_by_field.get("mass", {})
	ok = runtime._assert(String(scalar_mass_diag.get("mode", "")) == "scalar", "Scalar-only field evolution should mark mass mode as scalar.") and ok
	ok = runtime._assert(not bool(scalar_mass_diag.get("resolved_via_handle", false)), "Scalar-only field evolution should not resolve via handle.") and ok
	var scalar_fallback_found: bool = runtime._has_scalar_fallback_used(compat_diag)
	ok = runtime._assert(scalar_fallback_found, "Scalar fallback path should mark at least one hot field with fallback diagnostics.") and ok
	core.call("reset")
	var transport_result_a: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_ORDER_A))
	var transport_result_b: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_ORDER_B))
	ok = runtime._assert(
		runtime._assert_transport_payload_equivalence(
			transport_result_a,
			transport_result_b,
			1.0e-12),
		"Transport neighbor edge-order permutations must produce identical updated fields and pair update summaries.") and ok
	var transport_invalid_a: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_INVALID_A))
	var transport_invalid_b: Dictionary = core.call(
		"execute_environment_stage",
		PIPELINE_STAGE_NAME,
		runtime._build_transport_neighborhood_payload(TRANSPORT_TOPOLOGY_INVALID_B))
	ok = runtime._assert(
		runtime._assert_transport_invalid_edge_regression(
			transport_invalid_a,
			transport_invalid_b,
			TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES,
			1.0e-12),
		"Transport neighbor topologies with invalid edge entries must be deterministic and avoid NaN/extra pair updates.") and ok
	ok = runtime._assert(runtime._test_reordered_contact_rows_with_obstacle_motion(core), "Reordered obstacle-motion contact rows should not affect simulation determinism.") and ok
	ok = runtime._assert(runtime._test_obstacle_motion_scale_affects_boundary_effect(core), "Moving-obstacle speed scaling should impact effective_obstacle_attenuation while default scale keeps it unchanged.") and ok

	if ok:
		ok = runtime._assert(runtime._test_wave_b_regression_scenarios(core), "Wave-A regression coverage for impact/flood/fire/cooling/collapse/mixed-material should be deterministic, finite, and key-stable.") and ok
		ok = runtime._assert(runtime._test_repeated_load_terrain_stability(core), "Wave-A terrain repeated-load stability should stay bounded and replay-coherent after reset.") and ok
		print("Wave-A continuity runtime test passed for two-step field-buffer carry and row-260/263 regression coverage.")
	return ok
