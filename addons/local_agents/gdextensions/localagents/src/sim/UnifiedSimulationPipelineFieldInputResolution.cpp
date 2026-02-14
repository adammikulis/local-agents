#include "sim/UnifiedSimulationPipeline.hpp"
#include "sim/UnifiedSimulationPipelineInternal.hpp"
#include "sim/UnifiedSimulationPipelineFieldInputResolution.hpp"

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <algorithm>
#include <cmath>

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

} // namespace

Dictionary resolve_stage_field_inputs(
    const Dictionary &frame_inputs,
    const Array &field_handles,
    bool field_handles_provided,
    Dictionary &stage_input_diagnostics,
    const Dictionary &field_handle_cache) {
    (void)field_handles;
    Dictionary stage_inputs;
    stage_input_diagnostics.clear();
    const Array keys = frame_inputs.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        const String key = String(keys[i]);
        if (key.is_empty() || !frame_inputs.has(key)) {
            continue;
        }
        const Variant value = frame_inputs.get(key, Variant());
        const Variant::Type value_type = value.get_type();
        if (value_type == Variant::INT || value_type == Variant::FLOAT) {
            stage_inputs[key] = value;
        }
    }

    resolve_scalar_aliases(stage_inputs, frame_inputs);
    const Array hot_fields = Array::make("mass", "velocity", "pressure", "temperature", "density");
    if (field_handles_provided) {
        for (int64_t i = 0; i < hot_fields.size(); i++) {
            const String field_name = String(hot_fields[i]);
            if (field_name.is_empty()) {
                continue;
            }
            bool fallback_used = false;
            bool resolved_via_handle = false;
            String resolved_source;
            String resolved_key;
            String resolved_handle;
            int64_t attempt_count = 0;
            double resolved_scalar = 0.0;
            bool resolved = try_resolve_hot_field_from_handles(
                frame_inputs,
                field_handle_cache,
                field_name,
                resolved_scalar,
                resolved_source,
                resolved_key,
                resolved_handle,
                attempt_count);
            String fallback_reason = String();
            const bool explicit_scalar_fallback = as_bool(frame_inputs.get("compatibility_mode", Variant(false)))
                || as_bool(frame_inputs.get("compatibility_gate", Variant(false)));
            if (!resolved) {
                if (explicit_scalar_fallback) {
                    const Array candidate_keys = hot_field_candidate_keys(field_name);
                    String compatibility_key;
                    if (try_resolve_scalar_from_candidate_keys(
                            frame_inputs,
                            candidate_keys,
                            resolved_scalar,
                            compatibility_key,
                            resolved_source)) {
                        resolved = true;
                        fallback_used = true;
                        fallback_reason = String("scalar_fallback");
                        resolved_source = String("frame_inputs_scalar");
                        resolved_key = compatibility_key;
                    } else {
                        fallback_reason = String("field_handles");
                    }
                } else {
                    fallback_reason = String("field_handles");
                }
            } else {
                resolved_via_handle = true;
                fallback_reason = String();
            }

            if (resolved) {
                stage_inputs[field_name] = resolved_scalar;
            }
            stage_input_diagnostics[field_name] = unified_pipeline::make_dictionary(
                "requested_field", field_name,
                "resolved", resolved,
                "resolved_via_handle", resolved_via_handle,
                "fallback_used", fallback_used,
                "fallback_reason", fallback_reason,
                "mode", resolved_via_handle ? String("handle") : (fallback_used ? String("scalar_fallback") : String("missing")),
                "attempt_count", attempt_count,
                "resolved_source", resolved_source,
                "resolved_key", resolved_key,
                "resolved_handle", resolved_handle);
        }
        return stage_inputs;
    }

    for (int64_t i = 0; i < hot_fields.size(); i++) {
        const String field_name = String(hot_fields[i]);
        bool resolved = false;
        bool fallback_used = false;
        String resolved_source;
        String resolved_key;
        String fallback_reason = String();
        double resolved_scalar = 0.0;
        const Array candidate_keys = hot_field_candidate_keys(field_name);

        const Variant field_buffers_variant = frame_inputs.get("field_buffers", Variant());
        const Dictionary field_buffers = field_buffers_variant.get_type() == Variant::DICTIONARY
            ? Dictionary(field_buffers_variant)
            : Dictionary();
        String candidate_key;
        if (try_resolve_scalar_from_candidate_keys(
                field_buffers,
                candidate_keys,
                resolved_scalar,
                candidate_key,
                resolved_source)) {
            resolved = true;
            resolved_source = String("field_buffers");
            resolved_key = candidate_key;
            fallback_reason = String("none");
        } else if (try_resolve_scalar_from_candidate_keys(
                frame_inputs,
                candidate_keys,
                resolved_scalar,
                candidate_key,
                resolved_source)) {
            resolved = true;
            resolved_source = String("frame_inputs_scalar");
            resolved_key = candidate_key;
            fallback_reason = String("none");
        } else if (!resolved) {
            fallback_reason = String("missing");
        }

        if (resolved) {
            stage_inputs[field_name] = resolved_scalar;
        }
        stage_input_diagnostics[field_name] = unified_pipeline::make_dictionary(
            "requested_field", field_name,
            "resolved", resolved,
            "resolved_via_handle", false,
            "fallback_used", fallback_used,
            "fallback_reason", fallback_reason,
            "mode", resolved ? String("scalar") : String("missing"),
            "attempt_count", static_cast<int64_t>(0),
            "resolved_source", resolved ? resolved_source : String(),
            "resolved_key", resolved ? resolved_key : String(),
            "resolved_handle", String());
    }
    return stage_inputs;
}

double as_scalar(const Variant &value) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return 0.0;
}

String as_status_string(const Variant &value, const String &fallback) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<godot::StringName>(value));
    }
    return fallback;
}

bool as_bool(const Variant &value) {
    if (value.get_type() == Variant::BOOL) {
        return static_cast<bool>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value) != 0;
    }
    if (value.get_type() == Variant::FLOAT) {
        return std::abs(static_cast<double>(value)) >= 1.0e-12;
    }
    if (value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME) {
        return String(value).to_lower() == String("true");
    }
    return false;
}

bool is_pressure_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name) {
    const Variant field_diag_variant = stage_field_input_diagnostics.get(field_name, Dictionary());
    if (field_diag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary field_diag = field_diag_variant;
    const String mode = String(field_diag.get("mode", String()));
    if (mode != String("handle")) {
        return false;
    }
    const String resolved_source = String(field_diag.get("resolved_source", String()));
    return resolved_source == String("frame_inputs");
}

void scrub_pressure_scalar_snapshot_inputs(Dictionary &pressure_stage_field_inputs, const Dictionary &stage_field_input_diagnostics) {
    const Array pressure_hot_fields = Array::make("pressure", "density", "temperature");
    for (int64_t i = 0; i < pressure_hot_fields.size(); i++) {
        const String field_name = String(pressure_hot_fields[i]);
        if (field_name.is_empty()) {
            continue;
        }
        if (is_pressure_hot_frame_input_snapshot(stage_field_input_diagnostics, field_name)) {
            pressure_stage_field_inputs.erase(field_name);
        }
    }
}

bool is_mechanics_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name) {
    const Variant field_diag_variant = stage_field_input_diagnostics.get(field_name, Dictionary());
    if (field_diag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary field_diag = field_diag_variant;
    const String mode = String(field_diag.get("mode", String()));
    if (mode != String("handle")) {
        return false;
    }
    const String resolved_source = String(field_diag.get("resolved_source", String()));
    return resolved_source == String("frame_inputs");
}

void scrub_mechanics_scalar_snapshot_inputs(Dictionary &mechanics_stage_field_inputs, const Dictionary &stage_field_input_diagnostics) {
    const Array mechanics_hot_fields = Array::make("mass", "density", "velocity");
    for (int64_t i = 0; i < mechanics_hot_fields.size(); i++) {
        const String field_name = String(mechanics_hot_fields[i]);
        if (field_name.is_empty()) {
            continue;
        }
        if (is_mechanics_hot_frame_input_snapshot(stage_field_input_diagnostics, field_name)) {
            mechanics_stage_field_inputs.erase(field_name);
        }
    }
}

bool is_thermal_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name) {
    const Variant field_diag_variant = stage_field_input_diagnostics.get(field_name, Dictionary());
    if (field_diag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary field_diag = field_diag_variant;
    const String mode = String(field_diag.get("mode", String()));
    if (mode != String("handle")) {
        return false;
    }
    const String resolved_source = String(field_diag.get("resolved_source", String()));
    return resolved_source == String("frame_inputs");
}

void scrub_thermal_scalar_snapshot_inputs(Dictionary &thermal_stage_field_inputs, const Dictionary &stage_field_input_diagnostics) {
    const Array thermal_hot_fields = Array::make("temperature", "velocity");
    for (int64_t i = 0; i < thermal_hot_fields.size(); i++) {
        const String field_name = String(thermal_hot_fields[i]);
        if (field_name.is_empty()) {
            continue;
        }
        if (is_thermal_hot_frame_input_snapshot(stage_field_input_diagnostics, field_name)) {
            thermal_stage_field_inputs.erase(field_name);
        }
    }
}

bool is_reaction_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name) {
    const Variant field_diag_variant = stage_field_input_diagnostics.get(field_name, Dictionary());
    if (field_diag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary field_diag = field_diag_variant;
    const String mode = String(field_diag.get("mode", String()));
    if (mode != String("handle")) {
        return false;
    }
    const String resolved_source = String(field_diag.get("resolved_source", String()));
    return resolved_source == String("frame_inputs");
}

void scrub_reaction_scalar_snapshot_inputs(Dictionary &reaction_stage_field_inputs, const Dictionary &stage_field_input_diagnostics) {
    const Array reaction_hot_fields = Array::make("temperature", "pressure");
    for (int64_t i = 0; i < reaction_hot_fields.size(); i++) {
        const String field_name = String(reaction_hot_fields[i]);
        if (field_name.is_empty()) {
            continue;
        }
        if (is_reaction_hot_frame_input_snapshot(stage_field_input_diagnostics, field_name)) {
            reaction_stage_field_inputs.erase(field_name);
        }
    }
}

bool is_destruction_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name) {
    const Variant field_diag_variant = stage_field_input_diagnostics.get(field_name, Dictionary());
    if (field_diag_variant.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary field_diag = field_diag_variant;
    const String mode = String(field_diag.get("mode", String()));
    if (mode != String("handle")) {
        return false;
    }
    const String resolved_source = String(field_diag.get("resolved_source", String()));
    return resolved_source == String("frame_inputs");
}

void scrub_destruction_scalar_snapshot_inputs(Dictionary &destruction_stage_field_inputs, const Dictionary &stage_field_input_diagnostics) {
    const Array destruction_hot_fields = Array::make("mass");
    for (int64_t i = 0; i < destruction_hot_fields.size(); i++) {
        const String field_name = String(destruction_hot_fields[i]);
        if (field_name.is_empty()) {
            continue;
        }
        if (is_destruction_hot_frame_input_snapshot(stage_field_input_diagnostics, field_name)) {
            destruction_stage_field_inputs.erase(field_name);
        }
    }
}

bool pressure_stage_compatibility_fallback_enabled(const Dictionary &stage_config) {
    return as_bool(stage_config.get("compatibility_gate", Variant(false)))
        || as_bool(stage_config.get("compatibility_mode", Variant(false)));
}

Dictionary summarize_physics_server_feedback(
    const Array &destruction_results,
    const Dictionary &field_evolution) {
    Dictionary feedback;
    const Dictionary stage_coupling = field_evolution.get("coupling_scalar_diagnostics", Dictionary());
    const Array coupling_markers = field_evolution.get("coupling_markers", Array());

    feedback["schema"] = String("physics_server_feedback_v1");
    feedback["enabled"] = !destruction_results.is_empty() || field_evolution.has("updated_fields");
    feedback["destruction_stage_count"] = static_cast<int64_t>(destruction_results.size());

    double total_mass_loss = 0.0;
    double total_damage = 0.0;
    double total_damage_delta = 0.0;
    double total_damage_next = 0.0;
    double total_friction_force = 0.0;
    double total_friction_dissipation = 0.0;
    double total_fracture_energy = 0.0;
    double total_resistance = 0.0;
    double max_resistance = 0.0;
    double max_slope_failure_ratio = 0.0;
    double max_friction_force = 0.0;
    double max_overstress_ratio = 0.0;
    int64_t active_destruction_stages = 0;
    int64_t failure_watch_count = 0;
    int64_t active_failure_stages = 0;
    int64_t watch_failure_stages = 0;
    int64_t active_stage_index = -1;
    int64_t watch_stage_index = -1;
    String active_failure_mode;
    String watch_failure_mode;
    String active_failure_reason;
    String watch_failure_reason;
    double highest_failure_score = -1.0;
    Array active_modes;

    for (int64_t i = 0; i < destruction_results.size(); i += 1) {
        const Variant stage_variant = destruction_results[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = stage_variant;
        if (!bool(stage_result.get("ok", true))) {
            continue;
        }
        active_destruction_stages += 1;
        const String failure_status = as_status_string(stage_result.get("failure_status", String("stable")), String("stable"));
        const String failure_reason = as_status_string(stage_result.get("failure_reason", String("n/a")), String("n/a"));
        const String failure_mode = as_status_string(stage_result.get("failure_mode", String("stable")), String("stable"));
        const double overstress_ratio = as_scalar(stage_result.get("overstress_ratio", 0.0));
        const double friction_force_abs = std::abs(as_scalar(stage_result.get("friction_force", 0.0)));
        const double failure_score = (failure_status == String("active") ? 10000.0 : failure_status == String("watch") ? 1000.0 : 0.0) +
            std::abs(as_scalar(stage_result.get("damage_delta", 0.0))) * 100.0 +
            overstress_ratio * 20.0 +
            as_scalar(stage_result.get("friction_dissipation", 0.0)) * 0.01 +
            as_scalar(stage_result.get("slope_failure_ratio", 0.0)) * 100.0;

        const bool active_status = failure_status == String("active");
        const bool watch_status = failure_status == String("watch");
        if (active_status || watch_status) {
            failure_watch_count += 1;
            if (failure_mode != String("stable") && !active_modes.has(failure_mode)) {
                active_modes.append(failure_mode);
            }
            if (failure_score > highest_failure_score) {
                highest_failure_score = failure_score;
                active_stage_index = i;
                active_failure_mode = failure_mode;
                active_failure_reason = failure_reason;
            }
            if (active_status) {
                active_failure_stages += 1;
            } else {
                watch_failure_stages += 1;
            }
            if (watch_status && watch_stage_index < 0) {
                watch_stage_index = i;
                watch_failure_mode = failure_mode;
                watch_failure_reason = failure_reason;
            }
        }

        total_mass_loss += as_scalar(stage_result.get("mass_loss", 0.0));
        total_damage += as_scalar(stage_result.get("damage", 0.0));
        total_damage_delta += as_scalar(stage_result.get("damage_delta", 0.0));
        total_damage_next += as_scalar(stage_result.get("damage_next", 0.0));
        total_friction_force += as_scalar(stage_result.get("friction_force", 0.0));
        total_friction_dissipation += as_scalar(stage_result.get("friction_dissipation", 0.0));
        total_fracture_energy += as_scalar(stage_result.get("fracture_energy", 0.0));

        const double resistance = as_scalar(stage_result.get("resistance", 0.0));
        const double slope_failure_ratio = as_scalar(stage_result.get("slope_failure_ratio", 0.0));
        const double friction_force = as_scalar(stage_result.get("friction_force", 0.0));

        max_overstress_ratio = std::max(max_overstress_ratio, std::max(0.0, as_scalar(stage_result.get("overstress_ratio", 0.0))));

        total_resistance += resistance;
        max_resistance = std::max(max_resistance, resistance);
        max_slope_failure_ratio = std::max(max_slope_failure_ratio, slope_failure_ratio);
        max_friction_force = std::max(max_friction_force, std::abs(friction_force));
    }

    const int64_t total_failure_stages = active_failure_stages + watch_failure_stages;
    const bool has_feedback = active_destruction_stages > 0 || total_failure_stages > 0;
    const double inv_feedback_stages = has_feedback ? (1.0 / static_cast<double>(total_failure_stages)) : 0.0;

    feedback["has_feedback"] = has_feedback;
    feedback["destruction_feedback_count"] = active_destruction_stages;
    feedback["destruction"] = unified_pipeline::make_dictionary(
        "mass_loss_total", unified_pipeline::clamped(total_mass_loss, -1.0e18, 1.0e18, 0.0),
        "damage", unified_pipeline::clamped(total_damage, -1.0e6, 1.0e6, 0.0),
        "damage_delta_total", unified_pipeline::clamped(total_damage_delta, -1.0e6, 1.0e6, 0.0),
        "damage_next_total", unified_pipeline::clamped(total_damage_next, -1.0e6, 1.0e6, 0.0),
        "friction_force_total", unified_pipeline::clamped(total_friction_force, -1.0e18, 1.0e18, 0.0),
        "friction_abs_force_max", unified_pipeline::clamped(max_friction_force, 0.0, 1.0e18, 0.0),
        "friction_dissipation_total", unified_pipeline::clamped(total_friction_dissipation, -1.0e18, 1.0e18, 0.0),
        "fracture_energy_total", unified_pipeline::clamped(total_fracture_energy, -1.0e18, 1.0e18, 0.0),
        "resistance_avg", unified_pipeline::clamped(total_resistance * inv_feedback_stages, 0.0, 1.0e6, 0.0),
        "resistance_max", unified_pipeline::clamped(max_resistance, 0.0, 1.0e6, 0.0),
        "slope_failure_ratio_max", unified_pipeline::clamped(max_slope_failure_ratio, 0.0, 1.0e6, 0.0));

    String failure_source_status = String("idle");
    String failure_source_reason = String("no_failure");
    if (active_failure_stages > 0) {
        failure_source_status = String("active");
        failure_source_reason = active_failure_reason;
    } else if (failure_watch_count > 0) {
        failure_source_status = String("watch");
        failure_source_reason = watch_failure_reason.is_empty() ? String("watching_failure_regime") : watch_failure_reason;
    }

    const int64_t dominant_stage_index = (active_failure_stages > 0) ? active_stage_index : ((watch_failure_stages > 0) ? watch_stage_index : -1);
    String dominant_mode = active_failure_mode;
    if (active_failure_stages <= 0 && watch_failure_stages > 0) {
        dominant_mode = watch_failure_mode;
    }

    feedback["failure_feedback"] = unified_pipeline::make_dictionary(
        "status", failure_source_status,
        "reason", failure_source_reason,
        "active_stage_count", active_failure_stages,
        "watch_stage_count", failure_watch_count,
        "dominant_mode", dominant_mode,
        "dominant_stage_index", dominant_stage_index,
        "active_modes", active_modes);
    feedback["failure_source"] = unified_pipeline::make_dictionary(
        "source", String("destruction"),
        "status", failure_source_status,
        "reason", failure_source_reason,
        "active_count", active_failure_stages,
        "watch_count", watch_failure_stages,
        "overstress_ratio_max", unified_pipeline::clamped(max_overstress_ratio, 0.0, 1.0e6, 0.0));

    feedback["voxel_emission"] = unified_pipeline::make_dictionary(
        "status", active_failure_stages > 0 ? String("planned") : String("disabled"),
        "reason", failure_source_reason,
        "target_domain", String("environment"),
        "dominant_mode", dominant_mode,
        "active_failure_count", active_failure_stages,
        "planned_op_count", active_failure_stages > 0 ? static_cast<int64_t>(1) : 0);

    feedback["failure_coupling"] = unified_pipeline::make_dictionary(
        "damage_to_voxel_scalar", unified_pipeline::clamped(as_scalar(stage_coupling.get("damage_to_voxel_scalar", 0.0)), 0.0, 1.0e6, 0.0),
        "pressure_to_mechanics_scalar", unified_pipeline::clamped(as_scalar(stage_coupling.get("pressure_to_mechanics_scalar", 0.0)), 0.0, 1.0e6, 0.0),
        "reaction_to_thermal_scalar", unified_pipeline::clamped(as_scalar(stage_coupling.get("reaction_to_thermal_scalar", 0.0)), 0.0, 1.0e6, 0.0));

    feedback["coupling_markers_present"] = !coupling_markers.is_empty();
    return feedback;
}

} // namespace local_agents::simulation
