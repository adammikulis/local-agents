#include "sim/UnifiedSimulationPipelineInternal.hpp"

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace local_agents::simulation::unified_pipeline {
namespace {
double as_number(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}
} // namespace

Array default_required_channels() {
    Array channels;
    static const char *k_channels[] = {"mass", "position", "velocity", "force", "pressure", "pressure_gradient", "density", "temperature",
        "velocity_divergence", "neighbor_temperature", "ambient_temperature", "normal_force", "contact_velocity", "slope_angle_deg",
        "shock_impulse", "shock_distance", "reactant_a", "reactant_b", "stress", "strain", "damage"};
    for (const char *channel : k_channels) {
        channels.append(String(channel));
    }
    return channels;
}

double clamped(const Variant &value, double min_v, double max_v, double fallback) {
    return std::clamp(as_number(value, fallback), min_v, max_v);
}

double pressure_window_factor(double pressure, double min_pressure, double max_pressure, double optimal_pressure) {
    if (pressure < min_pressure || pressure > max_pressure) {
        return 0.0;
    }
    const double left = std::max(1.0e-6, optimal_pressure - min_pressure);
    const double right = std::max(1.0e-6, max_pressure - optimal_pressure);
    if (pressure <= optimal_pressure) {
        return std::clamp((pressure - min_pressure) / left, 0.0, 1.0);
    }
    return std::clamp((max_pressure - pressure) / right, 0.0, 1.0);
}

Dictionary boundary_contract(const Dictionary &stage_config, const Dictionary &frame_inputs) {
    const String mode_raw = String(frame_inputs.get("boundary_mode", stage_config.get("boundary_mode", "open"))).to_lower();
    const String mode = (mode_raw == "closed" || mode_raw == "reflective") ? mode_raw : String("open");
    const double obstacle_attenuation = clamped(
        frame_inputs.get("obstacle_attenuation", stage_config.get("obstacle_attenuation", 0.0)),
        0.0,
        1.0,
        0.0);
    const double constraint_factor = clamped(frame_inputs.get("constraint_factor", stage_config.get("constraint_factor", 1.0)), 0.0, 1.0, 1.0);
    double directional_multiplier = (1.0 - obstacle_attenuation) * constraint_factor;
    if (mode == "closed") {
        directional_multiplier = 0.0;
    } else if (mode == "reflective") {
        directional_multiplier = -directional_multiplier;
    }
    return make_dictionary(
        "mode", mode,
        "obstacle_attenuation", obstacle_attenuation,
        "constraint_factor", constraint_factor,
        "directional_multiplier", directional_multiplier,
        "scalar_multiplier", std::abs(directional_multiplier));
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

    diagnostics["overall"] = make_dictionary(
        "stage_count", stage_count,
        "mass_proxy_delta_total", mass_total,
        "energy_proxy_delta_total", energy_total);
}

} // namespace local_agents::simulation::unified_pipeline
