#include "sim/UnifiedSimulationPipeline.hpp"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace local_agents::simulation {
namespace {
Array default_required_channels() {
    Array channels;
    channels.append(String("mass"));
    channels.append(String("position"));
    channels.append(String("velocity"));
    channels.append(String("force"));
    channels.append(String("pressure"));
    channels.append(String("density"));
    channels.append(String("temperature"));
    channels.append(String("velocity_divergence"));
    channels.append(String("neighbor_temperature"));
    channels.append(String("reactant_a"));
    channels.append(String("reactant_b"));
    channels.append(String("stress"));
    channels.append(String("strain"));
    channels.append(String("damage"));
    return channels;
}

double clamped(const Variant &value, double min_v, double max_v, double fallback) {
    double parsed = fallback;
    if (value.get_type() == Variant::FLOAT) {
        parsed = static_cast<double>(value);
    } else if (value.get_type() == Variant::INT) {
        parsed = static_cast<double>(static_cast<int64_t>(value));
    }
    return std::clamp(parsed, min_v, max_v);
}

Dictionary stage_total_template(const String &stage_type) {
    Dictionary total;
    total["stage_type"] = stage_type;
    total["count"] = static_cast<int64_t>(0);
    total["mass_proxy_delta_sum"] = 0.0;
    total["energy_proxy_delta_sum"] = 0.0;
    return total;
}

void append_conservation(Dictionary &totals, const String &stage_type, const Dictionary &stage_result) {
    Dictionary stage_total = totals.get(stage_type, stage_total_template(stage_type));
    const int64_t previous_count = static_cast<int64_t>(stage_total.get("count", static_cast<int64_t>(0)));
    const double previous_mass_sum = clamped(stage_total.get("mass_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
    const double previous_energy_sum = clamped(stage_total.get("energy_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);

    const Dictionary conservation = stage_result.get("conservation", Dictionary());
    const double mass_delta = clamped(conservation.get("mass_proxy_delta", 0.0), -1e18, 1e18, 0.0);
    const double energy_delta = clamped(conservation.get("energy_proxy_delta", 0.0), -1e18, 1e18, 0.0);

    stage_total["count"] = previous_count + 1;
    stage_total["mass_proxy_delta_sum"] = previous_mass_sum + mass_delta;
    stage_total["energy_proxy_delta_sum"] = previous_energy_sum + energy_delta;
    totals[stage_type] = stage_total;
}

void aggregate_overall_conservation(Dictionary &diagnostics) {
    const Dictionary stage_totals = diagnostics.get("by_stage_type", Dictionary());

    double mass_total = 0.0;
    double energy_total = 0.0;
    int64_t stage_count = 0;

    const Array keys = stage_totals.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        const Variant key = keys[i];
        if (key.get_type() != Variant::STRING && key.get_type() != Variant::STRING_NAME) {
            continue;
        }
        const Dictionary stage_total = stage_totals.get(key, Dictionary());
        mass_total += clamped(stage_total.get("mass_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
        energy_total += clamped(stage_total.get("energy_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
        stage_count += static_cast<int64_t>(stage_total.get("count", static_cast<int64_t>(0)));
    }

    diagnostics["overall"] = Dictionary::make(
        "stage_count", stage_count,
        "mass_proxy_delta_total", mass_total,
        "energy_proxy_delta_total", energy_total);
}
} // namespace

bool UnifiedSimulationPipeline::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    required_channels_ = config.get("required_channels", default_required_channels());
    mechanics_stages_ = config.get("mechanics_stages", Array());
    pressure_stages_ = config.get("pressure_stages", Array());
    thermal_stages_ = config.get("thermal_stages", Array());
    reaction_stages_ = config.get("reaction_stages", Array());
    destruction_stages_ = config.get("destruction_stages", Array());
    return true;
}

Dictionary UnifiedSimulationPipeline::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

    const double delta_seconds = clamped(scheduled_frame.get("delta_seconds", 1.0 / 60.0), 1.0e-6, 10.0, 1.0 / 60.0);
    const Dictionary frame_inputs = scheduled_frame.get("inputs", Dictionary());

    Array missing_channels;
    for (int64_t i = 0; i < required_channels_.size(); i++) {
        const String channel = String(required_channels_[i]);
        if (channel.is_empty()) {
            continue;
        }
        if (!frame_inputs.has(channel)) {
            missing_channels.append(channel);
        }
    }

    Array mechanics_results;
    Array pressure_results;
    Array thermal_results;
    Array reaction_results;
    Array destruction_results;

    Dictionary conservation_diagnostics;
    Dictionary by_stage_type;
    by_stage_type["mechanics"] = stage_total_template("mechanics");
    by_stage_type["pressure"] = stage_total_template("pressure");
    by_stage_type["thermal"] = stage_total_template("thermal");
    by_stage_type["reaction"] = stage_total_template("reaction");
    by_stage_type["destruction"] = stage_total_template("destruction");
    conservation_diagnostics["by_stage_type"] = by_stage_type;

    for (int64_t i = 0; i < mechanics_stages_.size(); i++) {
        const Variant stage_variant = mechanics_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_mechanics_stage(stage_variant, frame_inputs, delta_seconds);
        mechanics_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        append_conservation(stage_totals, "mechanics", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < pressure_stages_.size(); i++) {
        const Variant stage_variant = pressure_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_pressure_stage(stage_variant, frame_inputs, delta_seconds);
        pressure_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        append_conservation(stage_totals, "pressure", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < thermal_stages_.size(); i++) {
        const Variant stage_variant = thermal_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_thermal_stage(stage_variant, frame_inputs, delta_seconds);
        thermal_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        append_conservation(stage_totals, "thermal", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < reaction_stages_.size(); i++) {
        const Variant stage_variant = reaction_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_reaction_stage(stage_variant, frame_inputs, delta_seconds);
        reaction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        append_conservation(stage_totals, "reaction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < destruction_stages_.size(); i++) {
        const Variant stage_variant = destruction_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_destruction_stage(stage_variant, frame_inputs, delta_seconds);
        destruction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        append_conservation(stage_totals, "destruction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    aggregate_overall_conservation(conservation_diagnostics);

    Dictionary summary;
    summary["ok"] = true;
    summary["executed_steps"] = executed_steps_;
    summary["delta_seconds"] = delta_seconds;
    summary["mechanics"] = mechanics_results;
    summary["pressure"] = pressure_results;
    summary["thermal"] = thermal_results;
    summary["reaction"] = reaction_results;
    summary["destruction"] = destruction_results;
    summary["required_channels"] = required_channels_.duplicate(true);
    summary["missing_channels"] = missing_channels;
    summary["physics_ready"] = missing_channels.is_empty();
    summary["stage_counts"] = Dictionary::make(
        "mechanics", mechanics_results.size(),
        "pressure", pressure_results.size(),
        "thermal", thermal_results.size(),
        "reaction", reaction_results.size(),
        "destruction", destruction_results.size());
    summary["conservation_diagnostics"] = conservation_diagnostics;

    last_step_summary_ = summary.duplicate(true);
    return summary;
}

void UnifiedSimulationPipeline::reset() {
    config_.clear();
    required_channels_.clear();
    mechanics_stages_.clear();
    pressure_stages_.clear();
    thermal_stages_.clear();
    reaction_stages_.clear();
    destruction_stages_.clear();
    executed_steps_ = 0;
    last_step_summary_.clear();
}

Dictionary UnifiedSimulationPipeline::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["configured"] = !config_.is_empty();
    snapshot["required_channels"] = required_channels_.duplicate(true);
    snapshot["mechanics_stage_count"] = mechanics_stages_.size();
    snapshot["pressure_stage_count"] = pressure_stages_.size();
    snapshot["thermal_stage_count"] = thermal_stages_.size();
    snapshot["reaction_stage_count"] = reaction_stages_.size();
    snapshot["destruction_stage_count"] = destruction_stages_.size();
    snapshot["executed_steps"] = executed_steps_;
    snapshot["config"] = config_.duplicate(true);
    snapshot["last_step_summary"] = last_step_summary_.duplicate(true);
    return snapshot;
}

Dictionary UnifiedSimulationPipeline::run_mechanics_stage(
    const Dictionary &stage_config,
    const Dictionary &frame_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "mechanics"));

    const double mass = clamped(frame_inputs.get("mass", stage_config.get("mass", 1.0)), 1.0e-6, 1.0e9, 1.0);
    const double force = clamped(frame_inputs.get("force", stage_config.get("force", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double external_force = clamped(frame_inputs.get("external_force", stage_config.get("external_force", 0.0)), -1.0e9, 1.0e9, 0.0);
    const double damping = clamped(stage_config.get("damping", 0.0), 0.0, 100.0, 0.0);
    const double velocity = clamped(frame_inputs.get("velocity", stage_config.get("velocity", 0.0)), -1.0e6, 1.0e6, 0.0);
    const double position = clamped(frame_inputs.get("position", stage_config.get("position", 0.0)), -1.0e12, 1.0e12, 0.0);

    const double drag_force = damping * velocity;
    const double net_force = force + external_force - drag_force;
    const double acceleration = net_force / mass;
    const double velocity_delta = acceleration * delta_seconds;
    const double velocity_next = velocity + velocity_delta;
    const double displacement_delta = velocity_next * delta_seconds;
    const double position_next = position + displacement_delta;

    const double kinetic_energy_before = 0.5 * mass * velocity * velocity;
    const double kinetic_energy_after = 0.5 * mass * velocity_next * velocity_next;
    const double energy_delta = kinetic_energy_after - kinetic_energy_before;

    Dictionary result;
    result["stage_type"] = String("mechanics");
    result["stage"] = stage_name;
    result["ok"] = true;
    result["mass"] = mass;
    result["net_force"] = net_force;
    result["acceleration"] = acceleration;
    result["velocity"] = velocity;
    result["velocity_delta"] = velocity_delta;
    result["velocity_next"] = velocity_next;
    result["position"] = position;
    result["displacement_delta"] = displacement_delta;
    result["position_next"] = position_next;
    result["conservation"] = Dictionary::make(
        "mass_proxy_delta", 0.0,
        "energy_proxy_delta", energy_delta,
        "energy_proxy_metric", String("kinetic_energy"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_pressure_stage(
    const Dictionary &stage_config,
    const Dictionary &frame_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "pressure"));

    const double pressure = clamped(frame_inputs.get("pressure", stage_config.get("pressure", 1.0)), 0.0, 1.0e9, 1.0);
    const double density = clamped(frame_inputs.get("density", stage_config.get("density", 1.0)), 1.0e-6, 1.0e9, 1.0);
    const double temperature = clamped(frame_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double velocity_divergence = clamped(frame_inputs.get("velocity_divergence", stage_config.get("velocity_divergence", 0.0)), -1.0e4, 1.0e4, 0.0);

    const double bulk_modulus = clamped(stage_config.get("bulk_modulus", 1.0), 0.0, 1.0e9, 1.0);
    const double thermal_pressure_coeff = clamped(stage_config.get("thermal_pressure_coeff", 0.0), -1.0e6, 1.0e6, 0.0);
    const double reference_temperature = clamped(stage_config.get("reference_temperature", 293.15), 0.0, 2.0e4, 293.15);
    const double pressure_source = clamped(stage_config.get("pressure_source", 0.0), -1.0e9, 1.0e9, 0.0);
    const double relaxation_rate = clamped(stage_config.get("relaxation_rate", 0.0), 0.0, 1.0e6, 0.0);

    const double compression_term = -bulk_modulus * velocity_divergence;
    const double thermal_term = thermal_pressure_coeff * (temperature - reference_temperature);
    const double relaxation_term = -relaxation_rate * pressure;
    const double pressure_rate = compression_term + thermal_term + pressure_source + relaxation_term;

    const double pressure_delta = pressure_rate * delta_seconds;
    const double pressure_next = std::max(0.0, pressure + pressure_delta);
    const double pressure_work_proxy = pressure_next * velocity_divergence * delta_seconds / std::max(1.0e-6, density);

    Dictionary result;
    result["stage_type"] = String("pressure");
    result["stage"] = stage_name;
    result["ok"] = true;
    result["pressure"] = pressure;
    result["pressure_delta"] = pressure_delta;
    result["pressure_next"] = pressure_next;
    result["pressure_rate"] = pressure_rate;
    result["compression_term"] = compression_term;
    result["thermal_term"] = thermal_term;
    result["relaxation_term"] = relaxation_term;
    result["conservation"] = Dictionary::make(
        "mass_proxy_delta", 0.0,
        "energy_proxy_delta", -pressure_work_proxy,
        "energy_proxy_metric", String("pressure_work"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_thermal_stage(
    const Dictionary &stage_config,
    const Dictionary &frame_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "thermal"));

    const double temperature = clamped(frame_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double neighbor_temperature = clamped(
        frame_inputs.get("neighbor_temperature", stage_config.get("neighbor_temperature", temperature)),
        0.0,
        2.0e4,
        temperature);
    const double ambient_temperature = clamped(
        frame_inputs.get("ambient_temperature", stage_config.get("ambient_temperature", 293.15)),
        0.0,
        2.0e4,
        293.15);

    const double thermal_conductivity = clamped(stage_config.get("thermal_conductivity", 0.1), 0.0, 1.0e4, 0.1);
    const double cooling_rate = clamped(stage_config.get("cooling_rate", 0.0), 0.0, 1.0e6, 0.0);
    const double thermal_mass = clamped(stage_config.get("thermal_mass", 1.0), 1.0e-6, 1.0e12, 1.0);
    const double internal_heat = clamped(stage_config.get("internal_heat", 0.0), -1.0e9, 1.0e9, 0.0);

    const double conduction_flux = thermal_conductivity * (neighbor_temperature - temperature);
    const double cooling_flux = cooling_rate * (temperature - ambient_temperature);
    const double heat_rate = conduction_flux - cooling_flux + internal_heat;
    const double temperature_rate = heat_rate / thermal_mass;
    const double temperature_delta = temperature_rate * delta_seconds;
    const double temperature_next = std::max(0.0, temperature + temperature_delta);
    const double energy_delta = thermal_mass * (temperature_next - temperature);

    Dictionary result;
    result["stage_type"] = String("thermal");
    result["stage"] = stage_name;
    result["ok"] = true;
    result["temperature"] = temperature;
    result["temperature_delta"] = temperature_delta;
    result["temperature_next"] = temperature_next;
    result["conduction_flux"] = conduction_flux;
    result["cooling_flux"] = cooling_flux;
    result["internal_heat"] = internal_heat;
    result["conservation"] = Dictionary::make(
        "mass_proxy_delta", 0.0,
        "energy_proxy_delta", energy_delta,
        "energy_proxy_metric", String("thermal_energy"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_reaction_stage(
    const Dictionary &stage_config,
    const Dictionary &frame_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "reaction"));

    const double temperature = clamped(frame_inputs.get("temperature", stage_config.get("temperature", 293.15)), 0.0, 2.0e4, 293.15);
    const double pressure = clamped(frame_inputs.get("pressure", stage_config.get("pressure", 1.0)), 0.0, 1.0e9, 1.0);
    const double reactant_a = clamped(frame_inputs.get("reactant_a", stage_config.get("reactant_a", 0.0)), 0.0, 1.0e9, 0.0);
    const double reactant_b = clamped(frame_inputs.get("reactant_b", stage_config.get("reactant_b", 0.0)), 0.0, 1.0e9, 0.0);

    const double activation_temperature = clamped(stage_config.get("activation_temperature", 700.0), 0.0, 2.0e4, 700.0);
    const double min_pressure = clamped(stage_config.get("min_pressure", 0.5), 0.0, 1.0e9, 0.5);
    const double max_pressure = clamped(stage_config.get("max_pressure", 3.5), min_pressure, 1.0e9, 3.5);
    const double optimal_pressure = clamped(stage_config.get("optimal_pressure", 1.2), min_pressure, max_pressure, 1.2);
    const double reaction_rate = clamped(stage_config.get("reaction_rate", 0.0), 0.0, 1.0e6, 0.0);
    const double stoichiometric_ratio_b = clamped(stage_config.get("stoichiometric_ratio_b", 1.0), 1.0e-6, 1.0e6, 1.0);
    const double product_yield = clamped(stage_config.get("product_yield", 1.0), 0.0, 2.0, 1.0);
    const double heat_release_per_extent = clamped(stage_config.get("heat_release_per_extent", 0.0), -1.0e9, 1.0e9, 0.0);
    const double terrain_damage_factor = clamped(stage_config.get("terrain_damage_factor", 0.01), 0.0, 1.0e3, 0.01);

    const bool activated = temperature >= activation_temperature;
    const double temp_factor = std::clamp(
        (temperature - activation_temperature) / std::max(1.0, activation_temperature),
        0.0,
        1.0);
    const double pressure_factor = pressure_window_factor(pressure, min_pressure, max_pressure, optimal_pressure);
    const double limiting_extent = std::min(reactant_a, reactant_b / stoichiometric_ratio_b);
    const double kinetic_extent = reaction_rate * temp_factor * pressure_factor * delta_seconds;
    const double reaction_extent = std::min(limiting_extent, kinetic_extent);

    const double reactant_a_consumed = reaction_extent;
    const double reactant_b_consumed = reaction_extent * stoichiometric_ratio_b;
    const double product_generated = reaction_extent * product_yield;
    const double heat_delta = reaction_extent * heat_release_per_extent;
    const double terrain_damage_budget = std::max(0.0, heat_delta) * terrain_damage_factor;

    const double mass_delta = product_generated - reactant_a_consumed - reactant_b_consumed;

    Dictionary result;
    result["stage_type"] = String("reaction");
    result["stage"] = stage_name;
    result["ok"] = true;
    result["activated"] = activated;
    result["temperature"] = temperature;
    result["pressure"] = pressure;
    result["pressure_factor"] = pressure_factor;
    result["temperature_activation_factor"] = temp_factor;
    result["reaction_extent"] = reaction_extent;
    result["reactant_a_consumed"] = reactant_a_consumed;
    result["reactant_b_consumed"] = reactant_b_consumed;
    result["product_generated"] = product_generated;
    result["heat_delta"] = heat_delta;
    result["terrain_damage_budget"] = terrain_damage_budget;
    result["conservation"] = Dictionary::make(
        "mass_proxy_delta", mass_delta,
        "energy_proxy_delta", heat_delta,
        "energy_proxy_metric", String("reaction_heat"));
    return result;
}

Dictionary UnifiedSimulationPipeline::run_destruction_stage(
    const Dictionary &stage_config,
    const Dictionary &frame_inputs,
    double delta_seconds) const {
    const String stage_name = String(stage_config.get("name", "destruction"));

    const double stress = clamped(frame_inputs.get("stress", stage_config.get("stress", 0.0)), 0.0, 1.0e9, 0.0);
    const double strain = clamped(frame_inputs.get("strain", stage_config.get("strain", 0.0)), 0.0, 1.0e3, 0.0);
    const double damage = clamped(frame_inputs.get("damage", stage_config.get("damage", 0.0)), 0.0, 1.0, 0.0);
    const double mass = clamped(frame_inputs.get("mass", stage_config.get("mass", 1.0)), 0.0, 1.0e9, 1.0);

    const double fracture_threshold = clamped(stage_config.get("fracture_threshold", 1.0), 1.0e-6, 1.0e9, 1.0);
    const double cohesion = clamped(frame_inputs.get("cohesion", stage_config.get("cohesion", 0.5)), 0.0, 1.0, 0.5);
    const double hardness = clamped(frame_inputs.get("hardness", stage_config.get("hardness", 0.5)), 0.0, 1.0, 0.5);
    const double damage_gain = clamped(stage_config.get("damage_gain", 1.0), 0.0, 1.0e6, 1.0);
    const double mass_loss_factor = clamped(stage_config.get("mass_loss_factor", 0.1), 0.0, 1.0, 0.1);

    const double overstress = std::max(0.0, stress - fracture_threshold);
    const double resistance = std::max(1.0e-6, (1.0 - 0.5 * cohesion) * (1.0 - 0.5 * hardness));
    const double damage_rate = (overstress / fracture_threshold) * (1.0 + strain) * resistance * damage_gain;
    const double damage_delta = std::clamp(damage_rate * delta_seconds, 0.0, 1.0 - damage);
    const double damage_next = std::clamp(damage + damage_delta, 0.0, 1.0);

    const double mass_loss = mass * damage_delta * mass_loss_factor;
    const double fracture_energy = stress * strain * damage_delta;

    Dictionary result;
    result["stage_type"] = String("destruction");
    result["stage"] = stage_name;
    result["ok"] = true;
    result["damage"] = damage;
    result["damage_delta"] = damage_delta;
    result["damage_next"] = damage_next;
    result["mass_loss"] = mass_loss;
    result["fracture_energy"] = fracture_energy;
    result["conservation"] = Dictionary::make(
        "mass_proxy_delta", -mass_loss,
        "energy_proxy_delta", -fracture_energy,
        "energy_proxy_metric", String("fracture_dissipation"));
    return result;
}

} // namespace local_agents::simulation
