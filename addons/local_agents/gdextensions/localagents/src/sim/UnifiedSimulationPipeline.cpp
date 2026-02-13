#include "sim/UnifiedSimulationPipeline.hpp"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace local_agents::simulation {
namespace {
Array default_required_channels() {
    Array channels;
    channels.append(String("pressure"));
    channels.append(String("temperature"));
    channels.append(String("density"));
    channels.append(String("velocity"));
    channels.append(String("moisture"));
    channels.append(String("porosity"));
    channels.append(String("cohesion"));
    channels.append(String("hardness"));
    channels.append(String("phase"));
    channels.append(String("fuel"));
    channels.append(String("oxygen"));
    channels.append(String("stress"));
    channels.append(String("strain"));
    channels.append(String("material_flammability"));
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

double pressure_window_factor(double pressure, double min_pressure, double max_pressure, double optimal_pressure) {
    if (pressure < min_pressure || pressure > max_pressure) {
        return 0.0;
    }
    const double span = std::max(0.001, max_pressure - min_pressure);
    const double normalized_delta = (pressure - optimal_pressure) / span;
    const double factor = std::exp(-(normalized_delta * normalized_delta) * 12.0);
    return std::clamp(factor, 0.0, 1.0);
}
} // namespace

bool UnifiedSimulationPipeline::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    required_channels_ = config.get("required_channels", default_required_channels());
    transport_stages_ = config.get("transport_stages", Array());
    destruction_stages_ = config.get("destruction_stages", Array());
    combustion_stages_ = config.get("combustion_stages", Array());
    return true;
}

Dictionary UnifiedSimulationPipeline::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

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

    Array transport_results;
    Array destruction_results;
    Array combustion_results;

    for (int64_t i = 0; i < transport_stages_.size(); i++) {
        const Variant stage_variant = transport_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        transport_results.append(run_transport_stage(stage_variant, frame_inputs));
    }
    for (int64_t i = 0; i < destruction_stages_.size(); i++) {
        const Variant stage_variant = destruction_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        destruction_results.append(run_destruction_stage(stage_variant, frame_inputs));
    }
    for (int64_t i = 0; i < combustion_stages_.size(); i++) {
        const Variant stage_variant = combustion_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        combustion_results.append(run_combustion_stage(stage_variant, frame_inputs));
    }

    Dictionary summary;
    summary["ok"] = true;
    summary["executed_steps"] = executed_steps_;
    summary["transport"] = transport_results;
    summary["destruction"] = destruction_results;
    summary["combustion"] = combustion_results;
    summary["required_channels"] = required_channels_.duplicate(true);
    summary["missing_channels"] = missing_channels;
    summary["physics_ready"] = missing_channels.is_empty();
    summary["stage_counts"] = Dictionary::make(
        "transport", transport_results.size(),
        "destruction", destruction_results.size(),
        "combustion", combustion_results.size());

    last_step_summary_ = summary.duplicate(true);
    return summary;
}

void UnifiedSimulationPipeline::reset() {
    config_.clear();
    required_channels_.clear();
    transport_stages_.clear();
    destruction_stages_.clear();
    combustion_stages_.clear();
    executed_steps_ = 0;
    last_step_summary_.clear();
}

Dictionary UnifiedSimulationPipeline::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["configured"] = !config_.is_empty();
    snapshot["required_channels"] = required_channels_.duplicate(true);
    snapshot["transport_stage_count"] = transport_stages_.size();
    snapshot["destruction_stage_count"] = destruction_stages_.size();
    snapshot["combustion_stage_count"] = combustion_stages_.size();
    snapshot["executed_steps"] = executed_steps_;
    snapshot["config"] = config_.duplicate(true);
    snapshot["last_step_summary"] = last_step_summary_.duplicate(true);
    return snapshot;
}

Dictionary UnifiedSimulationPipeline::run_transport_stage(const Dictionary &stage_config, const Dictionary &frame_inputs) const {
    const String stage_name = String(stage_config.get("name", "transport"));
    const double flow_rate = clamped(stage_config.get("flow_rate", 1.0), 0.0, 1000.0, 1.0);
    const double viscosity = clamped(stage_config.get("viscosity", 0.2), 0.0, 1.0, 0.2);
    const double activity = clamped(frame_inputs.get("activity", 0.0), 0.0, 1.0, 0.0);

    Dictionary result;
    result["stage"] = stage_name;
    result["ok"] = true;
    result["throughput"] = flow_rate * (1.0 - 0.6 * viscosity) * (0.5 + 0.5 * activity);
    result["activity"] = activity;
    return result;
}

Dictionary UnifiedSimulationPipeline::run_destruction_stage(const Dictionary &stage_config, const Dictionary &frame_inputs) const {
    const String stage_name = String(stage_config.get("name", "destruction"));
    const double stress = clamped(frame_inputs.get("stress", 0.0), 0.0, 10.0, 0.0);
    const double cohesion = clamped(frame_inputs.get("cohesion", 0.5), 0.0, 1.0, 0.5);
    const double hardness = clamped(frame_inputs.get("hardness", 0.5), 0.0, 1.0, 0.5);

    const double erosion_potential = std::max(0.0, stress * (1.0 - cohesion) * (1.0 - 0.7 * hardness));
    Dictionary result;
    result["stage"] = stage_name;
    result["ok"] = true;
    result["erosion_potential"] = erosion_potential;
    result["voxel_delta_budget"] = erosion_potential * 0.25;
    return result;
}

Dictionary UnifiedSimulationPipeline::run_combustion_stage(const Dictionary &stage_config, const Dictionary &frame_inputs) const {
    const String stage_name = String(stage_config.get("name", "combustion"));

    const double ignition_temperature = clamped(stage_config.get("ignition_temperature", 600.0), 0.0, 10000.0, 600.0);
    const double min_pressure = clamped(stage_config.get("min_pressure", 0.5), 0.0, 1000.0, 0.5);
    const double max_pressure = clamped(stage_config.get("max_pressure", 3.5), min_pressure, 1000.0, 3.5);
    const double optimal_pressure = clamped(stage_config.get("optimal_pressure", 1.2), min_pressure, max_pressure, 1.2);
    const double heat_release = clamped(stage_config.get("heat_release", 40.0), 0.0, 1e6, 40.0);
    const double burn_rate = clamped(stage_config.get("burn_rate", 0.1), 0.0, 1.0, 0.1);

    const double temperature = clamped(frame_inputs.get("temperature", 293.0), 0.0, 10000.0, 293.0);
    const double pressure = clamped(frame_inputs.get("pressure", 1.0), 0.0, 1000.0, 1.0);
    const double fuel = clamped(frame_inputs.get("fuel", 0.0), 0.0, 1.0, 0.0);
    const double oxygen = clamped(frame_inputs.get("oxygen", 0.21), 0.0, 1.0, 0.21);
    const double moisture = clamped(frame_inputs.get("moisture", 0.0), 0.0, 1.0, 0.0);
    const double material_flammability = clamped(frame_inputs.get("material_flammability", 0.5), 0.0, 1.0, 0.5);

    const bool ignited = temperature >= ignition_temperature && fuel > 0.001 && oxygen > 0.001;
    const double pressure_factor = pressure_window_factor(pressure, min_pressure, max_pressure, optimal_pressure);
    const double temp_factor = std::clamp((temperature - ignition_temperature) / std::max(1.0, ignition_temperature), 0.0, 1.0);
    const double moisture_penalty = 1.0 - 0.85 * moisture;
    const double reactant_factor = std::min(fuel, oxygen);

    double burn_intensity = 0.0;
    if (ignited) {
        burn_intensity = temp_factor * pressure_factor * material_flammability * moisture_penalty * reactant_factor;
        burn_intensity = std::clamp(burn_intensity, 0.0, 1.0);
    }

    Dictionary result;
    result["stage"] = stage_name;
    result["ok"] = true;
    result["ignited"] = ignited;
    result["temperature"] = temperature;
    result["pressure"] = pressure;
    result["pressure_factor"] = pressure_factor;
    result["burn_intensity"] = burn_intensity;
    result["heat_delta"] = burn_intensity * heat_release;
    result["fuel_consumed"] = burn_intensity * burn_rate;
    result["oxygen_consumed"] = burn_intensity * burn_rate * 0.75;
    result["terrain_damage_budget"] = burn_intensity * heat_release * 0.01;
    return result;
}

} // namespace local_agents::simulation
