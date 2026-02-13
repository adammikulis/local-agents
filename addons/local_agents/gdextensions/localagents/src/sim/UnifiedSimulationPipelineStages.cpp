#include "sim/UnifiedSimulationPipeline.hpp"

#include "sim/UnifiedSimulationPipelineInternal.hpp"

#include <algorithm>
#include <cmath>

using namespace godot;

namespace local_agents::simulation {

Dictionary UnifiedSimulationPipeline::run_mechanics_stage(const Dictionary &stage_config, const Dictionary &stage_field_inputs, double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "mechanics"));

    const double mass = unified_pipeline::clamped(stage_field_inputs.get("mass", stage_config.get("mass", 1.0)), 1.0e-6, 1.0e9, 1.0);
    const double force = unified_pipeline::clamped(stage_field_inputs.get("force", stage_config.get("force", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double density = unified_pipeline::clamped(stage_field_inputs.get("density", stage_config.get("density", 1.0)), 1.0e-6, 1.0e9, 1.0);
    const double pressure_gradient = unified_pipeline::clamped(
        stage_field_inputs.get("pressure_gradient", stage_config.get("pressure_gradient", 0.0)),
        -1.0e9,
        1.0e9,
        0.0);
    const double external_force = unified_pipeline::clamped(stage_field_inputs.get("external_force", stage_config.get("external_force", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double body_force = unified_pipeline::clamped(stage_field_inputs.get("body_force", stage_config.get("body_force", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double damping = unified_pipeline::clamped(stage_config.get("damping", 0.0), 0.0, 100.0, 0.0);
    const double viscosity = unified_pipeline::clamped(stage_config.get("viscosity", 0.0), 0.0, 1.0e6, 0.0);
    const double velocity = unified_pipeline::clamped(stage_field_inputs.get("velocity", stage_config.get("velocity", 0.0)), -1.0e6, 1.0e6, 0.0);
    const double position = unified_pipeline::clamped(stage_field_inputs.get("position", stage_config.get("position", 0.0)), -1.0e12, 1.0e12, 0.0);
    const double shock_impulse = unified_pipeline::clamped(stage_field_inputs.get("shock_impulse", stage_config.get("shock_impulse", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double shock_distance = unified_pipeline::clamped(stage_field_inputs.get("shock_distance", stage_config.get("shock_distance", 0.0)), 0.0, 1.0e9, 0.0);
    const double shock_attenuation = unified_pipeline::clamped(stage_config.get("shock_attenuation", 0.0), 0.0, 1.0e3, 0.0);
    const double shock_gain = unified_pipeline::clamped(stage_config.get("shock_gain", 1.0), -1.0e6, 1.0e6, 1.0);
    const Dictionary boundary = unified_pipeline::boundary_contract(stage_config, stage_field_inputs);
    const double boundary_dir = unified_pipeline::clamped(boundary.get("directional_multiplier", 1.0), -1.0, 1.0, 1.0);

    const double pressure_force = -pressure_gradient;
    const double body_force_term = density * body_force;
    const double drag_force = damping * velocity;
    const double viscous_force = viscosity * velocity;
    const double shock_decay = std::exp(-shock_attenuation * shock_distance);
    const double shock_impulse_effective = shock_impulse * shock_decay * shock_gain;
    const double shock_force = shock_impulse_effective / std::max(1.0e-6, delta_seconds);
    const double directional_force = (pressure_force + external_force + shock_force) * boundary_dir;
    const double net_force = force + directional_force + body_force_term - drag_force - viscous_force;
    const double acceleration = net_force / mass;
    const double velocity_delta = acceleration * delta_seconds;
    const double velocity_next = velocity + velocity_delta;
    const double displacement_delta = velocity_next * delta_seconds;
    const double position_next = position + displacement_delta;
    const double momentum_before = mass * velocity;
    const double momentum_after = mass * velocity_next;
    const double momentum_delta = momentum_after - momentum_before;

    const double kinetic_energy_before = 0.5 * mass * velocity * velocity;
    const double kinetic_energy_after = 0.5 * mass * velocity_next * velocity_next;
    const double energy_delta = kinetic_energy_after - kinetic_energy_before;

    Dictionary result = unified_pipeline::make_dictionary(
        "stage_type", String("mechanics"), "stage", stage_name, "ok", true, "mass", mass, "density", density, "pressure_force", pressure_force,
        "boundary", boundary, "body_force_term", body_force_term, "shock_decay", shock_decay, "shock_impulse_effective", shock_impulse_effective,
        "shock_force", shock_force, "viscous_force", viscous_force, "drag_force", drag_force, "net_force", net_force, "acceleration", acceleration,
        "velocity", velocity, "velocity_delta", velocity_delta, "velocity_next", velocity_next, "position", position,
        "displacement_delta", displacement_delta, "position_next", position_next, "momentum_delta", momentum_delta);
    result["conservation"] = unified_pipeline::make_dictionary("mass_proxy_delta", 0.0, "energy_proxy_delta", energy_delta, "energy_proxy_metric", String("kinetic_energy"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_pressure_stage(const Dictionary &stage_config, const Dictionary &stage_field_inputs, double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "pressure"));

    const double pressure = unified_pipeline::clamped(stage_field_inputs.get("pressure", stage_config.get("pressure", 1.0)), 0.0, 1.0e9, 1.0);
    const double density = unified_pipeline::clamped(stage_field_inputs.get("density", stage_config.get("density", 1.0)), 1.0e-6, 1.0e9, 1.0);
    const double temperature = unified_pipeline::clamped(stage_field_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double velocity_divergence = unified_pipeline::clamped(stage_field_inputs.get("velocity_divergence", stage_config.get("velocity_divergence", 0.0)), -1.0e4, 1.0e4, 0.0);
    const double pressure_gradient = unified_pipeline::clamped(stage_field_inputs.get("pressure_gradient", stage_config.get("pressure_gradient", 0.0)), -1.0e9, 1.0e9, 0.0);
    const Dictionary boundary = unified_pipeline::boundary_contract(stage_config, stage_field_inputs);
    const double boundary_dir = unified_pipeline::clamped(boundary.get("directional_multiplier", 1.0), -1.0, 1.0, 1.0);
    const double boundary_scalar = unified_pipeline::clamped(boundary.get("scalar_multiplier", 1.0), 0.0, 1.0, 1.0);

    const double bulk_modulus = unified_pipeline::clamped(stage_config.get("bulk_modulus", 1.0), 0.0, 1.0e9, 1.0);
    const double thermal_pressure_coeff = unified_pipeline::clamped(stage_config.get("thermal_pressure_coeff", 0.0), -1.0e6, 1.0e6, 0.0);
    const double reference_temperature = unified_pipeline::clamped(stage_config.get("reference_temperature", 293.15), 0.0, 2.0e4, 293.15);
    const double pressure_source = unified_pipeline::clamped(stage_config.get("pressure_source", 0.0), -1.0e9, 1.0e9, 0.0);
    const double relaxation_rate = unified_pipeline::clamped(stage_config.get("relaxation_rate", 0.0), 0.0, 1.0e6, 0.0);
    const double density_source = unified_pipeline::clamped(stage_config.get("density_source", 0.0), -1.0e9, 1.0e9, 0.0);
    const double density_sink = unified_pipeline::clamped(stage_config.get("density_sink", 0.0), 0.0, 1.0e9, 0.0);
    const double eos_gamma = unified_pipeline::clamped(stage_config.get("eos_gamma", 1.0), 0.0, 10.0, 1.0);
    const double eos_r = unified_pipeline::clamped(stage_config.get("eos_r", 1.0), 0.0, 1.0e6, 1.0);
    const double permeability = unified_pipeline::clamped(stage_config.get("permeability", 0.0), 0.0, 1.0e3, 0.0);
    const double dynamic_viscosity = unified_pipeline::clamped(stage_config.get("dynamic_viscosity", 1.0), 1.0e-9, 1.0e9, 1.0);
    const double porosity = unified_pipeline::clamped(stage_config.get("porosity", 0.0), 0.0, 1.0, 0.0);
    const double seepage_coupling = unified_pipeline::clamped(stage_config.get("seepage_coupling", 1.0), -1.0e6, 1.0e6, 1.0);
    const double shock_impulse = unified_pipeline::clamped(stage_field_inputs.get("shock_impulse", stage_config.get("shock_impulse", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double shock_distance = unified_pipeline::clamped(stage_field_inputs.get("shock_distance", stage_config.get("shock_distance", 0.0)), 0.0, 1.0e9, 0.0);
    const double shock_attenuation = unified_pipeline::clamped(stage_config.get("shock_attenuation", 0.0), 0.0, 1.0e3, 0.0);
    const double shock_pressure_gain = unified_pipeline::clamped(stage_config.get("shock_pressure_gain", 0.0), -1.0e6, 1.0e6, 0.0);

    const double darcy_velocity = -(permeability / dynamic_viscosity) * pressure_gradient;
    const double seepage_flux = porosity * darcy_velocity * boundary_dir;
    const double seepage_density_rate = -density * seepage_flux * seepage_coupling;
    const double density_rate = -density * velocity_divergence + density_source - density_sink + seepage_density_rate;
    const double density_delta = density_rate * delta_seconds;
    const double density_next = std::max(1.0e-6, density + density_delta);

    const double pressure_eos = eos_gamma * density_next * eos_r * temperature;
    const double compression_term = -bulk_modulus * velocity_divergence;
    const double thermal_term = thermal_pressure_coeff * (temperature - reference_temperature);
    const double relaxation_term = -relaxation_rate * pressure;
    const double eos_relaxation_gain = unified_pipeline::clamped(stage_config.get("eos_relaxation_gain", 0.0), 0.0, 1.0e6, 0.0);
    const double eos_term = eos_relaxation_gain * (pressure_eos - pressure);
    const double shock_decay = std::exp(-shock_attenuation * shock_distance);
    const double shock_pressure_term = shock_impulse * shock_decay * shock_pressure_gain * boundary_scalar;
    const double pressure_rate = compression_term + thermal_term + pressure_source + relaxation_term + eos_term + shock_pressure_term;

    const double pressure_delta = pressure_rate * delta_seconds;
    const double pressure_next = std::max(0.0, pressure + pressure_delta);
    const double pressure_work_proxy = pressure_next * velocity_divergence * delta_seconds / std::max(1.0e-6, density);

    Dictionary result = unified_pipeline::make_dictionary(
        "stage_type", String("pressure"), "stage", stage_name, "ok", true, "pressure", pressure, "boundary", boundary, "pressure_delta", pressure_delta,
        "pressure_next", pressure_next, "density", density, "density_rate", density_rate, "density_delta", density_delta, "density_next", density_next,
        "pressure_eos", pressure_eos, "pressure_rate", pressure_rate, "compression_term", compression_term, "darcy_velocity", darcy_velocity,
        "seepage_flux", seepage_flux, "seepage_density_rate", seepage_density_rate, "shock_decay", shock_decay, "shock_pressure_term", shock_pressure_term,
        "thermal_term", thermal_term, "eos_term", eos_term, "relaxation_term", relaxation_term);
    result["conservation"] = unified_pipeline::make_dictionary("mass_proxy_delta", density_delta, "energy_proxy_delta", -pressure_work_proxy, "energy_proxy_metric", String("pressure_work"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_thermal_stage(const Dictionary &stage_config, const Dictionary &stage_field_inputs, double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "thermal"));

    const double temperature = unified_pipeline::clamped(stage_field_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double neighbor_temperature = unified_pipeline::clamped(
        stage_field_inputs.get("neighbor_temperature", stage_config.get("neighbor_temperature", temperature)),
        0.0,
        2.0e4,
        temperature);
    const double ambient_temperature = unified_pipeline::clamped(
        stage_field_inputs.get("ambient_temperature", stage_config.get("ambient_temperature", 293.15)),
        0.0,
        2.0e4,
        293.15);

    const double thermal_conductivity = unified_pipeline::clamped(stage_config.get("thermal_conductivity", 0.1), 0.0, 1.0e4, 0.1);
    const double cooling_rate = unified_pipeline::clamped(stage_config.get("cooling_rate", 0.0), 0.0, 1.0e6, 0.0);
    const double thermal_mass = unified_pipeline::clamped(stage_config.get("thermal_mass", 1.0), 1.0e-6, 1.0e12, 1.0);
    const double internal_heat = unified_pipeline::clamped(stage_config.get("internal_heat", 0.0), -1.0e9, 1.0e9, 0.0);
    const double advection_coeff = unified_pipeline::clamped(stage_config.get("advection_coeff", 0.0), 0.0, 1.0e6, 0.0);
    const double velocity = unified_pipeline::clamped(stage_field_inputs.get("velocity", stage_config.get("velocity", 0.0)), -1.0e6, 1.0e6, 0.0);
    const double stefan_boltzmann = unified_pipeline::clamped(stage_config.get("stefan_boltzmann", 5.670374419e-8), 0.0, 1.0, 5.670374419e-8);
    const double emissivity = unified_pipeline::clamped(stage_config.get("emissivity", 0.85), 0.0, 1.0, 0.85);
    const double melting_point = unified_pipeline::clamped(stage_config.get("melting_point", 273.15), 0.0, 2.0e4, 273.15);
    const double boiling_point = unified_pipeline::clamped(stage_config.get("boiling_point", 373.15), melting_point, 2.0e4, 373.15);
    const double phase_response = unified_pipeline::clamped(stage_config.get("phase_response_rate", 0.0), 0.0, 1.0e6, 0.0);
    const double latent_heat_fusion = unified_pipeline::clamped(stage_config.get("latent_heat_fusion", 0.0), 0.0, 1.0e9, 0.0);
    const double latent_heat_vaporization = unified_pipeline::clamped(stage_config.get("latent_heat_vaporization", 0.0), 0.0, 1.0e9, 0.0);
    const double liquid_fraction = unified_pipeline::clamped(stage_field_inputs.get("liquid_fraction", stage_config.get("liquid_fraction", 0.0)), 0.0, 1.0, 0.0);
    const double vapor_fraction = unified_pipeline::clamped(stage_field_inputs.get("vapor_fraction", stage_config.get("vapor_fraction", 0.0)), 0.0, 1.0, 0.0);
    const Dictionary boundary = unified_pipeline::boundary_contract(stage_config, stage_field_inputs);
    const double boundary_dir = unified_pipeline::clamped(boundary.get("directional_multiplier", 1.0), -1.0, 1.0, 1.0);
    const double boundary_scalar = unified_pipeline::clamped(boundary.get("scalar_multiplier", 1.0), 0.0, 1.0, 1.0);

    const double conduction_flux = thermal_conductivity * (neighbor_temperature - temperature) * boundary_dir;
    const double advection_flux = -advection_coeff * velocity * (temperature - ambient_temperature) * boundary_dir;
    const double cooling_flux = cooling_rate * (temperature - ambient_temperature);
    const double t4 = temperature * temperature * temperature * temperature;
    const double ta4 = ambient_temperature * ambient_temperature * ambient_temperature * ambient_temperature;
    const double radiative_flux = emissivity * stefan_boltzmann * (t4 - ta4);
    const double melt_extent = std::min(std::max(0.0, 1.0 - liquid_fraction), std::max(0.0, temperature - melting_point) * phase_response * delta_seconds);
    const double freeze_extent = std::min(liquid_fraction, std::max(0.0, melting_point - temperature) * phase_response * delta_seconds);
    const double boil_extent = std::min(std::max(0.0, 1.0 - vapor_fraction), std::max(0.0, temperature - boiling_point) * phase_response * delta_seconds);
    const double condense_extent = std::min(vapor_fraction, std::max(0.0, boiling_point - temperature) * phase_response * delta_seconds);
    const double liquid_fraction_next = std::clamp(liquid_fraction + melt_extent - freeze_extent - boil_extent + condense_extent, 0.0, 1.0);
    const double vapor_fraction_next = std::clamp(vapor_fraction + boil_extent - condense_extent, 0.0, 1.0);
    const double latent_energy_delta = thermal_mass * (
        latent_heat_fusion * (melt_extent - freeze_extent) + latent_heat_vaporization * (boil_extent - condense_extent));
    const double heat_rate = (conduction_flux + advection_flux) * boundary_scalar - cooling_flux - radiative_flux + internal_heat
        - (latent_energy_delta / std::max(1.0e-6, delta_seconds));
    const double temperature_rate = heat_rate / thermal_mass;
    const double temperature_delta = temperature_rate * delta_seconds;
    const double temperature_next = std::max(0.0, temperature + temperature_delta);
    const double energy_delta = thermal_mass * (temperature_next - temperature);

    Dictionary result = unified_pipeline::make_dictionary(
        "stage_type", String("thermal"), "stage", stage_name, "ok", true, "temperature", temperature, "boundary", boundary, "temperature_delta", temperature_delta,
        "temperature_next", temperature_next, "conduction_flux", conduction_flux, "advection_flux", advection_flux, "cooling_flux", cooling_flux,
        "radiative_flux", radiative_flux, "internal_heat", internal_heat,
        "phase_change", unified_pipeline::make_dictionary("melt_extent", melt_extent, "freeze_extent", freeze_extent, "boil_extent", boil_extent,
            "condense_extent", condense_extent, "liquid_fraction_next", liquid_fraction_next, "vapor_fraction_next", vapor_fraction_next, "latent_energy_delta", latent_energy_delta));
    result["conservation"] = unified_pipeline::make_dictionary("mass_proxy_delta", 0.0, "energy_proxy_delta", energy_delta, "energy_proxy_metric", String("thermal_energy"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_reaction_stage(const Dictionary &stage_config, const Dictionary &stage_field_inputs, double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "reaction"));

    const double temperature = unified_pipeline::clamped(stage_field_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double pressure = unified_pipeline::clamped(stage_field_inputs.get("pressure", stage_config.get("pressure", 1.0)), 0.0, 1.0e9, 1.0);
    const double reactant_a = unified_pipeline::clamped(stage_field_inputs.get("reactant_a", stage_config.get("reactant_a", 0.0)), 0.0, 1.0e9, 0.0);
    const double reactant_b = unified_pipeline::clamped(stage_field_inputs.get("reactant_b", stage_config.get("reactant_b", 0.0)), 0.0, 1.0e9, 0.0);

    const double activation_temperature = unified_pipeline::clamped(stage_config.get("activation_temperature", 700.0), 0.0, 2.0e4, 700.0);
    const double min_pressure = unified_pipeline::clamped(stage_config.get("min_pressure", 0.5), 0.0, 1.0e9, 0.5);
    const double max_pressure = unified_pipeline::clamped(stage_config.get("max_pressure", 3.5), min_pressure, 1.0e9, 3.5);
    const double optimal_pressure = unified_pipeline::clamped(stage_config.get("optimal_pressure", 1.2), min_pressure, max_pressure, 1.2);
    const double pre_exponential_factor = unified_pipeline::clamped(stage_config.get("arrhenius_a", stage_config.get("reaction_rate", 0.0)), 0.0, 1.0e9, 0.0);
    const double activation_energy = unified_pipeline::clamped(stage_config.get("arrhenius_ea", 1.0), 0.0, 1.0e9, 1.0);
    const double gas_constant = unified_pipeline::clamped(stage_config.get("arrhenius_r", 8.314462618), 1.0e-6, 1.0e6, 8.314462618);
    const double stoichiometric_ratio_b = unified_pipeline::clamped(stage_config.get("stoichiometric_ratio_b", 1.0), 1.0e-6, 1.0e6, 1.0);
    const double product_yield = unified_pipeline::clamped(stage_config.get("product_yield", 1.0), 0.0, 2.0, 1.0);
    const double heat_release_per_extent = unified_pipeline::clamped(stage_config.get("heat_release_per_extent", 0.0), -1.0e9, 1.0e9, 0.0);
    const double terrain_damage_factor = unified_pipeline::clamped(stage_config.get("terrain_damage_factor", 0.01), 0.0, 1.0e3, 0.01);
    const double latent_heat_phase_change = unified_pipeline::clamped(stage_config.get("latent_heat_phase_change", 0.0), 0.0, 1.0e9, 0.0);
    const double phase_capacity = unified_pipeline::clamped(stage_field_inputs.get("phase_transition_capacity", stage_config.get("phase_transition_capacity", 1.0)), 0.0, 1.0e9, 1.0);
    const Dictionary boundary = unified_pipeline::boundary_contract(stage_config, stage_field_inputs);
    const double boundary_scalar = unified_pipeline::clamped(boundary.get("scalar_multiplier", 1.0), 0.0, 1.0, 1.0);

    const bool activated = temperature >= activation_temperature;
    const double temp_factor = std::clamp(
        (temperature - activation_temperature) / std::max(1.0, activation_temperature),
        0.0,
        1.0);
    const double pressure_factor = unified_pipeline::pressure_window_factor(pressure, min_pressure, max_pressure, optimal_pressure);
    const double limiting_extent = std::min(reactant_a, reactant_b / stoichiometric_ratio_b);
    const double inv_rt = 1.0 / std::max(1.0e-9, gas_constant * temperature);
    const double arrhenius_exponent = std::clamp(-activation_energy * inv_rt, -700.0, 0.0);
    const double arrhenius_k = pre_exponential_factor * std::exp(arrhenius_exponent);
    const double kinetic_extent = arrhenius_k * temp_factor * pressure_factor * delta_seconds;
    const double reaction_extent = std::min(limiting_extent, kinetic_extent);

    const double reactant_a_consumed = reaction_extent;
    const double reactant_b_consumed = reaction_extent * stoichiometric_ratio_b;
    const double product_generated = reaction_extent * product_yield;
    const double heat_delta = reaction_extent * heat_release_per_extent * boundary_scalar;
    const double phase_change_extent = std::min(
        phase_capacity,
        std::max(0.0, heat_delta) / std::max(1.0e-6, latent_heat_phase_change));
    const double phase_change_latent_energy = phase_change_extent * latent_heat_phase_change;
    const double terrain_damage_budget = std::max(0.0, heat_delta) * terrain_damage_factor;

    const double mass_delta = product_generated - reactant_a_consumed - reactant_b_consumed;

    Dictionary result = unified_pipeline::make_dictionary(
        "stage_type", String("reaction"), "stage", stage_name, "ok", true, "boundary", boundary, "activated", activated, "temperature", temperature,
        "pressure", pressure, "pressure_factor", pressure_factor, "arrhenius_k", arrhenius_k, "arrhenius_exponent", arrhenius_exponent,
        "temperature_activation_factor", temp_factor, "reaction_extent", reaction_extent, "reactant_a_consumed", reactant_a_consumed,
        "reactant_b_consumed", reactant_b_consumed, "product_generated", product_generated, "heat_delta", heat_delta,
        "phase_change", unified_pipeline::make_dictionary("phase_change_extent", phase_change_extent, "latent_energy_consumed", phase_change_latent_energy),
        "terrain_damage_budget", terrain_damage_budget);
    result["conservation"] = unified_pipeline::make_dictionary("mass_proxy_delta", mass_delta, "energy_proxy_delta", heat_delta - phase_change_latent_energy, "energy_proxy_metric", String("reaction_heat"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_destruction_stage(
    const Dictionary &stage_config,
    const Dictionary &stage_field_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "destruction"));

    const double stress = unified_pipeline::clamped(stage_field_inputs.get("stress", stage_config.get("stress", 0.0)), 0.0, 1.0e9, 0.0);
    const double strain = unified_pipeline::clamped(stage_field_inputs.get("strain", stage_config.get("strain", 0.0)), 0.0, 1.0e3, 0.0);
    const double damage = unified_pipeline::clamped(stage_field_inputs.get("damage", stage_config.get("damage", 0.0)), 0.0, 1.0, 0.0);
    const double mass = unified_pipeline::clamped(stage_field_inputs.get("mass", stage_config.get("mass", 1.0)), 0.0, 1.0e9, 1.0);

    const double fracture_threshold = unified_pipeline::clamped(stage_config.get("fracture_threshold", 1.0), 1.0e-6, 1.0e9, 1.0);
    const double cohesion = unified_pipeline::clamped(stage_field_inputs.get("cohesion", stage_config.get("cohesion", 0.5)), 0.0, 1.0, 0.5);
    const double hardness = unified_pipeline::clamped(stage_field_inputs.get("hardness", stage_config.get("hardness", 0.5)), 0.0, 1.0, 0.5);
    const double damage_gain = unified_pipeline::clamped(stage_config.get("damage_gain", 1.0), 0.0, 1.0e6, 1.0);
    const double mass_loss_factor = unified_pipeline::clamped(stage_config.get("mass_loss_factor", 0.1), 0.0, 1.0, 0.1);
    const double normal_force = unified_pipeline::clamped(stage_field_inputs.get("normal_force", stage_config.get("normal_force", mass * 9.81)), 0.0, 1.0e12, mass * 9.81);
    const double contact_velocity = unified_pipeline::clamped(stage_field_inputs.get("contact_velocity", stage_config.get("contact_velocity", 0.0)), -1.0e6, 1.0e6, 0.0);
    const double friction_static_mu = unified_pipeline::clamped(stage_config.get("friction_static_mu", 0.6), 0.0, 10.0, 0.6);
    const double friction_dynamic_mu = unified_pipeline::clamped(stage_config.get("friction_dynamic_mu", 0.4), 0.0, 10.0, 0.4);
    const double slope_angle_deg = unified_pipeline::clamped(stage_field_inputs.get("slope_angle_deg", stage_config.get("slope_angle_deg", 0.0)), 0.0, 89.9, 0.0);
    const double slope_failure_angle_deg = unified_pipeline::clamped(stage_config.get("slope_failure_angle_deg", 35.0), 0.1, 89.9, 35.0);
    const double slope_failure_gain = unified_pipeline::clamped(stage_config.get("slope_failure_gain", 1.0), 0.0, 1.0e6, 1.0);
    const double gravity = unified_pipeline::clamped(stage_config.get("gravity", 9.81), 0.0, 1.0e3, 9.81);
    const Dictionary boundary = unified_pipeline::boundary_contract(stage_config, stage_field_inputs);
    const double boundary_scalar = unified_pipeline::clamped(boundary.get("scalar_multiplier", 1.0), 0.0, 1.0, 1.0);

    const double overstress = std::max(0.0, stress - fracture_threshold);
    const double resistance = std::max(1.0e-6, (1.0 - 0.5 * cohesion) * (1.0 - 0.5 * hardness));
    const double slope_radians = slope_angle_deg * (3.14159265358979323846 / 180.0);
    const double tangential_load = mass * gravity * std::sin(slope_radians) * boundary_scalar;
    const double static_limit = friction_static_mu * normal_force;
    const bool sliding = std::abs(tangential_load) > static_limit;
    const double friction_force = sliding
        ? -std::copysign(friction_dynamic_mu * normal_force, std::abs(contact_velocity) > 1.0e-9 ? contact_velocity : tangential_load)
        : -tangential_load;
    const double friction_dissipation = std::abs(friction_force * contact_velocity) * delta_seconds;
    const double slope_failure_ratio = std::max(0.0, (slope_angle_deg - slope_failure_angle_deg) / slope_failure_angle_deg);
    const double damage_rate = ((overstress / fracture_threshold) * (1.0 + strain) + slope_failure_ratio * slope_failure_gain) * resistance * damage_gain;
    const double damage_delta = std::clamp(damage_rate * delta_seconds, 0.0, 1.0 - damage);
    const double damage_next = std::clamp(damage + damage_delta, 0.0, 1.0);

    const double mass_loss = mass * damage_delta * mass_loss_factor;
    const double fracture_energy = stress * strain * damage_delta;

    Dictionary result = unified_pipeline::make_dictionary(
        "stage_type", String("destruction"), "stage", stage_name, "ok", true, "boundary", boundary, "damage", damage, "damage_delta", damage_delta,
        "damage_next", damage_next, "mass_loss", mass_loss, "friction_force", friction_force, "friction_dissipation", friction_dissipation,
        "slope_failure_ratio", slope_failure_ratio, "fracture_energy", fracture_energy);
    result["conservation"] = unified_pipeline::make_dictionary("mass_proxy_delta", -mass_loss, "energy_proxy_delta", -fracture_energy - friction_dissipation, "energy_proxy_metric", String("fracture_dissipation"));
    return result;
}

} // namespace local_agents::simulation
