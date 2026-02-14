#include "sim/CoreSimulationPipelineFieldInputResolutionScalarHelpers.hpp"

#include "sim/CoreSimulationPipelineInternal.hpp"

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace local_agents::simulation {

namespace {

double as_number(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT || value.get_type() == Variant::INT) {
        return static_cast<double>(value);
    }
    return fallback;
}

void append_scalar_if_nonempty(Array &values, const String &candidate) {
    if (candidate.is_empty()) {
        return;
    }
    const String normalized = candidate.strip_edges();
    if (normalized.is_empty()) {
        return;
    }
    for (int64_t i = 0; i < values.size(); i++) {
        if (String(values[i]).strip_edges() == normalized) {
            return;
        }
    }
    values.append(normalized);
}

bool as_scalar_mean(const Variant &value, double &scalar_value) {
    double total = 0.0;
    int64_t count = 0;
    if (value.get_type() == Variant::ARRAY) {
        const Array source = value;
        for (int64_t i = 0; i < source.size(); i++) {
            const Variant sample_variant = source[i];
            if (sample_variant.get_type() != Variant::INT && sample_variant.get_type() != Variant::FLOAT) {
                continue;
            }
            total += as_number(sample_variant, 0.0);
            count += 1;
        }
    } else if (value.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
        const godot::PackedFloat32Array source = value;
        for (int64_t i = 0; i < source.size(); i++) {
            total += static_cast<double>(source[i]);
            count += 1;
        }
    } else if (value.get_type() == Variant::PACKED_FLOAT64_ARRAY) {
        const godot::PackedFloat64Array source = value;
        for (int64_t i = 0; i < source.size(); i++) {
            total += source[i];
            count += 1;
        }
    } else if (value.get_type() == Variant::INT || value.get_type() == Variant::FLOAT) {
        scalar_value = as_number(value, 0.0);
        return true;
    } else {
        return false;
    }
    if (count == 0) {
        return false;
    }
    scalar_value = total / static_cast<double>(count);
    return true;
}

} // namespace

Array hot_field_candidate_keys(const String &requested_field) {
    const String canonical = unified_pipeline::canonicalize_resolve_field(requested_field);
    Array candidate_keys = unified_pipeline::build_field_source_aliases(canonical);
    const int64_t alias_count = candidate_keys.size();
    for (int64_t i = 0; i < alias_count; i += 1) {
        const String alias = String(candidate_keys[i]).strip_edges();
        append_scalar_if_nonempty(candidate_keys, alias + String("_field"));
    }
    return candidate_keys;
}

bool try_resolve_scalar_from_candidate_keys(
    const Dictionary &container,
    const Array &candidate_keys,
    double &scalar_value,
    String &resolved_key,
    String &resolution_key) {
    for (int64_t i = 0; i < candidate_keys.size(); i++) {
        const String candidate = String(candidate_keys[i]).strip_edges();
        if (candidate.is_empty()) {
            continue;
        }
        const Variant value = container.get(candidate, Variant());
        if (value == Variant()) {
            continue;
        }
        if (!as_scalar_mean(value, scalar_value)) {
            continue;
        }
        resolved_key = candidate;
        resolution_key = String("container.") + candidate;
        return true;
    }
    return false;
}

bool try_resolve_hot_field_from_handles(
    const Dictionary &frame_inputs,
    const Dictionary &field_handle_cache,
    const String &requested_field,
    double &out_scalar,
    String &resolved_source,
    String &resolved_key,
    String &matched_handle,
    int64_t &attempt_count) {
    attempt_count = 0;
    const Dictionary field_buffers = frame_inputs.get("field_buffers", Dictionary());
    const String normalized_requested_field = unified_pipeline::canonicalize_resolve_field(requested_field);
    const Array candidate_keys = hot_field_candidate_keys(normalized_requested_field);
    const Array cached_handle_refs = field_handle_cache.get(normalized_requested_field, Array());
    for (int64_t i = 0; i < cached_handle_refs.size() && i < 512; i += 1) {
        const String handle_ref = String(cached_handle_refs[i]).strip_edges();
        if (handle_ref.is_empty()) {
            continue;
        }
        matched_handle = handle_ref;
        String candidate_key;
        if (try_resolve_scalar_from_candidate_keys(field_buffers, candidate_keys, out_scalar, candidate_key, resolved_source)) {
            resolved_key = candidate_key;
            resolved_source = String("field_buffers");
            return true;
        }
        attempt_count += 1;
        if (try_resolve_scalar_from_candidate_keys(frame_inputs, candidate_keys, out_scalar, candidate_key, resolved_source)) {
            resolved_key = candidate_key;
            resolved_source = String("frame_inputs");
            return true;
        }
    }
    return false;
}

void resolve_scalar_aliases(Dictionary &stage_inputs, const Dictionary &frame_inputs) {
    if (!stage_inputs.has("mass") && frame_inputs.has("mass_density")) {
        stage_inputs["mass"] = frame_inputs.get("mass_density", 0.0);
    }
    if (!stage_inputs.has("velocity") && frame_inputs.has("momentum_x")) {
        stage_inputs["velocity"] = frame_inputs.get("momentum_x", 0.0);
    }
    if (!stage_inputs.has("liquid_fraction") && frame_inputs.has("phase_fraction_liquid")) {
        stage_inputs["liquid_fraction"] = frame_inputs.get("phase_fraction_liquid", 0.0);
    }
    if (!stage_inputs.has("vapor_fraction") && frame_inputs.has("phase_fraction_vapor")) {
        stage_inputs["vapor_fraction"] = frame_inputs.get("phase_fraction_vapor", 0.0);
    }
    if (!stage_inputs.has("phase_transition_capacity") && frame_inputs.has("yield_strength")) {
        stage_inputs["phase_transition_capacity"] = frame_inputs.get("yield_strength", 1.0);
    }
}

} // namespace local_agents::simulation
