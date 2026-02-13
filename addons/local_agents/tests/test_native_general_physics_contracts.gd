@tool
extends RefCounted

const PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_pipeline_declares_all_generalized_stage_domains() and ok
	ok = _test_stage_dispatch_and_summary_contracts_cover_all_domains() and ok
	ok = _test_stage_results_include_conservation_payload_contract() and ok
	ok = _test_conservation_diagnostics_fields_contract() and ok
	ok = _test_core_equation_contracts_present() and ok
	if ok:
		print("Native generalized physics source contracts passed (stage domains + conservation diagnostics).")
	return ok

func _test_pipeline_declares_all_generalized_stage_domains() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
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
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("run_mechanics_stage(stage_variant, frame_inputs, delta_seconds)"), "Pipeline must execute mechanics stage runner") and ok
	ok = _assert(source.contains("run_pressure_stage(stage_variant, frame_inputs, delta_seconds)"), "Pipeline must execute pressure stage runner") and ok
	ok = _assert(source.contains("run_thermal_stage(stage_variant, frame_inputs, delta_seconds)"), "Pipeline must execute thermal stage runner") and ok
	ok = _assert(source.contains("run_reaction_stage(stage_variant, frame_inputs, delta_seconds)"), "Pipeline must execute reaction stage runner") and ok
	ok = _assert(source.contains("run_destruction_stage(stage_variant, frame_inputs, delta_seconds)"), "Pipeline must execute destruction stage runner") and ok
	ok = _assert(source.contains("summary[\"mechanics\"] = mechanics_results;"), "Summary must include mechanics stage results") and ok
	ok = _assert(source.contains("summary[\"pressure\"] = pressure_results;"), "Summary must include pressure stage results") and ok
	ok = _assert(source.contains("summary[\"thermal\"] = thermal_results;"), "Summary must include thermal stage results") and ok
	ok = _assert(source.contains("summary[\"reaction\"] = reaction_results;"), "Summary must include reaction stage results") and ok
	ok = _assert(source.contains("summary[\"destruction\"] = destruction_results;"), "Summary must include destruction stage results") and ok
	ok = _assert(source.contains("summary[\"stage_counts\"] = Dictionary::make("), "Summary must include per-domain stage_counts dictionary") and ok
	return ok

func _test_stage_results_include_conservation_payload_contract() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("result[\"stage_type\"] = String(\"mechanics\");"), "Mechanics runner must stamp stage_type") and ok
	ok = _assert(source.contains("result[\"stage_type\"] = String(\"pressure\");"), "Pressure runner must stamp stage_type") and ok
	ok = _assert(source.contains("result[\"stage_type\"] = String(\"thermal\");"), "Thermal runner must stamp stage_type") and ok
	ok = _assert(source.contains("result[\"stage_type\"] = String(\"reaction\");"), "Reaction runner must stamp stage_type") and ok
	ok = _assert(source.contains("result[\"stage_type\"] = String(\"destruction\");"), "Destruction runner must stamp stage_type") and ok
	ok = _assert(source.contains("result[\"conservation\"] = Dictionary::make("), "Each stage runner must emit conservation payload") and ok
	ok = _assert(source.contains("\"mass_proxy_delta\""), "Conservation payload must include mass_proxy_delta") and ok
	ok = _assert(source.contains("\"energy_proxy_delta\""), "Conservation payload must include energy_proxy_delta") and ok
	ok = _assert(source.contains("\"energy_proxy_metric\""), "Conservation payload must include energy_proxy_metric") and ok
	return ok

func _test_conservation_diagnostics_fields_contract() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
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

func _test_core_equation_contracts_present() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double density_rate = -density * velocity_divergence + density_source - density_sink;"), "Pressure stage must include continuity equation density_rate term") and ok
	ok = _assert(source.contains("const double pressure_eos = eos_gamma * density_next * eos_r * temperature;"), "Pressure stage must include EOS closure pressure_eos") and ok
	ok = _assert(source.contains("const double eos_term = eos_relaxation_gain * (pressure_eos - pressure);"), "Pressure stage must include EOS relaxation term") and ok
	ok = _assert(source.contains("const double heat_rate = conduction_flux + advection_flux - cooling_flux - radiative_flux + internal_heat;"), "Thermal stage must include conduction, advection, cooling, and radiative terms") and ok
	ok = _assert(source.contains("const double radiative_flux = emissivity * stefan_boltzmann * (t4 - ta4);"), "Thermal stage must include radiative cooling law term") and ok
	ok = _assert(source.contains("const double arrhenius_exponent = std::clamp(-activation_energy * inv_rt, -700.0, 0.0);"), "Reaction stage must include Arrhenius exponent") and ok
	ok = _assert(source.contains("const double arrhenius_k = pre_exponential_factor * std::exp(arrhenius_exponent);"), "Reaction stage must include Arrhenius rate constant") and ok
	ok = _assert(source.contains("const double kinetic_extent = arrhenius_k * temp_factor * pressure_factor * delta_seconds;"), "Reaction stage must gate kinetics by Arrhenius + pressure + temperature factors") and ok
	ok = _assert(source.contains("const double net_force = force + pressure_force + body_force_term + external_force - drag_force - viscous_force;"), "Mechanics stage must include momentum-form force balance terms") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
