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
	ok = _test_boundary_condition_contracts_present() and ok
	ok = _test_porous_flow_contracts_present() and ok
	ok = _test_phase_change_contracts_present() and ok
	ok = _test_shock_impulse_contracts_present() and ok
	ok = _test_friction_contact_contracts_present() and ok
	if ok:
		print("Native generalized physics source contracts passed (stage domains, conservation diagnostics, and generalized physics terms).")
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
	ok = _assert(source.contains("\"stage_type\", String(\"mechanics\")"), "Mechanics runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"pressure\")"), "Pressure runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"thermal\")"), "Thermal runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"reaction\")"), "Reaction runner must stamp stage_type") and ok
	ok = _assert(source.contains("\"stage_type\", String(\"destruction\")"), "Destruction runner must stamp stage_type") and ok
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
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary boundary_contract(const Dictionary &stage_config, const Dictionary &frame_inputs)"), "Pipeline must define reusable boundary contract helper") and ok
	ok = _assert(source.contains("const String mode = (mode_raw == \"closed\" || mode_raw == \"reflective\") ? mode_raw : String(\"open\");"), "Boundary contract must normalize to open/closed/reflective modes") and ok
	ok = _assert(source.contains("if (mode == \"closed\") {"), "Boundary contract must define closed boundary mode behavior") and ok
	ok = _assert(source.contains("} else if (mode == \"reflective\") {"), "Boundary contract must define reflective boundary mode behavior") and ok
	ok = _assert(source.contains("\"directional_multiplier\", directional_multiplier,"), "Boundary contract payload must include directional_multiplier") and ok
	ok = _assert(source.contains("\"scalar_multiplier\", std::abs(directional_multiplier)"), "Boundary contract payload must include scalar_multiplier") and ok
	return ok

func _test_porous_flow_contracts_present() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double permeability = clamped(stage_config.get(\"permeability\", 0.0), 0.0, 1.0e3, 0.0);"), "Pressure stage must include permeability term for porous flow") and ok
	ok = _assert(source.contains("const double dynamic_viscosity = clamped(stage_config.get(\"dynamic_viscosity\", 1.0), 1.0e-9, 1.0e9, 1.0);"), "Pressure stage must include dynamic viscosity term for Darcy flow") and ok
	ok = _assert(source.contains("const double porosity = clamped(stage_config.get(\"porosity\", 0.0), 0.0, 1.0, 0.0);"), "Pressure stage must include porosity term") and ok
	ok = _assert(source.contains("const double darcy_velocity = -(permeability / dynamic_viscosity) * pressure_gradient;"), "Pressure stage must include Darcy velocity equation") and ok
	ok = _assert(source.contains("const double seepage_flux = porosity * darcy_velocity * boundary_dir;"), "Pressure stage must include boundary-coupled seepage flux") and ok
	ok = _assert(source.contains("const double seepage_density_rate = -density * seepage_flux * seepage_coupling;"), "Pressure stage must include seepage density coupling term") and ok
	ok = _assert(source.contains("\"darcy_velocity\", darcy_velocity,"), "Pressure result payload must include darcy_velocity") and ok
	ok = _assert(source.contains("\"seepage_flux\", seepage_flux,"), "Pressure result payload must include seepage_flux") and ok
	return ok

func _test_phase_change_contracts_present() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double melt_extent = std::min(std::max(0.0, 1.0 - liquid_fraction), std::max(0.0, temperature - melting_point) * phase_response * delta_seconds);"), "Thermal stage must include melt_extent phase-transition term") and ok
	ok = _assert(source.contains("const double freeze_extent = std::min(liquid_fraction, std::max(0.0, melting_point - temperature) * phase_response * delta_seconds);"), "Thermal stage must include freeze_extent phase-transition term") and ok
	ok = _assert(source.contains("const double boil_extent = std::min(std::max(0.0, 1.0 - vapor_fraction), std::max(0.0, temperature - boiling_point) * phase_response * delta_seconds);"), "Thermal stage must include boil_extent phase-transition term") and ok
	ok = _assert(source.contains("const double condense_extent = std::min(vapor_fraction, std::max(0.0, boiling_point - temperature) * phase_response * delta_seconds);"), "Thermal stage must include condense_extent phase-transition term") and ok
	ok = _assert(source.contains("\"phase_change\", Dictionary::make(\"melt_extent\", melt_extent, \"freeze_extent\", freeze_extent, \"boil_extent\", boil_extent,"), "Thermal stage result must expose phase_change payload") and ok
	ok = _assert(source.contains("const double phase_change_extent = std::min("), "Reaction stage must compute phase_change_extent") and ok
	ok = _assert(source.contains("const double phase_change_latent_energy = phase_change_extent * latent_heat_phase_change;"), "Reaction stage must compute phase_change latent energy") and ok
	ok = _assert(source.contains("\"phase_change\", Dictionary::make(\"phase_change_extent\", phase_change_extent, \"latent_energy_consumed\", phase_change_latent_energy),"), "Reaction stage result must expose phase_change payload") and ok
	return ok

func _test_shock_impulse_contracts_present() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double shock_impulse = clamped(frame_inputs.get(\"shock_impulse\", stage_config.get(\"shock_impulse\", 0.0)), -1.0e9, 1.0e9, 0.0);"), "Mechanics/pressure stages must accept shock_impulse inputs") and ok
	ok = _assert(source.contains("const double shock_distance = clamped(frame_inputs.get(\"shock_distance\", stage_config.get(\"shock_distance\", 0.0)), 0.0, 1.0e9, 0.0);"), "Mechanics/pressure stages must accept shock_distance inputs") and ok
	ok = _assert(source.contains("const double shock_decay = std::exp(-shock_attenuation * shock_distance);"), "Shock handling must include exponential attenuation") and ok
	ok = _assert(source.contains("const double shock_force = shock_impulse_effective / std::max(1.0e-6, delta_seconds);"), "Mechanics stage must convert impulse into force") and ok
	ok = _assert(source.contains("const double shock_pressure_term = shock_impulse * shock_decay * shock_pressure_gain * boundary_scalar;"), "Pressure stage must include shock pressure coupling term") and ok
	ok = _assert(source.contains("\"shock_force\", shock_force,"), "Mechanics result payload must include shock_force") and ok
	ok = _assert(source.contains("\"shock_pressure_term\", shock_pressure_term,"), "Pressure result payload must include shock_pressure_term") and ok
	return ok

func _test_friction_contact_contracts_present() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const double normal_force = clamped(frame_inputs.get(\"normal_force\", stage_config.get(\"normal_force\", mass * 9.81)), 0.0, 1.0e12, mass * 9.81);"), "Destruction stage must include normal_force contact term") and ok
	ok = _assert(source.contains("const double contact_velocity = clamped(frame_inputs.get(\"contact_velocity\", stage_config.get(\"contact_velocity\", 0.0)), -1.0e6, 1.0e6, 0.0);"), "Destruction stage must include contact_velocity term") and ok
	ok = _assert(source.contains("const double friction_static_mu = clamped(stage_config.get(\"friction_static_mu\", 0.6), 0.0, 10.0, 0.6);"), "Destruction stage must include static friction coefficient") and ok
	ok = _assert(source.contains("const double friction_dynamic_mu = clamped(stage_config.get(\"friction_dynamic_mu\", 0.4), 0.0, 10.0, 0.4);"), "Destruction stage must include dynamic friction coefficient") and ok
	ok = _assert(source.contains("const bool sliding = std::abs(tangential_load) > static_limit;"), "Destruction stage must compute sliding/contact regime") and ok
	ok = _assert(source.contains("const double friction_force = sliding"), "Destruction stage must compute friction_force from sliding mode") and ok
	ok = _assert(source.contains("const double friction_dissipation = std::abs(friction_force * contact_velocity) * delta_seconds;"), "Destruction stage must include friction dissipation energy") and ok
	ok = _assert(source.contains("\"friction_force\", friction_force, \"friction_dissipation\", friction_dissipation,"), "Destruction result payload must expose friction/contact fields") and ok
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
