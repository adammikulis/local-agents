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

bool is_known_field_alias_added(const Array &values, const String &candidate) {
    for (int64_t i = 0; i < values.size(); i += 1) {
        const Variant known = values[i];
        if (known.get_type() == Variant::STRING && String(known) == candidate) {
            return true;
        }
    }
    return false;
}

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

void append_scalar_if_nonempty(Array &values, const String &candidate) {
    if (!candidate.is_empty() && !is_known_field_alias_added(values, candidate)) {
        values.append(candidate);
    }
}

Array build_field_source_aliases(const String &field_name) {
    Array aliases;
    append_scalar_if_nonempty(aliases, field_name);
    if (field_name == String("mass")) {
        append_scalar_if_nonempty(aliases, String("mass_density"));
    } else if (field_name == String("velocity")) {
        append_scalar_if_nonempty(aliases, String("momentum_x"));
    }
    return aliases;
}

String field_name_from_handle(const Variant &handle_variant) {
    if (handle_variant.get_type() != Variant::DICTIONARY) {
        if (handle_variant.get_type() == Variant::STRING || handle_variant.get_type() == Variant::STRING_NAME) {
            return normalize_handle_token(String(handle_variant));
        }
        return String();
    }
    const Dictionary handle = handle_variant;
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
    if (handle.has("field_name")) {
        return normalize_handle_token(String(handle.get("field_name", String())));
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

String handle_reference_from_variant(const Variant &handle_variant, int64_t index) {
    if (handle_variant.get_type() != Variant::DICTIONARY) {
        if (handle_variant.get_type() == Variant::STRING || handle_variant.get_type() == Variant::STRING_NAME) {
            return normalize_handle_token(String(handle_variant));
        }
        return String("index::") + String::num_int64(index);
    }
    const Dictionary handle = handle_variant;
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
    if (handle.has("field_name")) {
        return normalize_handle_token(String(handle.get("field_name", String())));
    }
    if (handle.has("schema_row")) {
        const Variant schema_variant = handle.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
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
            if (schema.has("field_name")) {
                return normalize_handle_token(String(schema.get("field_name", String())));
            }
        }
    }
    return String("index::") + String::num_int64(index);
}

Array collect_handle_lookup_keys(const Variant &handle_variant) {
    Array keys;
    if (handle_variant.get_type() != Variant::DICTIONARY) {
        append_scalar_if_nonempty(keys, String(handle_variant).strip_edges());
        return keys;
    }

    const Dictionary handle = handle_variant;
    append_scalar_if_nonempty(keys, String(handle.get("handle_id", String())).strip_edges());
    append_scalar_if_nonempty(keys, String(handle.get("id", String())).strip_edges());
    append_scalar_if_nonempty(keys, String(handle.get("handle", String())).strip_edges());
    append_scalar_if_nonempty(keys, String(handle.get("name", String())).strip_edges());
    append_scalar_if_nonempty(keys, String(handle.get("field_name", String())).strip_edges());
    if (handle.has("schema_row")) {
        const Variant schema_variant = handle.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
            append_scalar_if_nonempty(keys, String(schema.get("handle_id", String())).strip_edges());
            append_scalar_if_nonempty(keys, String(schema.get("id", String())).strip_edges());
            append_scalar_if_nonempty(keys, String(schema.get("handle", String())).strip_edges());
            append_scalar_if_nonempty(keys, String(schema.get("field_name", String())).strip_edges());
            append_scalar_if_nonempty(keys, String(schema.get("name", String())).strip_edges());
        }
    }
    const int64_t key_count = keys.size();
    for (int64_t i = 0; i < key_count; i++) {
        const String key = String(keys[i]).strip_edges();
        if (key.is_empty()) {
            continue;
        }
        if (key.begins_with("field::")) {
            append_scalar_if_nonempty(keys, key.substr(7, key.length() - 7));
        }
        if (key.ends_with("_field")) {
            append_scalar_if_nonempty(keys, key.substr(0, key.length() - 6));
        }
    }
    return keys;
}

void append_resolution_attempt(
    Array &attempts,
    const String &source,
    const String &path,
    const String &candidate,
    const String &handle_ref,
    bool found) {
    attempts.append(unified_pipeline::make_dictionary(
        "source", source,
        "path", path,
        "candidate", candidate,
        "handle_reference", handle_ref,
        "found", found));
}

bool try_resolve_numeric_candidates(
    const Dictionary &container,
    const String &source,
    const String &path,
    const String &handle_ref,
    const Array &candidate_keys,
    Array &out_values,
    String &resolved_key,
    Array &attempts) {
    for (int64_t i = 0; i < candidate_keys.size(); i += 1) {
        const String candidate = String(candidate_keys[i]).strip_edges();
        if (candidate.is_empty()) {
            continue;
        }
        const Array values = to_numeric_array(container.get(candidate, Variant()));
        const bool found = !values.is_empty();
        append_resolution_attempt(attempts, source, path, candidate, handle_ref, found);
        if (found) {
            out_values = values;
            resolved_key = candidate;
            return true;
        }
    }
    return false;
}

Dictionary summarize_field_resolution_diagnostics(const Dictionary &field_resolution_by_field) {
    const char *requested_fields[] = {"mass", "pressure", "temperature", "velocity", "density"};
    int64_t requested_field_count = 0;
    int64_t resolved_count = 0;
    int64_t resolved_via_handle_count = 0;
    int64_t resolved_via_fallback_count = 0;
    int64_t fallback_usage_count = 0;
    int64_t miss_count = 0;
    Array missing_fields;
    for (int64_t i = 0; i < 5; i += 1) {
        requested_field_count += 1;
        const String field_name = String(requested_fields[i]);
        const Variant field_diag_variant = field_resolution_by_field.get(field_name, Dictionary());
        if (field_diag_variant.get_type() != Variant::DICTIONARY) {
            miss_count += 1;
            missing_fields.append(field_name);
            continue;
        }
        const Dictionary field_diag = field_diag_variant;
        const bool resolved = static_cast<bool>(field_diag.get("resolved", false));
        if (!resolved) {
            miss_count += 1;
            missing_fields.append(field_name);
            continue;
        }
        resolved_count += 1;
        const bool used_handle = static_cast<bool>(field_diag.get("resolved_via_handle", false));
        const bool used_fallback = static_cast<bool>(field_diag.get("fallback_used", false));
        if (used_handle) {
            resolved_via_handle_count += 1;
        } else if (used_fallback) {
            resolved_via_fallback_count += 1;
        }
        if (used_fallback) {
            fallback_usage_count += 1;
        }
    }

    return unified_pipeline::make_dictionary(
        "requested_field_count", requested_field_count,
        "resolved_count", resolved_count,
        "resolved_via_handle_count", resolved_via_handle_count,
        "resolved_via_fallback_count", resolved_via_fallback_count,
        "fallback_usage_count", fallback_usage_count,
        "miss_count", miss_count,
        "missing_fields", missing_fields,
        "by_field", field_resolution_by_field.duplicate(true));
}

String normalize_handle_field_for_evolution(const String &handle_field_name) {
    if (handle_field_name == String("mass_density")) {
        return String("mass");
    }
    if (handle_field_name == String("momentum_x") || handle_field_name == String("momentum_y") || handle_field_name == String("momentum_z")) {
        return String("velocity");
    }
    return handle_field_name;
}

double as_number(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

int64_t as_index(const Variant &value, int64_t fallback) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(static_cast<double>(value));
    }
    return fallback;
}

Array to_numeric_array(const Variant &value) {
    Array out;
    if (value.get_type() == Variant::ARRAY) {
        const Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = as_number(source[i], 0.0);
        }
        return out;
    }
    if (value.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
        const PackedFloat32Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = static_cast<double>(source[i]);
        }
        return out;
    }
    if (value.get_type() == Variant::PACKED_FLOAT64_ARRAY) {
        const PackedFloat64Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = source[i];
        }
        return out;
    }
    return out;
}

Array to_topology_row(const Variant &value) {
    Array row;
    if (value.get_type() == Variant::ARRAY) {
        const Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = as_index(source[i], -1);
        }
        return row;
    }
    if (value.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = static_cast<int64_t>(source[i]);
        }
        return row;
    }
    if (value.get_type() == Variant::PACKED_INT64_ARRAY) {
        const PackedInt64Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = static_cast<int64_t>(source[i]);
        }
        return row;
    }
    return row;
}

Array to_topology(const Variant &value) {
    Array topology;
    if (value.get_type() != Variant::ARRAY) {
        return topology;
    }
    const Array source = value;
    topology.resize(source.size());
    for (int64_t i = 0; i < source.size(); i++) {
        topology[i] = to_topology_row(source[i]);
    }
    return topology;
}

Array read_field_evolution_buffer(
    const Dictionary &field_buffers,
    const Dictionary &frame_inputs,
    const Array &field_handles,
    const String &requested_field,
    Dictionary &field_resolution_by_field) {
    Dictionary field_diagnostics = unified_pipeline::make_dictionary(
        "requested_field", requested_field,
        "resolved", false,
        "resolved_via_handle", false,
        "fallback_used", false,
        "status", String("missing"),
        "resolved_source", String(),
        "resolved_key", String(),
        "attempt_count", static_cast<int64_t>(0),
        "matched_handle_count", static_cast<int64_t>(0),
        "attempts", Array());
    Array attempts;
    Array aliases = build_field_source_aliases(requested_field);
    Array matched_handle_refs;
    bool resolved = false;
    bool resolved_via_handle = false;
    bool fallback_used = false;
    Array resolved_values;
    String resolved_source;
    String resolved_key;
    String resolved_path;
    String resolved_via_handle_ref;

    const String normalized_requested_field = normalize_handle_field_for_evolution(requested_field);
    for (int64_t i = 0; i < field_handles.size() && !resolved; i += 1) {
        const String source_field = field_name_from_handle(field_handles[i]);
        const String handle_field = normalize_handle_field_for_evolution(source_field);
        if (handle_field.is_empty() || handle_field != normalized_requested_field) {
            continue;
        }
        const String handle_ref = handle_reference_from_variant(field_handles[i], i);
        append_scalar_if_nonempty(matched_handle_refs, handle_ref);
        Array handle_lookup_keys = collect_handle_lookup_keys(field_handles[i]);
        String candidate_key;
        if (try_resolve_numeric_candidates(
                field_buffers,
                String("field_buffers"),
                String("handle_backed"),
                handle_ref,
                handle_lookup_keys,
                resolved_values,
                candidate_key,
                attempts)) {
            resolved = true;
            resolved_via_handle = true;
            resolved_via_handle_ref = handle_ref;
            resolved_source = String("field_buffers");
            resolved_key = candidate_key;
            resolved_path = String("handle_backed");
            break;
        }
        if (try_resolve_numeric_candidates(
                frame_inputs,
                String("frame_inputs"),
                String("handle_backed"),
                handle_ref,
                handle_lookup_keys,
                resolved_values,
                candidate_key,
                attempts)) {
            resolved = true;
            resolved_via_handle = true;
            resolved_via_handle_ref = handle_ref;
            resolved_source = String("frame_inputs");
            resolved_key = candidate_key;
            resolved_path = String("handle_backed");
            break;
        }
    }

    if (!resolved) {
        fallback_used = true;
        for (int64_t i = 0; i < aliases.size() && !resolved; i += 1) {
            const String alias = String(aliases[i]).strip_edges();
            if (alias.is_empty()) {
                continue;
            }
            Array alias_keys;
            alias_keys.append(alias);
            String candidate_key;
            if (try_resolve_numeric_candidates(
                    field_buffers,
                    String("field_buffers"),
                    String("fallback"),
                    String(),
                    alias_keys,
                    resolved_values,
                    candidate_key,
                    attempts)) {
                resolved = true;
                resolved_source = String("field_buffers");
                resolved_key = candidate_key;
                resolved_path = String("fallback");
                break;
            }

            if (try_resolve_numeric_candidates(
                    frame_inputs,
                    String("frame_inputs"),
                    String("fallback"),
                    String(),
                    alias_keys,
                    resolved_values,
                    candidate_key,
                    attempts)) {
                resolved = true;
                resolved_source = String("frame_inputs");
                resolved_key = candidate_key;
                resolved_path = String("fallback");
                break;
            }

            const String alias_field = alias + String("_field");
            if (alias_field != alias) {
                Array alias_field_keys;
                alias_field_keys.append(alias_field);
                if (try_resolve_numeric_candidates(
                        frame_inputs,
                        String("frame_inputs"),
                        String("fallback_field"),
                        String(),
                        alias_field_keys,
                        resolved_values,
                        candidate_key,
                        attempts)) {
                    resolved = true;
                    resolved_source = String("frame_inputs");
                    resolved_key = candidate_key;
                    resolved_path = String("fallback_field");
                    break;
                }
            }
        }
    }

    field_diagnostics["resolved"] = resolved;
    field_diagnostics["resolved_via_handle"] = resolved_via_handle;
    field_diagnostics["fallback_used"] = fallback_used;
    field_diagnostics["mode"] = resolved_via_handle ? String("handle") : (fallback_used ? String("fallback") : String("none"));
    field_diagnostics["attempt_count"] = static_cast<int64_t>(attempts.size());
    field_diagnostics["matched_handle_count"] = static_cast<int64_t>(matched_handle_refs.size());
    field_diagnostics["matched_handles"] = matched_handle_refs;
    field_diagnostics["resolved_source"] = resolved_source;
    field_diagnostics["resolved_key"] = resolved_key;
    field_diagnostics["resolved_path"] = resolved_path;
    field_diagnostics["status"] = resolved ? String("resolved") : String("missing");
    if (resolved_via_handle && !resolved_via_handle_ref.is_empty()) {
        field_diagnostics["resolved_handle_ref"] = resolved_via_handle_ref;
    }
    field_diagnostics["attempts"] = attempts;
    if (!resolved_key.is_empty()) {
        field_diagnostics["resolved_value_count"] = static_cast<int64_t>(resolved_values.size());
    }

    field_resolution_by_field[requested_field] = field_diagnostics;

    if (!resolved_values.is_empty()) {
        return resolved_values;
    }
    return Array();
}

double sum_array(const Array &values) {
    double total = 0.0;
    for (int64_t i = 0; i < values.size(); i++) {
        total += as_number(values[i], 0.0);
    }
    return total;
}

double proxy_energy_total(const Array &mass, const Array &velocity, const Array &pressure, const Array &temperature) {
    const int64_t count = std::min(std::min(mass.size(), velocity.size()), std::min(pressure.size(), temperature.size()));
    double total = 0.0;
    for (int64_t i = 0; i < count; i++) {
        const double m = std::max(1.0e-9, as_number(mass[i], 0.0));
        const double v = as_number(velocity[i], 0.0);
        const double p = as_number(pressure[i], 0.0);
        const double t = as_number(temperature[i], 0.0);
        total += 0.5 * m * v * v + p + t;
    }
    return total;
}

double averaged_stage_param(const Array &stages, const char *key, double fallback, double min_v, double max_v) {
    double total = 0.0;
    int64_t count = 0;
    for (int64_t i = 0; i < stages.size(); i++) {
        const Variant stage_variant = stages[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage = stage_variant;
        total += clamped(stage.get(String(key), fallback), min_v, max_v, fallback);
        count += 1;
    }
    if (count == 0) {
        return fallback;
    }
    return total / static_cast<double>(count);
}

void copy_if_missing(Array &target, const Array &source, double fill) {
    if (!target.is_empty()) {
        return;
    }
    target.resize(source.size());
    for (int64_t i = 0; i < source.size(); i++) {
        target[i] = fill;
    }
}

void apply_surface_group_smoothing(
    Array &velocity,
    const Array &pressure,
    const Array &density,
    const Array &topology,
    double blend,
    double density_scale) {
    if (blend <= 0.0 || velocity.is_empty()) {
        return;
    }
    const int64_t cell_count = velocity.size();
    if (pressure.size() != cell_count || density.size() != cell_count || topology.size() != cell_count) {
        return;
    }

    const double safe_density_scale = std::max(1.0e-6, density_scale);
    Array smoothed = velocity.duplicate(true);
    for (int64_t i = 0; i < cell_count; i++) {
        const Array neighbors = to_topology_row(topology[i]);
        if (neighbors.is_empty()) {
            continue;
        }
        const double local_density = as_number(density[i], 0.0);
        if (local_density <= 0.0) {
            continue;
        }
        const double depth_factor = std::clamp(1.0 - (local_density / safe_density_scale), 0.0, 1.0);
        const double local_blend = blend * depth_factor;
        if (local_blend <= 0.0) {
            continue;
        }

        double pressure_sum = as_number(pressure[i], 0.0);
        double pressure_weight_sum = 1.0;
        double velocity_sum = as_number(velocity[i], 0.0);
        for (int64_t n = 0; n < neighbors.size(); n++) {
            const int64_t neighbor = as_index(neighbors[n], -1);
            if (neighbor < 0 || neighbor >= cell_count) {
                continue;
            }
            const double neighbor_velocity = as_number(velocity[neighbor], 0.0);
            const double neighbor_pressure = as_number(pressure[neighbor], 0.0);
            const double pressure_delta = std::abs(pressure_sum - neighbor_pressure);
            const double pressure_gate = std::exp(-pressure_delta / safe_density_scale);
            velocity_sum += pressure_gate * neighbor_velocity;
            pressure_sum += pressure_gate * neighbor_pressure;
            pressure_weight_sum += pressure_gate;
        }
        if (pressure_weight_sum <= 0.0) {
            continue;
        }
        const double smoothed_velocity = velocity_sum / pressure_weight_sum;
        smoothed[i] = as_number(velocity[i], 0.0) + local_blend * (smoothed_velocity - as_number(velocity[i], 0.0));
    }
    velocity = smoothed;
}

void set_default_topology(Array &topology, int64_t count) {
    if (!topology.is_empty()) {
        return;
    }
    topology.resize(count);
    for (int64_t i = 0; i < count; i++) {
        Array neighbors;
        if (i > 0) {
            neighbors.append(i - 1);
        }
        if (i + 1 < count) {
            neighbors.append(i + 1);
        }
        topology[i] = neighbors;
    }
}

Array wave_a_coupling_markers() {
    Array markers;
    markers.append(String("pressure->mechanics"));
    markers.append(String("reaction->thermal"));
    markers.append(String("damage->voxel"));
    return markers;
}

Dictionary wave_a_stage_coupling(double pressure_to_mechanics, double reaction_to_thermal, double damage_to_voxel) {
    Dictionary stage_coupling;
    stage_coupling["pressure->mechanics"] = unified_pipeline::make_dictionary(
        "marker", String("pressure->mechanics"),
        "wave", String("A"),
        "source_stage", String("pressure"),
        "target_stage", String("mechanics"),
        "scalar", pressure_to_mechanics);
    stage_coupling["reaction->thermal"] = unified_pipeline::make_dictionary(
        "marker", String("reaction->thermal"),
        "wave", String("A"),
        "source_stage", String("reaction"),
        "target_stage", String("thermal"),
        "scalar", reaction_to_thermal);
    stage_coupling["damage->voxel"] = unified_pipeline::make_dictionary(
        "marker", String("damage->voxel"),
        "wave", String("A"),
        "source_stage", String("damage"),
        "target_stage", String("voxel"),
        "scalar", damage_to_voxel);
    return stage_coupling;
}

Dictionary wave_a_coupling_scalar_diagnostics(
    double pressure_to_mechanics,
    double reaction_to_thermal,
    double damage_to_voxel,
    double mechanics_rate,
    double pressure_diffusivity,
    double thermal_diffusivity,
    double mass_transfer_coeff) {
    return unified_pipeline::make_dictionary(
        "pressure_to_mechanics_scalar", pressure_to_mechanics,
        "reaction_to_thermal_scalar", reaction_to_thermal,
        "damage_to_voxel_scalar", damage_to_voxel,
        "mechanics_exchange_rate", mechanics_rate,
        "pressure_diffusivity", pressure_diffusivity,
        "thermal_diffusivity", thermal_diffusivity,
        "mass_transfer_coeff", mass_transfer_coeff);
}

} // namespace

Dictionary run_field_buffer_evolution(
    const Dictionary &config,
    const Array &mechanics_stages,
    const Array &pressure_stages,
    const Array &thermal_stages,
    const Dictionary &frame_inputs,
    const Array &field_handles,
    double delta_seconds) {
    const Dictionary field_buffers = frame_inputs.get("field_buffers", Dictionary());
    Dictionary field_resolution_by_field;

    Array mass = read_field_evolution_buffer(field_buffers, frame_inputs, field_handles, String("mass"), field_resolution_by_field);
    Array pressure = read_field_evolution_buffer(field_buffers, frame_inputs, field_handles, String("pressure"), field_resolution_by_field);
    Array temperature = read_field_evolution_buffer(field_buffers, frame_inputs, field_handles, String("temperature"), field_resolution_by_field);
    Array velocity = read_field_evolution_buffer(field_buffers, frame_inputs, field_handles, String("velocity"), field_resolution_by_field);
    Array density = read_field_evolution_buffer(field_buffers, frame_inputs, field_handles, String("density"), field_resolution_by_field);
    const Dictionary field_handle_resolution_diagnostics = summarize_field_resolution_diagnostics(field_resolution_by_field);
    Array topology = to_topology(field_buffers.get("neighbor_topology", frame_inputs.get("neighbor_topology", Variant())));

    String mode = "array";
    if (mass.is_empty() || pressure.is_empty() || temperature.is_empty() || velocity.is_empty()) {
        const Array cells = field_buffers.get("cells", frame_inputs.get("cells", Array()));
        if (!cells.is_empty()) {
            mode = "cell";
            mass.clear();
            pressure.clear();
            temperature.clear();
            velocity.clear();
            density.clear();
            topology.clear();
            mass.resize(cells.size());
            pressure.resize(cells.size());
            temperature.resize(cells.size());
            velocity.resize(cells.size());
            density.resize(cells.size());
            topology.resize(cells.size());
            for (int64_t i = 0; i < cells.size(); i++) {
                const Variant cell_variant = cells[i];
                if (cell_variant.get_type() != Variant::DICTIONARY) {
                    mass[i] = 0.0;
                    pressure[i] = 0.0;
                    temperature[i] = 0.0;
                    velocity[i] = 0.0;
                    density[i] = 0.0;
                    topology[i] = Array();
                    continue;
                }
                const Dictionary cell = cell_variant;
                    mass[i] = clamped(cell.get("mass", 0.0), 0.0, 1.0e9, 0.0);
                    pressure[i] = clamped(cell.get("pressure", 0.0), -1.0e9, 1.0e9, 0.0);
                    temperature[i] = clamped(cell.get("temperature", 0.0), 0.0, 2.0e4, 0.0);
                    velocity[i] = clamped(cell.get("velocity", 0.0), -1.0e6, 1.0e6, 0.0);
                    density[i] = clamped(cell.get("density", cell.get("mass", 0.0)), 0.0, 1.0e9, cell.get("mass", 0.0));
                topology[i] = to_topology_row(cell.get("neighbors", Array()));
            }
        }
    }

    if (mass.is_empty() || pressure.is_empty() || temperature.is_empty() || velocity.is_empty()) {
        Dictionary result = unified_pipeline::make_dictionary(
            "enabled", false,
            "mode", String("none"),
            "cell_count_updated", static_cast<int64_t>(0),
            "mass_drift_proxy", 0.0,
            "energy_drift_proxy", 0.0,
            "pair_updates", static_cast<int64_t>(0));
        result["stage_coupling"] = wave_a_stage_coupling(0.0, 0.0, 0.0);
        result["coupling_markers"] = wave_a_coupling_markers();
        result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        result["handle_resolution_diagnostics"] = field_handle_resolution_diagnostics;
        return result;
    }

    const int64_t cell_count = std::min(std::min(mass.size(), pressure.size()), std::min(temperature.size(), velocity.size()));
    if (cell_count <= 0) {
        Dictionary result = unified_pipeline::make_dictionary(
            "enabled", false,
            "mode", String("none"),
            "cell_count_updated", static_cast<int64_t>(0),
            "mass_drift_proxy", 0.0,
            "energy_drift_proxy", 0.0,
            "pair_updates", static_cast<int64_t>(0));
        result["stage_coupling"] = wave_a_stage_coupling(0.0, 0.0, 0.0);
        result["coupling_markers"] = wave_a_coupling_markers();
        result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        result["handle_resolution_diagnostics"] = field_handle_resolution_diagnostics;
        return result;
    }

    Array mass_next = mass.duplicate();
    Array pressure_next = pressure.duplicate();
    Array temperature_next = temperature.duplicate();
    Array velocity_next = velocity.duplicate();
    Array density_next = density.duplicate();
    mass_next.resize(cell_count);
    pressure_next.resize(cell_count);
    temperature_next.resize(cell_count);
    velocity_next.resize(cell_count);
    density_next.resize(cell_count);
    copy_if_missing(density_next, mass_next, 0.0);
    if (density_next.size() != cell_count) {
        density_next.resize(cell_count);
        for (int64_t i = 0; i < cell_count; i++) {
            density_next[i] = clamped(density_next[i], 0.0, 1.0e9, clamped(mass_next[i], 0.0, 1.0e9, 0.0));
        }
    }

    set_default_topology(topology, cell_count);

    const double mechanics_rate = averaged_stage_param(
        mechanics_stages,
        "neighbor_exchange_rate",
        clamped(config.get("field_mechanics_exchange_rate", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double pressure_diffusivity = averaged_stage_param(
        pressure_stages,
        "neighbor_diffusivity",
        clamped(config.get("field_pressure_diffusivity", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double thermal_diffusivity = averaged_stage_param(
        thermal_stages,
        "neighbor_diffusivity",
        clamped(config.get("field_thermal_diffusivity", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double mass_transfer_coeff = clamped(config.get("field_mass_transfer_coeff", pressure_diffusivity * 0.1), 0.0, 1.0e6, pressure_diffusivity * 0.1);
    const double pressure_to_mechanics_scalar = mechanics_rate * pressure_diffusivity;
    const double reaction_to_thermal_scalar = clamped(config.get("field_reaction_thermal_coupling", thermal_diffusivity), 0.0, 1.0e6, thermal_diffusivity);
    const double damage_to_voxel_scalar = clamped(config.get("field_damage_voxel_coupling", mass_transfer_coeff), 0.0, 1.0e6, mass_transfer_coeff);
    const double surface_grouping_blend = clamped(config.get("field_surface_grouping_blend", 0.0), 0.0, 1.0, 0.0);
    const double surface_density_scale = clamped(config.get("field_surface_density_scale", 4.0), 1.0e-6, 1.0e9, 4.0);

    Array mass_updated = mass_next.duplicate();
    Array pressure_updated = pressure_next.duplicate();
    Array temperature_updated = temperature_next.duplicate();
    Array velocity_updated = velocity_next.duplicate();
    Array density_updated = density_next.duplicate();

    int64_t pair_updates = 0;
    for (int64_t i = 0; i < cell_count; i++) {
        const Array neighbors = to_topology_row(topology[i]);
        for (int64_t n = 0; n < neighbors.size(); n++) {
            const int64_t j = as_index(neighbors[n], -1);
            if (j <= i || j < 0 || j >= cell_count) {
                continue;
            }

            const double mass_i = std::max(1.0e-6, clamped(mass_updated[i], 0.0, 1.0e9, 0.0));
            const double mass_j = std::max(1.0e-6, clamped(mass_updated[j], 0.0, 1.0e9, 0.0));
            const double velocity_i = clamped(velocity_updated[i], -1.0e6, 1.0e6, 0.0);
            const double velocity_j = clamped(velocity_updated[j], -1.0e6, 1.0e6, 0.0);
            const double pressure_i = clamped(pressure_updated[i], -1.0e9, 1.0e9, 0.0);
            const double pressure_j = clamped(pressure_updated[j], -1.0e9, 1.0e9, 0.0);
            const double temperature_i = clamped(temperature_updated[i], 0.0, 2.0e4, 0.0);
            const double temperature_j = clamped(temperature_updated[j], 0.0, 2.0e4, 0.0);

            const double impulse = mechanics_rate * (velocity_j - velocity_i) * delta_seconds;
            const double velocity_delta_i = impulse / mass_i;
            const double velocity_delta_j = -impulse / mass_j;
            velocity_updated[i] = clamped(as_number(velocity_updated[i], 0.0) + velocity_delta_i, -1.0e6, 1.0e6, 0.0);
            velocity_updated[j] = clamped(as_number(velocity_updated[j], 0.0) + velocity_delta_j, -1.0e6, 1.0e6, 0.0);

            const double pressure_flux = pressure_diffusivity * (pressure_j - pressure_i) * delta_seconds;
            pressure_updated[i] = as_number(pressure_updated[i], 0.0) + pressure_flux;
            pressure_updated[j] = as_number(pressure_updated[j], 0.0) - pressure_flux;

            const double thermal_flux = thermal_diffusivity * (temperature_j - temperature_i) * delta_seconds;
            temperature_updated[i] = std::max(0.0, as_number(temperature_updated[i], 0.0) + thermal_flux);
            temperature_updated[j] = std::max(0.0, as_number(temperature_updated[j], 0.0) - thermal_flux);

            const double desired_transfer = mass_transfer_coeff * (pressure_j - pressure_i) * delta_seconds;
            const double max_from_i = std::max(0.0, as_number(mass_updated[i], 0.0) - 1.0e-6);
            const double max_from_j = std::max(0.0, as_number(mass_updated[j], 0.0) - 1.0e-6);
            double transfer_to_i = desired_transfer;
            if (transfer_to_i > 0.0) {
                transfer_to_i = std::min(transfer_to_i, max_from_j);
            } else {
                transfer_to_i = std::max(transfer_to_i, -max_from_i);
            }

            mass_updated[i] = std::max(1.0e-6, as_number(mass_updated[i], 0.0) + transfer_to_i);
            mass_updated[j] = std::max(1.0e-6, as_number(mass_updated[j], 0.0) - transfer_to_i);
            density_updated[i] = std::max(1.0e-6, as_number(density_updated[i], 0.0) + transfer_to_i);
            density_updated[j] = std::max(1.0e-6, as_number(density_updated[j], 0.0) - transfer_to_i);

            pair_updates += 1;
        }
    }

    apply_surface_group_smoothing(
        velocity_updated,
        pressure_updated,
        density_updated,
        topology,
        surface_grouping_blend,
        surface_density_scale);

    const double mass_before = sum_array(mass);
    const double mass_after = sum_array(mass_updated);
    const double energy_before = proxy_energy_total(mass, velocity, pressure, temperature);
    const double energy_after = proxy_energy_total(mass_updated, velocity_updated, pressure_updated, temperature_updated);
    const double mass_drift_proxy = clamped(mass_after - mass_before, -1.0e18, 1.0e18, 0.0);
    const double energy_drift_proxy = clamped(energy_after - energy_before, -1.0e18, 1.0e18, 0.0);

    Dictionary result = unified_pipeline::make_dictionary(
        "enabled", true,
        "mode", mode,
        "cell_count_updated", cell_count,
        "pair_updates", pair_updates,
        "mechanics_exchange_rate", mechanics_rate,
        "pressure_diffusivity", pressure_diffusivity,
        "thermal_diffusivity", thermal_diffusivity,
        "mass_transfer_coeff", mass_transfer_coeff,
        "mass_drift_proxy", mass_drift_proxy,
        "energy_drift_proxy", energy_drift_proxy);
    result["updated_fields"] = unified_pipeline::make_dictionary(
        "mass", mass_updated,
        "density", density_updated,
        "pressure", pressure_updated,
        "temperature", temperature_updated,
        "velocity", velocity_updated,
        "neighbor_topology", topology);
    result["stage_coupling"] = wave_a_stage_coupling(pressure_to_mechanics_scalar, reaction_to_thermal_scalar, damage_to_voxel_scalar);
    result["coupling_markers"] = wave_a_coupling_markers();
    result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(
        pressure_to_mechanics_scalar,
        reaction_to_thermal_scalar,
        damage_to_voxel_scalar,
        mechanics_rate,
        pressure_diffusivity,
        thermal_diffusivity,
        mass_transfer_coeff);
    result["handle_resolution_diagnostics"] = field_handle_resolution_diagnostics;

    if (mode == "cell") {
        const Array source_cells = field_buffers.get("cells", frame_inputs.get("cells", Array()));
        Array updated_cells;
        updated_cells.resize(cell_count);
        for (int64_t i = 0; i < cell_count; i++) {
            Dictionary cell;
            if (i < source_cells.size() && source_cells[i].get_type() == Variant::DICTIONARY) {
                cell = Dictionary(source_cells[i]).duplicate(true);
            }
            cell["mass"] = mass_updated[i];
            cell["density"] = density_updated[i];
            cell["pressure"] = pressure_updated[i];
            cell["temperature"] = temperature_updated[i];
            cell["velocity"] = velocity_updated[i];
            cell["neighbors"] = to_topology_row(topology[i]);
            updated_cells[i] = cell;
        }
        result["updated_cells"] = updated_cells;
    }

    return result;
}

} // namespace local_agents::simulation::unified_pipeline
