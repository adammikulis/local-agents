#include "sim/CoreSimulationPipelineInternal.hpp"

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
bool is_known_field_alias_added(const Array &values, const String &candidate) {
    for (int64_t i = 0; i < values.size(); i += 1) {
        const Variant known = values[i];
        if (known.get_type() == Variant::STRING && String(known) == candidate) {
            return true;
        }
    }
    return false;
}

void append_scalar_if_nonempty(Array &values, const String &candidate) {
    const String normalized = candidate.strip_edges();
    if (normalized.is_empty() || is_known_field_alias_added(values, normalized)) {
        return;
    }
    values.append(normalized);
}
} // namespace

String normalize_handle_token(const String &token) {
    const String stripped = token.strip_edges();
    if (stripped.begins_with("field::")) {
        return stripped.substr(7, stripped.length() - 7);
    }
    if (stripped.ends_with("_field")) {
        return stripped.substr(0, stripped.length() - 6);
    }
    return stripped;
}

String canonicalize_resolve_field(const String &field_name) {
    const String normalized = normalize_handle_token(field_name);
    if (normalized == String("mass_density")) {
        return String("mass");
    }
    if (normalized == String("momentum_x") || normalized == String("momentum_y") || normalized == String("momentum_z")) {
        return String("velocity");
    }
    return normalized;
}

Array build_field_source_aliases(const String &field_name) {
    Array aliases;
    const String canonical = canonicalize_resolve_field(field_name);
    append_scalar_if_nonempty(aliases, canonical);
    if (canonical == String("mass")) {
        append_scalar_if_nonempty(aliases, String("mass_density"));
    } else if (canonical == String("velocity")) {
        append_scalar_if_nonempty(aliases, String("momentum_x"));
        append_scalar_if_nonempty(aliases, String("momentum_y"));
        append_scalar_if_nonempty(aliases, String("momentum_z"));
    }
    return aliases;
}

String resolve_handle_field_from_variant(const Variant &handle_variant) {
    if (handle_variant.get_type() == Variant::STRING || handle_variant.get_type() == Variant::STRING_NAME) {
        return normalize_handle_token(String(handle_variant));
    }
    if (handle_variant.get_type() != Variant::DICTIONARY) {
        return String();
    }

    const Dictionary handle = handle_variant;
    if (handle.has("field_name")) {
        return normalize_handle_token(String(handle.get("field_name", String())));
    }
    if (handle.has("handle_id")) {
        return normalize_handle_token(String(handle.get("handle_id", String())));
    }
    if (handle.has("id")) {
        return normalize_handle_token(String(handle.get("id", String())));
    }
    if (handle.has("handle")) {
        return normalize_handle_token(String(handle.get("handle", String())));
    }
    if (handle.has("name")) {
        return normalize_handle_token(String(handle.get("name", String())));
    }
    if (handle.has("schema_row")) {
        const Variant schema_variant = handle.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
            if (schema.has("field_name")) {
                return normalize_handle_token(String(schema.get("field_name", String())));
            }
            if (schema.has("handle_id")) {
                return normalize_handle_token(String(schema.get("handle_id", String())));
            }
            if (schema.has("id")) {
                return normalize_handle_token(String(schema.get("id", String())));
            }
            if (schema.has("handle")) {
                return normalize_handle_token(String(schema.get("handle", String())));
            }
            if (schema.has("name")) {
                return normalize_handle_token(String(schema.get("name", String())));
            }
        }
    }
    return String();
}

String resolve_handle_reference_from_variant(const Variant &handle_variant, int64_t index) {
    if (handle_variant.get_type() == Variant::STRING || handle_variant.get_type() == Variant::STRING_NAME) {
        return normalize_handle_token(String(handle_variant));
    }

    if (handle_variant.get_type() != Variant::DICTIONARY) {
        return String("index::") + String::num_int64(index);
    }

    const Dictionary handle = handle_variant;
    if (handle.has("field_name")) {
        return normalize_handle_token(String(handle.get("field_name", String())));
    }
    if (handle.has("handle_id")) {
        return normalize_handle_token(String(handle.get("handle_id", String())));
    }
    if (handle.has("id")) {
        return normalize_handle_token(String(handle.get("id", String())));
    }
    if (handle.has("handle")) {
        return normalize_handle_token(String(handle.get("handle", String())));
    }
    if (handle.has("name")) {
        return normalize_handle_token(String(handle.get("name", String())));
    }
    if (handle.has("schema_row")) {
        const Variant schema_variant = handle.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
            if (schema.has("field_name")) {
                return normalize_handle_token(String(schema.get("field_name", String())));
            }
            if (schema.has("handle_id")) {
                return normalize_handle_token(String(schema.get("handle_id", String())));
            }
            if (schema.has("id")) {
                return normalize_handle_token(String(schema.get("id", String())));
            }
            if (schema.has("handle")) {
                return normalize_handle_token(String(schema.get("handle", String())));
            }
            if (schema.has("name")) {
                return normalize_handle_token(String(schema.get("name", String())));
            }
        }
    }
    return String("index::") + String::num_int64(index);
}

Dictionary build_handle_field_cache(const Array &field_handles, int64_t max_handles) {
    Dictionary field_handle_cache;
    if (max_handles <= 0) {
        return field_handle_cache;
    }
    const int64_t handle_limit = std::min<int64_t>(field_handles.size(), max_handles);
    for (int64_t i = 0; i < handle_limit; i += 1) {
        const Variant handle_variant = field_handles[i];
        const String canonical_field = canonicalize_resolve_field(resolve_handle_field_from_variant(handle_variant));
        if (canonical_field.is_empty()) {
            continue;
        }
        const String handle_ref = resolve_handle_reference_from_variant(handle_variant, i);
        if (handle_ref.is_empty()) {
            continue;
        }
        Array refs;
        const Variant refs_variant = field_handle_cache.get(canonical_field, Array());
        if (refs_variant.get_type() == Variant::ARRAY) {
            refs = refs_variant;
        }
        refs.append(handle_ref);
        field_handle_cache[canonical_field] = refs;
    }
    return field_handle_cache;
}

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
    const String mode_raw = String(frame_inputs.get("boundary_mode", stage_config.get("boundary_mode", "open"))).to_lower().strip_edges();
    String mode;
    if (mode_raw == "open" || mode_raw == "inflow/outflow") {
        mode = String("open");
    } else if (mode_raw == "reflective") {
        mode = String("reflective");
    } else if (mode_raw == "no-slip" || mode_raw == "no-penetration") {
        mode = mode_raw;
    } else if (mode_raw == "closed") {
        mode = String("no-slip");
    } else {
        mode = String("open");
    }
    const double obstacle_attenuation = clamped(
        frame_inputs.get("obstacle_attenuation", stage_config.get("obstacle_attenuation", 0.0)),
        0.0,
        1.0,
        0.0);
    const double obstacle_velocity = std::abs(as_number(frame_inputs.get("obstacle_velocity", stage_config.get("obstacle_velocity", 0.0)), 0.0));
    const double moving_obstacle_speed_scale = clamped(
        frame_inputs.get("moving_obstacle_speed_scale", stage_config.get("moving_obstacle_speed_scale", 0.0)),
        0.0,
        1.0e6,
        0.0);
    const double effective_obstacle_attenuation = std::clamp(obstacle_attenuation + obstacle_velocity * moving_obstacle_speed_scale, 0.0, 1.0);
    const double constraint_factor = clamped(frame_inputs.get("constraint_factor", stage_config.get("constraint_factor", 1.0)), 0.0, 1.0, 1.0);
    double directional_multiplier = (1.0 - effective_obstacle_attenuation) * constraint_factor;
    if (mode == "no-slip" || mode == "no-penetration") {
        directional_multiplier = 0.0;
    } else if (mode == "reflective") {
        directional_multiplier = -directional_multiplier;
    }
    const Variant obstacle_trajectory = frame_inputs.get("obstacle_trajectory", stage_config.get("obstacle_trajectory", Variant()));
    return make_dictionary(
        "mode", mode,
        "obstacle_attenuation", obstacle_attenuation,
        "obstacle_velocity", obstacle_velocity,
        "obstacle_trajectory", obstacle_trajectory,
        "moving_obstacle_speed_scale", moving_obstacle_speed_scale,
        "effective_obstacle_attenuation", effective_obstacle_attenuation,
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
