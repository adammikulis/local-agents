@tool
extends RefCounted

const SIM_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/src/sim"
const PIPELINE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/sim/CoreSimulationPipeline.hpp"
const LEGACY_PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp"
const INTERNAL_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp"
const BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"
const NativeComputeBridgeScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const NativeComputeBridgeEnvironmentBindingsScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeEnvironmentBindings.gd")
const WaveAInvariantChecks := preload("res://addons/local_agents/tests/test_native_general_physics_wave_a_contracts.gd")

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_pipeline_declares_all_generalized_stage_domains() and ok
	ok = _test_stage_dispatch_and_summary_contracts_cover_all_domains() and ok
	ok = _test_stage_results_include_conservation_payload_contract() and ok
	ok = _test_conservation_diagnostics_fields_contract() and ok
	ok = _test_mass_energy_step_drift_bound_contracts() and ok
	ok = _test_mass_energy_overall_drift_bound_contracts() and ok
	ok = _test_wave_a_invariant_contracts(_tree) and ok
	ok = _test_field_handle_summary_and_diagnostics_contract() and ok
	ok = _test_optional_field_evolution_summary_keys_contract() and ok
	ok = _test_field_evolution_invariant_and_stage_coupling_contract() and ok
	ok = _test_core_equation_contracts_present() and ok
	ok = _test_boundary_condition_contracts_present() and ok
	ok = _test_porous_flow_contracts_present() and ok
	ok = _test_phase_change_contracts_present() and ok
	ok = _test_shock_impulse_contracts_present() and ok
	ok = _test_friction_contact_contracts_present() and ok
	ok = _test_bridge_declares_contact_canonical_input_fields() and ok
	ok = _test_bridge_contact_aggregation_behavior() and ok
	ok = _test_wave_a_coupling_pressure_to_mechanics_contract() and ok
	ok = _test_wave_a_coupling_reaction_to_thermal_contract() and ok
	ok = _test_wave_a_coupling_damage_to_voxel_ops_contract() and ok
	ok = _test_pipeline_feedback_contract() and ok
	if ok:
		print("Native generalized physics source contracts passed (stage domains, conservation diagnostics, and generalized physics terms).")
	return ok

func _test_pipeline_declares_all_generalized_stage_domains() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("mechanics_stages_ = config.get(\"mechanics_stages\""), "Pipeline config must declare mechanics stages") and ok
	ok = _assert(source.contains("pressure_stages_ = config.get(\"pressure_stages\""), "Pipeline config must declare pressure stages") and ok
	ok = _assert(source.contains("thermal_stages_ = config.get(\"thermal_stages\""), "Pipeline config must declare thermal stages") and ok
	ok = _assert(source.contains("reaction_stages_ = config.get(\"reaction_stages\""), "Pipeline config must declare reaction stages") and ok
	ok = _assert(source.contains("destruction_stages_ = config.get(\"destruction_stages\""), "Pipeline config must declare destruction stages") and ok
	return ok

func _test_stage_dispatch_and_summary_contracts_cover_all_domains() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var pipeline_header := _read_source(PIPELINE_HPP_PATH)
	if pipeline_header == "":
		return false
	var pipeline_cpp := _read_source(LEGACY_PIPELINE_CPP_PATH)
	if pipeline_cpp == "":
		return false

	var ok := true
	for stage_name in ["mechanics", "pressure", "thermal", "reaction", "destruction"]:
		var method_name := "run_%s_stage" % stage_name
		var arg_count := _extract_stage_runner_param_count(pipeline_header, method_name)
		ok = _assert(arg_count > 0, "Pipeline header must declare %s runner signature." % method_name) and ok
		ok = _assert(_has_stage_runner_call_with_arity(pipeline_cpp, method_name, arg_count), "Pipeline must execute %s stage runner." % stage_name) and ok
	ok = _assert(source.contains("summary[\"mechanics\"] = mechanics_results;"), "Summary must include mechanics stage results") and ok
	ok = _assert(source.contains("summary[\"pressure\"] = pressure_results;"), "Summary must include pressure stage results") and ok
	ok = _assert(source.contains("summary[\"thermal\"] = thermal_results;"), "Summary must include thermal stage results") and ok
	ok = _assert(source.contains("summary[\"reaction\"] = reaction_results;"), "Summary must include reaction stage results") and ok
	ok = _assert(source.contains("summary[\"destruction\"] = destruction_results;"), "Summary must include destruction stage results") and ok
	ok = _assert(
		_contains_any(source, ["summary[\"stage_counts\"] = Dictionary::make(", "summary[\"stage_counts\"] = unified_pipeline::make_dictionary("]),
		"Summary must include per-domain stage_counts dictionary"
	) and ok
	return ok

func _test_stage_results_include_conservation_payload_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("\"stage_type\", String(\"mechanics\")"), "Mechanics runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"pressure\")"), "Pressure runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"thermal\")"), "Thermal runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"reaction\")"), "Reaction runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"destruction\")"), "Destruction runner must stamp stage_type") and ok
	ok = _assert(
		_contains_any(source, ["result[\"conservation\"] = Dictionary::make(", "result[\"conservation\"] = unified_pipeline::make_dictionary("]),
		"Each stage runner must emit conservation payload"
	) and ok
	ok = _assert(source.contains("\"mass_proxy_delta\""), "Conservation payload must include mass_proxy_delta") and ok
	ok = _assert(source.contains("\"energy_proxy_delta\""), "Conservation payload must include energy_proxy_delta") and ok
	ok = _assert(source.contains("\"energy_proxy_metric\""), "Conservation payload must include energy_proxy_metric") and ok
	return ok

func _test_conservation_diagnostics_fields_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("total[\"count\"] = static_cast<int64_t>(0);"), "Conservation stage totals must track count") and ok
	ok = _assert(source.contains("total[\"mass_proxy_delta_sum\"] = 0.0;"), "Conservation stage totals must track mass_proxy_delta_sum") and ok
	ok = _assert(source.contains("total[\"energy_proxy_delta_sum\"] = 0.0;"), "Conservation stage totals must track energy_proxy_delta_sum") and ok
	ok = _assert(source.contains("conservation_diagnostics[\"by_stage_type\"] = by_stage_type;"), "Summary must include by_stage_type diagnostics") and ok
	ok = _assert(source.contains("append_conservation(stage_totals, \"mechanics\", stage_result);"), "Diagnostics must append mechanics conservation") and ok
	ok = _assert(source.contains("append_conservation(stage_totals, \"pressure\", stage_result);"), "Diagnostics must append pressure conservation") and ok
	ok = _assert(source.contains("append_conservation(stage_totals, \"thermal\", stage_result);"), "Diagnostics must append thermal conservation") and ok
	ok = _assert(source.contains("append_conservation(stage_totals, \"reaction\", stage_result);"), "Diagnostics must append reaction conservation") and ok
	ok = _assert(source.contains("append_conservation(stage_totals, \"destruction\", stage_result);"), "Diagnostics must append destruction conservation") and ok
	ok = _assert(source.contains("aggregate_overall_conservation(conservation_diagnostics);"), "Diagnostics must aggregate overall conservation") and ok
	ok = _assert(source.contains("\"stage_count\", stage_count,"), "Overall diagnostics must include stage_count") and ok
	ok = _assert(source.contains("\"mass_proxy_delta_total\", mass_total,"), "Overall diagnostics must include mass_proxy_delta_total") and ok
	ok = _assert(source.contains("\"energy_proxy_delta_total\", energy_total"), "Overall diagnostics must include energy_proxy_delta_total") and ok
	ok = _assert(source.contains("summary[\"conservation_diagnostics\"] = conservation_diagnostics;"), "Summary must publish conservation_diagnostics") and ok
	return ok

func _test_field_handle_summary_and_diagnostics_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const String field_handle_mode = field_handles_provided ? String(\"field_handles\") : String(\"scalar\");"), "Pipeline must derive deterministic field_handle_mode") and ok
	ok = _assert(source.contains("conservation_diagnostics[\"field_handle_mode\"] = field_handle_mode;"), "Conservation diagnostics must expose field_handle_mode") and ok
	ok = _assert(source.contains("conservation_diagnostics[\"field_handle_count\"] = field_handle_count;"), "Conservation diagnostics must expose field_handle_count") and ok
	ok = _assert(source.contains("summary[\"field_handle_mode\"] = field_handle_mode;"), "Summary must expose field_handle_mode") and ok
	ok = _assert(source.contains("summary[\"field_handle_count\"] = field_handle_count;"), "Summary must expose field_handle_count") and ok
	ok = _assert(source.contains("field_handle_marker = String(\"field_handles:v1|count=\") + String::num_int64(field_handle_count);"), "Field-handle marker contract must include deterministic prefix and count") and ok
	ok = _assert(source.contains("conservation_diagnostics[\"field_handle_marker\"] = field_handle_marker;"), "Conservation diagnostics must expose field_handle_marker when handles are provided") and ok
	ok = _assert(source.contains("summary[\"field_handle_marker\"] = field_handle_marker;"), "Summary must expose field_handle_marker when handles are provided") and ok
	ok = _assert(source.contains("conservation_diagnostics[\"field_handle_io\"] = field_handle_io;"), "Conservation diagnostics must expose field_handle_io when handles are provided") and ok
	ok = _assert(source.contains("summary[\"field_handle_io\"] = field_handle_io;"), "Summary must expose field_handle_io when handles are provided") and ok
	return ok

func _test_optional_field_evolution_summary_keys_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false

	var mentions_field_evolution := source.contains("field_mass_drift_proxy") or source.contains("field_energy_drift_proxy") or source.contains("field_cell_count_updated")
	if not mentions_field_evolution:
		return true

	var ok := true
	ok = _assert(_contains_summary_key_contract(source, "field_mass_drift_proxy"), "Field evolution summary must expose field_mass_drift_proxy when field evolution keys are present") and ok
	ok = _assert(_contains_summary_key_contract(source, "field_energy_drift_proxy"), "Field evolution summary must expose field_energy_drift_proxy when field evolution keys are present") and ok
	ok = _assert(_contains_summary_key_contract(source, "field_cell_count_updated"), "Field evolution summary must expose field_cell_count_updated when field evolution keys are present") and ok
	return ok

func _test_field_evolution_invariant_and_stage_coupling_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("summary[\"field_mass_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"mass_drift_proxy\", 0.0), -1.0e18, 1.0e18, 0.0);"), "Summary must expose field_mass_drift_proxy invariant proxy") and ok
	ok = _assert(source.contains("summary[\"field_energy_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"energy_drift_proxy\", 0.0), -1.0e18, 1.0e18, 0.0);"), "Summary must expose field_energy_drift_proxy invariant proxy") and ok
	ok = _assert(source.contains("\"mass_drift_proxy\", mass_drift_proxy"), "Field evolution should expose bounded mass_drift_proxy") and ok
	ok = _assert(source.contains("\"energy_drift_proxy\", energy_drift_proxy"), "Field evolution should expose bounded energy_drift_proxy") and ok
	ok = _assert(source.contains("\"pair_updates\", pair_updates,"), "Field evolution must publish pair_updates stage-coupling marker") and ok
	ok = _assert(source.contains("result[\"updated_fields\"] = unified_pipeline::make_dictionary("), "Field evolution must publish updated_fields coupling payload") and ok
	var has_stage_coupling := source.contains("\"stage_coupling\"")
	var has_coupling_markers := source.contains("\"coupling_markers\"")
	if has_stage_coupling:
		ok = _assert(_contains_direct_summary_key_contract(source, "stage_coupling"), "Summary must expose stage_coupling when stage_coupling marker is present") and ok
	if has_coupling_markers:
		ok = _assert(_contains_direct_summary_key_contract(source, "coupling_markers"), "Summary must expose coupling_markers when coupling markers are present") and ok
	return ok

func _test_mass_energy_step_drift_bound_contracts() -> bool:
	var internal_source := _read_source(INTERNAL_CPP_PATH)
	if internal_source == "":
		return false
	var ok := true
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double mass_delta = clamped(conservation.get(\"mass_proxy_delta\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"const double mass_delta = clamped(conservation.get(\"mass_proxy_delta\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Per-step mass drift must be clamped before accumulation."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double energy_delta = clamped(conservation.get(\"energy_proxy_delta\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"const double energy_delta = clamped(conservation.get(\"energy_proxy_delta\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Per-step energy drift must be clamped before accumulation."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double previous_mass_sum = clamped(stage_total.get(\"mass_proxy_delta_sum\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"const double previous_mass_sum = clamped(stage_total.get(\"mass_proxy_delta_sum\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Per-step mass sum accumulation must read bounded history."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double previous_energy_sum = clamped(stage_total.get(\"energy_proxy_delta_sum\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"const double previous_energy_sum = clamped(stage_total.get(\"energy_proxy_delta_sum\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Per-step energy sum accumulation must read bounded history."
	) and ok
	return ok

func _test_mass_energy_overall_drift_bound_contracts() -> bool:
	var internal_source := _read_source(INTERNAL_CPP_PATH)
	if internal_source == "":
		return false
	var pipeline_source := _read_source(LEGACY_PIPELINE_CPP_PATH)
	if pipeline_source == "":
		return false
	var ok := true
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"mass_total += clamped(stage_total.get(\"mass_proxy_delta_sum\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"mass_total += clamped(stage_total.get(\"mass_proxy_delta_sum\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Overall mass drift total must aggregate bounded per-stage sums."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"energy_total += clamped(stage_total.get(\"energy_proxy_delta_sum\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"energy_total += clamped(stage_total.get(\"energy_proxy_delta_sum\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Overall energy drift total must aggregate bounded per-stage sums."
	) and ok
	ok = _assert(
		_contains_any(
			pipeline_source,
			[
				"summary[\"field_mass_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"mass_drift_proxy\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"summary[\"field_mass_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"mass_drift_proxy\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Step summary must clamp field mass drift proxy."
	) and ok
	ok = _assert(
		_contains_any(
			pipeline_source,
			[
				"summary[\"field_energy_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"energy_drift_proxy\", 0.0), -1.0e18, 1.0e18, 0.0);",
				"summary[\"field_energy_drift_proxy\"] = unified_pipeline::clamped(field_evolution.get(\"energy_drift_proxy\", 0.0), -1e18, 1e18, 0.0);"
			]
		),
		"Step summary must clamp field energy drift proxy."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"diagnostics[\"overall\"] = unified_pipeline::make_dictionary(",
				"diagnostics[\"overall\"] = Dictionary::make("
			]
		),
		"Summary must expose bounded overall conservation totals."
	) and ok
	return ok

func _test_wave_a_invariant_contracts(_tree: SceneTree) -> bool:
	var checks = WaveAInvariantChecks.new()
	return checks.run_test(_tree)

func _test_wave_a_coupling_pressure_to_mechanics_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("markers.append(String(\"pressure->mechanics\"))"), "Wave A coupling markers must include pressure->mechanics") and ok
	ok = _assert(source.contains("stage_coupling[\"pressure->mechanics\"] = unified_pipeline::make_dictionary("), "Wave A must expose pressure->mechanics coupling mapping") and ok
	ok = _assert(source.contains("\"marker\", String(\"pressure->mechanics\"),"), "pressure->mechanics mapping must stamp marker field") and ok
	ok = _assert(source.contains("\"wave\", String(\"A\")"), "pressure->mechanics mapping must identify Wave A") and ok
	ok = _assert(source.contains("\"source_stage\", String(\"pressure\")"), "pressure->mechanics mapping must identify pressure as source stage") and ok
	ok = _assert(source.contains("\"target_stage\", String(\"mechanics\")"), "pressure->mechanics mapping must identify mechanics as target stage") and ok
	ok = _assert(source.contains("\"scalar\", pressure_to_mechanics"), "pressure->mechanics mapping must surface pressure_to_mechanics scalar") and ok
	ok = _assert(source.contains("\"pressure_to_mechanics_scalar\", pressure_to_mechanics"), "pressure->mechanics scalar diagnostics must publish pressure_to_mechanics_scalar") and ok
	return ok

func _test_wave_a_coupling_reaction_to_thermal_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("markers.append(String(\"reaction->thermal\"))"), "Wave A coupling markers must include reaction->thermal") and ok
	ok = _assert(source.contains("stage_coupling[\"reaction->thermal\"] = unified_pipeline::make_dictionary("), "Wave A must expose reaction->thermal coupling mapping") and ok
	ok = _assert(source.contains("\"marker\", String(\"reaction->thermal\"),"), "reaction->thermal mapping must stamp marker field") and ok
	ok = _assert(source.contains("\"wave\", String(\"A\")"), "reaction->thermal mapping must identify Wave A") and ok
	ok = _assert(source.contains("\"source_stage\", String(\"reaction\")"), "reaction->thermal mapping must identify reaction as source stage") and ok
	ok = _assert(source.contains("\"target_stage\", String(\"thermal\")"), "reaction->thermal mapping must identify thermal as target stage") and ok
	ok = _assert(source.contains("\"scalar\", reaction_to_thermal"), "reaction->thermal mapping must surface reaction_to_thermal scalar") and ok
	ok = _assert(source.contains("\"reaction_to_thermal_scalar\", reaction_to_thermal"), "reaction->thermal scalar diagnostics must publish reaction_to_thermal_scalar") and ok
	return ok

func _test_wave_a_coupling_damage_to_voxel_ops_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("markers.append(String(\"damage->voxel\"))"), "Wave A coupling markers must include damage->voxel") and ok
	ok = _assert(source.contains("stage_coupling[\"damage->voxel\"] = unified_pipeline::make_dictionary("), "Wave A must expose damage->voxel coupling mapping for voxel ops") and ok
	ok = _assert(source.contains("\"marker\", String(\"damage->voxel\"),"), "damage->voxel mapping must stamp marker field") and ok
	ok = _assert(source.contains("\"wave\", String(\"A\")"), "damage->voxel mapping must identify Wave A") and ok
	ok = _assert(source.contains("\"source_stage\", String(\"damage\")"), "damage->voxel ops mapping must identify damage as source stage") and ok
	ok = _assert(source.contains("\"target_stage\", String(\"voxel\")"), "damage->voxel ops mapping must identify voxel ops as target stage") and ok
	ok = _assert(source.contains("\"scalar\", damage_to_voxel"), "damage->voxel mapping must surface damage_to_voxel scalar") and ok
	ok = _assert(source.contains("\"damage_to_voxel_scalar\", damage_to_voxel"), "damage->voxel scalar diagnostics must publish damage_to_voxel_scalar") and ok
	return ok

func _test_pipeline_feedback_contract() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(
		source.contains("summary[\"physics_server_feedback\"] = summarize_physics_server_feedback(destruction_results, field_evolution);"),
		"Pipeline summary should expose physics_server_feedback bridge payload."
	) and ok
	ok = _assert(source.contains("feedback[\"schema\"] = String(\"physics_server_feedback_v1\");"), "Physics-server feedback summary should declare schema.") and ok
	ok = _assert(source.contains("feedback[\"enabled\"] = !destruction_results.is_empty() || field_evolution.has(\"updated_fields\");"), "Physics-server feedback should expose enabled flag from destruction/field_evolution state.") and ok
	ok = _assert(source.contains("feedback[\"has_feedback\"] = active_destruction_stages > 0;"), "Physics-server feedback should expose has_feedback flag from destruction stages.") and ok
	ok = _assert(source.contains("feedback[\"destruction_stage_count\"] = static_cast<int64_t>(destruction_results.size());"), "Feedback should expose destruction_stage_count.") and ok
	ok = _assert(source.contains("\"destruction_feedback_count\", active_destruction_stages"), "Feedback should expose destruction_feedback_count.") and ok
	ok = _assert(source.contains("\"coupling_markers_present\""), "Feedback should expose coupling_markers_present flag.") and ok
	ok = _assert(source.contains("feedback[\"destruction\"] = unified_pipeline::make_dictionary("), "Feedback should expose destruction summary aggregate.") and ok
	ok = _assert(source.contains("\"friction_abs_force_max\""), "Destruction feedback should include friction_abs_force_max.") and ok
	ok = _assert(source.contains("\"friction_dissipation_total\""), "Destruction feedback should include friction_dissipation_total.") and ok
	ok = _assert(source.contains("\"fracture_energy_total\""), "Destruction feedback should include fracture_energy_total.") and ok
	ok = _assert(source.contains("\"resistance_avg\""), "Destruction feedback should include resistance_avg.") and ok
	ok = _assert(source.contains("\"resistance_max\""), "Destruction feedback should include resistance_max.") and ok
	ok = _assert(source.contains("feedback[\"failure_coupling\"] = unified_pipeline::make_dictionary("), "Feedback should expose failure_coupling mapping block.") and ok
	ok = _assert(source.contains("damage_to_voxel_scalar"), "Failure coupling should include damage_to_voxel_scalar.") and ok
	ok = _assert(source.contains("pressure_to_mechanics_scalar"), "Failure coupling should include pressure_to_mechanics_scalar.") and ok
	ok = _assert(source.contains("reaction_to_thermal_scalar"), "Failure coupling should include reaction_to_thermal_scalar.") and ok
	ok = _assert(source.contains("\"resistance\", resistance_proxy"), "Destruction stage result should expose resistance feedback value.") and ok
	ok = _assert(source.contains("\"resistance_raw\", resistance"), "Destruction stage result should expose resistance_raw compatibility fallback.") and ok
	ok = _assert(source.contains("\"failure_status\", failure_status"), "Destruction stage result should expose failure_status.") and ok
	ok = _assert(source.contains("\"failure_reason\", failure_reason"), "Destruction stage result should expose failure_reason.") and ok
	ok = _assert(source.contains("\"failure_mode\", failure_mode"), "Destruction stage result should expose failure_mode.") and ok
	ok = _assert(source.contains("\"friction_state\", friction_state"), "Destruction stage result should expose friction_state.") and ok
	ok = _assert(source.contains("\"friction_state_code\", friction_state_code"), "Destruction stage result should expose friction_state_code.") and ok
	ok = _assert(source.contains("\"overstress_ratio\", normalized_overstress_ratio"), "Destruction stage result should expose overstress_ratio.") and ok
	ok = _assert(source.contains("feedback[\"failure_feedback\"]"), "Physics-server feedback should expose failure_feedback block.") and ok
	ok = _assert(source.contains("feedback[\"failure_source\"]"), "Physics-server feedback should expose failure_source block.") and ok
	ok = _assert(source.contains("feedback[\"voxel_emission\"]"), "Physics-server feedback should expose voxel_emission block.") and ok
	return ok

func _test_core_equation_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double density_rate = -density * velocity_divergence + density_source - density_sink + seepage_density_rate;"), "Pressure stage must include continuity equation density_rate term with seepage coupling") and ok
	ok = _assert(source.contains("const double pressure_eos = eos_gamma * density_next * eos_r * temperature;"), "Pressure stage must include EOS closure pressure_eos") and ok
	ok = _assert(source.contains("const double eos_term = eos_relaxation_gain * (pressure_eos - pressure);"), "Pressure stage must include EOS relaxation term") and ok
	ok = _assert(source.contains("const double heat_rate = (conduction_flux + advection_flux) * boundary_scalar - cooling_flux - radiative_flux + internal_heat"), "Thermal stage must include boundary-scaled conduction/advection plus cooling and radiative terms") and ok
	ok = _assert(source.contains("const double radiative_flux = emissivity * stefan_boltzmann * (t4 - ta4);"), "Thermal stage must include radiative cooling law term") and ok
	ok = _assert(source.contains("const double arrhenius_exponent = std::clamp(-activation_energy * inv_rt, -700.0, 0.0);"), "Reaction stage must include Arrhenius exponent") and ok
	ok = _assert(source.contains("const double arrhenius_k = pre_exponential_factor * std::exp(arrhenius_exponent);"), "Reaction stage must include Arrhenius rate constant") and ok
	ok = _assert(source.contains("const double kinetic_extent = arrhenius_k * temp_factor * pressure_factor * delta_seconds;"), "Reaction stage must gate kinetics by Arrhenius + pressure + temperature factors") and ok
	ok = _assert(source.contains("const double net_force = force + directional_force + body_force_term - drag_force - viscous_force;"), "Mechanics stage must include momentum-form force balance terms including directional force") and ok
	return ok

func _test_boundary_condition_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary boundary_contract(const Dictionary &stage_config, const Dictionary &frame_inputs)"), "Pipeline must define reusable boundary contract helper") and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"const String mode_raw = String(frame_inputs.get(\"boundary_mode\", stage_config.get(\"boundary_mode\", \"open\"))).to_lower().strip_edges();",
				"const String mode_raw = String(frame_inputs.get(\"boundary_mode\", stage_config.get(\"boundary_mode\", \"open\"))).to_lower();"
			]
		),
		"Boundary contract must lower-case and normalize raw boundary mode input."
	) and ok
	ok = _assert(source.contains("if (mode_raw == \"open\" || mode_raw == \"inflow/outflow\") {"), "Boundary contract must canonicalize inflow/outflow to open mode") and ok
	ok = _assert(source.contains("else if (mode_raw == \"reflective\") {"), "Boundary contract must canonicalize reflective mode") and ok
	ok = _assert(source.contains("else if (mode_raw == \"no-slip\" || mode_raw == \"no-penetration\") {"), "Boundary contract must canonicalize no-slip and no-penetration modes") and ok
	ok = _assert(source.contains("mode = String(\"open\");"), "Boundary contract must default unknown modes to open") and ok
	ok = _assert(source.contains("if (mode == \"no-slip\" || mode == \"no-penetration\") {"), "Boundary contract must define no-slip/no-penetration boundary mode behavior") and ok
	ok = _assert(source.contains("} else if (mode == \"reflective\") {"), "Boundary contract must define reflective boundary mode behavior") and ok
	ok = _assert(source.contains("const double obstacle_velocity = std::abs(as_number(frame_inputs.get(\"obstacle_velocity\", stage_config.get(\"obstacle_velocity\", 0.0)), 0.0));"), "Boundary contract must read obstacle_velocity and apply magnitude") and ok
	ok = _assert(_contains_any(source, ["const double moving_obstacle_speed_scale = clamped(", "const double moving_obstacle_speed_scale = unified_pipeline::clamped("]), "Boundary contract must read moving_obstacle_speed_scale with fallback 0 and clamp") and ok
	ok = _assert(source.contains("const double effective_obstacle_attenuation = std::clamp(obstacle_attenuation + obstacle_velocity * moving_obstacle_speed_scale, 0.0, 1.0);"), "Boundary contract must compute effective obstacle attenuation in backward-safe form") and ok
	ok = _assert(source.contains("double directional_multiplier = (1.0 - effective_obstacle_attenuation) * constraint_factor;"), "Boundary contract must apply directional multiplier using effective obstacle attenuation") and ok
	ok = _assert(source.contains("\"obstacle_attenuation\", obstacle_attenuation,"), "Boundary diagnostics should include obstacle_attenuation") and ok
	ok = _assert(source.contains("\"obstacle_velocity\", obstacle_velocity,"), "Boundary diagnostics should include obstacle_velocity") and ok
	ok = _assert(source.contains("\"obstacle_trajectory\", obstacle_trajectory,"), "Boundary diagnostics should include obstacle_trajectory") and ok
	ok = _assert(source.contains("\"moving_obstacle_speed_scale\", moving_obstacle_speed_scale,"), "Boundary diagnostics should include moving_obstacle_speed_scale") and ok
	ok = _assert(source.contains("\"effective_obstacle_attenuation\", effective_obstacle_attenuation,"), "Boundary diagnostics should include effective_obstacle_attenuation") and ok
	ok = _assert(source.contains("\"directional_multiplier\", directional_multiplier,"), "Boundary contract payload must include directional_multiplier") and ok
	ok = _assert(source.contains("\"scalar_multiplier\", std::abs(directional_multiplier)"), "Boundary contract payload must include scalar_multiplier") and ok
	return ok

func _test_porous_flow_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(
		_contains_any(source, ["const double permeability = clamped(stage_config.get(\"permeability\", 0.0), 0.0, 1.0e3, 0.0);", "const double permeability = unified_pipeline::clamped(stage_config.get(\"permeability\", 0.0), 0.0, 1.0e3, 0.0);"]),
		"Pressure stage must include permeability term for porous flow"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double dynamic_viscosity = clamped(stage_config.get(\"dynamic_viscosity\", 1.0), 1.0e-9, 1.0e9, 1.0);", "const double dynamic_viscosity = unified_pipeline::clamped(stage_config.get(\"dynamic_viscosity\", 1.0), 1.0e-9, 1.0e9, 1.0);"]),
		"Pressure stage must include dynamic viscosity term for Darcy flow"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double porosity = clamped(stage_config.get(\"porosity\", 0.0), 0.0, 1.0, 0.0);", "const double porosity = unified_pipeline::clamped(stage_config.get(\"porosity\", 0.0), 0.0, 1.0, 0.0);"]),
		"Pressure stage must include porosity term"
	) and ok
	ok = _assert(source.contains("const double darcy_velocity = -(permeability / dynamic_viscosity) * pressure_gradient;"), "Pressure stage must include Darcy velocity equation") and ok
	ok = _assert(source.contains("const double seepage_flux = porosity * darcy_velocity * boundary_dir;"), "Pressure stage must include boundary-coupled seepage flux") and ok
	ok = _assert(source.contains("const double seepage_density_rate = -density * seepage_flux * seepage_coupling;"), "Pressure stage must include seepage density coupling term") and ok
	ok = _assert(source.contains("\"darcy_velocity\", darcy_velocity,"), "Pressure result payload must include darcy_velocity") and ok
	ok = _assert(source.contains("\"seepage_flux\", seepage_flux,"), "Pressure result payload must include seepage_flux") and ok
	return ok

func _test_phase_change_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double melt_extent = std::min(std::max(0.0, 1.0 - liquid_fraction), std::max(0.0, temperature - melting_point) * phase_response * delta_seconds);"), "Thermal stage must include melt_extent phase-transition term") and ok
	ok = _assert(source.contains("const double freeze_extent = std::min(liquid_fraction, std::max(0.0, melting_point - temperature) * phase_response * delta_seconds);"), "Thermal stage must include freeze_extent phase-transition term") and ok
	ok = _assert(source.contains("const double boil_extent = std::min(std::max(0.0, 1.0 - vapor_fraction), std::max(0.0, temperature - boiling_point) * phase_response * delta_seconds);"), "Thermal stage must include boil_extent phase-transition term") and ok
	ok = _assert(source.contains("const double condense_extent = std::min(vapor_fraction, std::max(0.0, boiling_point - temperature) * phase_response * delta_seconds);"), "Thermal stage must include condense_extent phase-transition term") and ok
	ok = _assert(
		_contains_any(source, ["\"phase_change\", Dictionary::make(\"melt_extent\", melt_extent, \"freeze_extent\", freeze_extent, \"boil_extent\", boil_extent,", "\"phase_change\", unified_pipeline::make_dictionary(\"melt_extent\", melt_extent, \"freeze_extent\", freeze_extent, \"boil_extent\", boil_extent,"]),
		"Thermal stage result must expose phase_change payload"
	) and ok
	ok = _assert(source.contains("const double phase_change_extent = std::min("), "Reaction stage must compute phase_change_extent") and ok
	ok = _assert(source.contains("const double phase_change_latent_energy = phase_change_extent * latent_heat_phase_change;"), "Reaction stage must compute phase_change latent energy") and ok
	ok = _assert(
		_contains_any(source, ["\"phase_change\", Dictionary::make(\"phase_change_extent\", phase_change_extent, \"latent_energy_consumed\", phase_change_latent_energy),", "\"phase_change\", unified_pipeline::make_dictionary(\"phase_change_extent\", phase_change_extent, \"latent_energy_consumed\", phase_change_latent_energy),"]),
		"Reaction stage result must expose phase_change payload"
	) and ok
	return ok

func _test_shock_impulse_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(
		_contains_any(source, ["const double shock_impulse = clamped(stage_field_inputs.get(\"shock_impulse\", stage_config.get(\"shock_impulse\", 0.0)), -1.0e9, 1.0e9, 0.0);", "const double shock_impulse = unified_pipeline::clamped(stage_field_inputs.get(\"shock_impulse\", stage_config.get(\"shock_impulse\", 0.0)), -1.0e9, 1.0e9, 0.0);"]),
		"Mechanics/pressure stages must accept shock_impulse inputs"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double shock_distance = clamped(stage_field_inputs.get(\"shock_distance\", stage_config.get(\"shock_distance\", 0.0)), 0.0, 1.0e9, 0.0);", "const double shock_distance = unified_pipeline::clamped(stage_field_inputs.get(\"shock_distance\", stage_config.get(\"shock_distance\", 0.0)), 0.0, 1.0e9, 0.0);"]),
		"Mechanics/pressure stages must accept shock_distance inputs"
	) and ok
	ok = _assert(source.contains("const double shock_decay = std::exp(-shock_attenuation * shock_distance);"), "Shock handling must include exponential attenuation") and ok
	ok = _assert(source.contains("const double shock_force = shock_impulse_effective / std::max(1.0e-6, delta_seconds);"), "Mechanics stage must convert impulse into force") and ok
	ok = _assert(source.contains("const double shock_pressure_term = shock_impulse * shock_decay * shock_pressure_gain * boundary_scalar;"), "Pressure stage must include shock pressure coupling term") and ok
	ok = _assert(source.contains("\"shock_force\", shock_force,"), "Mechanics result payload must include shock_force") and ok
	ok = _assert(source.contains("\"shock_pressure_term\", shock_pressure_term,"), "Pressure result payload must include shock_pressure_term") and ok
	return ok

func _test_friction_contact_contracts_present() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(
		_contains_any(source, ["const double normal_force = clamped(stage_field_inputs.get(\"normal_force\", stage_config.get(\"normal_force\", mass * 9.81)), 0.0, 1.0e12, mass * 9.81);", "const double normal_force = unified_pipeline::clamped(stage_field_inputs.get(\"normal_force\", stage_config.get(\"normal_force\", mass * 9.81)), 0.0, 1.0e12, mass * 9.81);"]),
		"Destruction stage must include normal_force contact term"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double contact_velocity = clamped(stage_field_inputs.get(\"contact_velocity\", stage_config.get(\"contact_velocity\", 0.0)), -1.0e6, 1.0e6, 0.0);", "const double contact_velocity = unified_pipeline::clamped(stage_field_inputs.get(\"contact_velocity\", stage_config.get(\"contact_velocity\", 0.0)), -1.0e6, 1.0e6, 0.0);"]),
		"Destruction stage must include contact_velocity term"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double friction_static_mu = clamped(stage_config.get(\"friction_static_mu\", 0.6), 0.0, 10.0, 0.6);", "const double friction_static_mu = unified_pipeline::clamped(stage_config.get(\"friction_static_mu\", 0.6), 0.0, 10.0, 0.6);"]),
		"Destruction stage must include static friction coefficient"
	) and ok
	ok = _assert(
		_contains_any(source, ["const double friction_dynamic_mu = clamped(stage_config.get(\"friction_dynamic_mu\", 0.4), 0.0, 10.0, 0.4);", "const double friction_dynamic_mu = unified_pipeline::clamped(stage_config.get(\"friction_dynamic_mu\", 0.4), 0.0, 10.0, 0.4);"]),
		"Destruction stage must include dynamic friction coefficient"
	) and ok
	ok = _assert(source.contains("const bool sliding = std::abs(tangential_load) > static_limit;"), "Destruction stage must compute sliding/contact regime") and ok
	ok = _assert(source.contains("const double friction_force = sliding"), "Destruction stage must compute friction_force from sliding mode") and ok
	ok = _assert(source.contains("const double friction_dissipation = std::abs(friction_force * contact_velocity) * delta_seconds;"), "Destruction stage must include friction dissipation energy") and ok
	ok = _assert(source.contains("\"friction_force\", friction_force, \"friction_dissipation\", friction_dissipation,"), "Destruction result payload must expose friction/contact fields") and ok
	return ok

func _test_bridge_declares_contact_canonical_input_fields() -> bool:
	var payload := {
		"phase": "liquid",
		"contact_samples": [
			{
				"id": 44,
				"normal_impulse": 5.0,
			},
			{
				"id": 21,
				"normal_impulse": 2.0,
			},
		],
	}
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload(payload)
	var contacts := NativeComputeBridgeScript._normalize_physics_contacts_from_payload(payload)
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var identity_variant = normalized.get("material_identity", {})
	var identity: Dictionary = identity_variant if identity_variant is Dictionary else {}
	var ok := true
	ok = _assert(contacts.size() == 2, "Bridge must preserve contact rows for native ingestion.") and ok
	ok = _assert(
		normalized.get("physics_server_contacts", []) is Array and int((normalized.get("physics_server_contacts", []) as Array).size()) == 2,
		"Bridge payload normalization should expose contact rows on physics_server_contacts."
	) and ok
	ok = _assert(
		normalized.get("physics_contacts", []) is Array and int((normalized.get("physics_contacts", []) as Array).size()) == 2,
		"Bridge payload normalization should mirror contact rows on physics_contacts."
	) and ok
	ok = _assert(String(inputs.get("material_phase_id", "")) == "phase:liquid", "Bridge should canonicalize material_phase_id on normalized inputs.") and ok
	ok = _assert(String(identity.get("material_phase_id", "")) == "phase:liquid", "Bridge should expose canonicalized phase id on material_identity.") and ok
	ok = _assert(not inputs.has("contact_impulse"), "Bridge should not synthesize aggregate contact inputs before native snapshot binding.") and ok
	return ok

func _test_bridge_contact_aggregation_behavior() -> bool:
	var payload := {
		"phase": "solid",
		"contact_samples": [
			{
				"body_id": 88,
				"contact_impulse": 3.0,
			},
			{
				"normal_impulse": 7.0,
			},
		],
	}
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload(payload)
	var bound: Dictionary = NativeComputeBridgeEnvironmentBindingsScript.apply_native_contact_snapshot(
		normalized,
		{
			"total_impulse": 29.0,
			"average_relative_speed": 3.75,
			"buffered_rows": [
				{"body_id": 101, "normal_impulse": 13.0},
				{"body_id": 102, "normal_impulse": 16.0},
			],
		}
	)
	var inputs_variant = bound.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var physics_contacts_variant = bound.get("physics_contacts", {})
	var physics_contacts: Dictionary = physics_contacts_variant if physics_contacts_variant is Dictionary else {}
	var physics_rows_variant = bound.get("physics_server_contacts", [])
	var physics_rows: Array = physics_rows_variant if physics_rows_variant is Array else []
	var ok := true
	ok = _assert(_is_approx(float(inputs.get("contact_impulse", 0.0)), 29.0), "Bridge should bind native snapshot total_impulse to contact_impulse.") and ok
	ok = _assert(_is_approx(float(inputs.get("contact_velocity", 0.0)), 3.75), "Bridge should bind native snapshot average_relative_speed to contact_velocity.") and ok
	ok = _assert(
		physics_contacts.get("buffered_rows", []) is Array and int((physics_contacts.get("buffered_rows", []) as Array).size()) == 2,
		"Bridge should preserve native snapshot payload in physics_contacts."
	) and ok
	ok = _assert(physics_rows.size() == 2, "Bridge should surface native buffered rows on physics_server_contacts after snapshot binding.") and ok
	ok = _assert(String(inputs.get("material_phase_id", "")) == "phase:solid", "Bridge should preserve material identity fields while binding native snapshot contacts.") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-4) -> bool:
	return absf(lhs - rhs) <= epsilon

func _contains_summary_key_contract(source: String, key: String) -> bool:
	var direct_key := "summary[\"%s\"]" % key
	var nested_key := "\"%s\"" % key
	return source.contains(direct_key) or (source.contains("summary[\"field_evolution\"]") and source.contains(nested_key))

func _contains_direct_summary_key_contract(source: String, key: String) -> bool:
	var direct_key := "summary[\"%s\"]" % key
	return source.contains(direct_key)

func _contains_any(source: String, needles: Array[String]) -> bool:
	for needle in needles:
		if source.contains(needle):
			return true
	return false

func _extract_stage_runner_param_count(source: String, function_name: String) -> int:
	var marker := "%s(" % function_name
	var marker_pos := source.find(marker)
	if marker_pos < 0:
		return -1
	var args := _extract_parenthesized_args(source, marker_pos)
	return _count_csv_args(args)

func _has_stage_runner_call_with_arity(source: String, function_name: String, expected_arity: int) -> bool:
	var marker := "%s(" % function_name
	var search_pos := 0
	while true:
		var marker_pos := source.find(marker, search_pos)
		if marker_pos < 0:
			return false
		search_pos = marker_pos + marker.length()
		if marker_pos >= 2 and source.substr(marker_pos - 2, 2) == "::":
			continue
		var args := _extract_parenthesized_args(source, marker_pos)
		if args == "":
			continue
		if _count_csv_args(args) == expected_arity:
			return true
	return false

func _extract_parenthesized_args(source: String, marker_pos: int) -> String:
	var open := source.find("(", marker_pos)
	if open < 0:
		return ""
	var depth := 1
	var idx := open + 1
	while idx < source.length():
		var ch := source.substr(idx, 1)
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return source.substr(open + 1, idx - open - 1)
		idx += 1
	return ""

func _count_csv_args(arg_text: String) -> int:
	var args := arg_text.strip_edges()
	if args == "":
		return 0
	var depth := 0
	var in_single_quote := false
	var in_double_quote := false
	var was_escape := false
	var count := 1
	var idx := 0
	while idx < args.length():
		var ch := args.substr(idx, 1)
		if was_escape:
			was_escape = false
		elif ch == "\\":
			was_escape = true
		elif ch == "'" and not in_double_quote:
			in_single_quote = not in_single_quote
		elif ch == "\"" and not in_single_quote:
			in_double_quote = not in_double_quote
		elif not in_single_quote and not in_double_quote:
			if ch == "(" or ch == "[" or ch == "{":
				depth += 1
			elif ch == ")" or ch == "]" or ch == "}":
				depth = max(depth - 1, 0)
			elif ch == "," and depth == 0:
				count += 1
		idx += 1
	return count

func _read_pipeline_sources() -> String:
	var files := _list_sim_source_files()
	if files.is_empty():
		return ""

	var combined := PackedStringArray()
	for path in files:
		var source := _read_source(path)
		if source == "":
			return ""
		combined.append("// file: %s\n%s" % [path, source])
	return "\n".join(combined)

func _list_sim_source_files() -> PackedStringArray:
	var files := PackedStringArray()
	var sim_dir := DirAccess.open(SIM_SOURCE_DIR)
	if sim_dir == null:
		_assert(false, "Failed to open sim source dir: %s" % SIM_SOURCE_DIR)
		files.append(LEGACY_PIPELINE_CPP_PATH)
		return files

	sim_dir.list_dir_begin()
	var entry := sim_dir.get_next()
	while entry != "":
		if not sim_dir.current_is_dir() and (entry.ends_with(".cpp") or entry.ends_with(".hpp")):
			files.append("%s/%s" % [SIM_SOURCE_DIR, entry])
		entry = sim_dir.get_next()
	sim_dir.list_dir_end()

	files.sort()
	if files.is_empty():
		files.append(LEGACY_PIPELINE_CPP_PATH)
	return files

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
