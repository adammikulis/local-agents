#include "helpers/SimulationCoreDictionaryHelpers.hpp"

#include <cmath>
#include <set>

using namespace godot;

namespace local_agents::simulation::helpers {
namespace {

double get_numeric_dictionary_value(const Dictionary &row, const StringName &key) {
    if (!row.has(key)) {
        return 0.0;
    }
    const Variant value = row[key];
    switch (value.get_type()) {
        case Variant::INT:
            return static_cast<double>(static_cast<int64_t>(value));
        case Variant::FLOAT:
            return static_cast<double>(value);
        default:
            return 0.0;
    }
}

double contact_impulse_from_row(const Dictionary &row) {
    const double contact_impulse = get_numeric_dictionary_value(row, StringName("contact_impulse"));
    if (contact_impulse != 0.0) {
        return contact_impulse;
    }
    return get_numeric_dictionary_value(row, StringName("impulse"));
}

} // namespace

bool extract_reference_from_dictionary(const Dictionary &payload, String &out_ref) {
    if (payload.has("schema_row")) {
        const Variant schema_variant = payload.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
            if (extract_reference_from_dictionary(schema, out_ref)) {
                return true;
            }
        }
    }
    if (payload.has("handle_id")) {
        out_ref = String(payload.get("handle_id", String()));
        return true;
    }
    if (payload.has("field_name")) {
        out_ref = String(payload.get("field_name", String()));
        return true;
    }
    if (payload.has("name")) {
        out_ref = String(payload.get("name", String()));
        return true;
    }
    if (payload.has("id")) {
        out_ref = String(payload.get("id", String()));
        return true;
    }
    if (payload.has("handle")) {
        const Variant handle_candidate = payload.get("handle", String());
        if (handle_candidate.get_type() == Variant::STRING || handle_candidate.get_type() == Variant::STRING_NAME) {
            out_ref = String(handle_candidate);
            return true;
        }
    }
    return false;
}

Dictionary normalize_contact_row(const Variant &raw_row) {
    Dictionary normalized;
    if (raw_row.get_type() != Variant::DICTIONARY) {
        return normalized;
    }

    const Dictionary source = raw_row;
    normalized["body_a"] = source.get("body_a", StringName());
    normalized["body_b"] = source.get("body_b", StringName());
    normalized["shape_a"] = static_cast<int64_t>(source.get("shape_a", static_cast<int64_t>(-1)));
    normalized["shape_b"] = static_cast<int64_t>(source.get("shape_b", static_cast<int64_t>(-1)));
    const double normalized_impulse = contact_impulse_from_row(source);
    normalized["contact_impulse"] = normalized_impulse;
    normalized["impulse"] = normalized_impulse;
    const double body_velocity = get_numeric_dictionary_value(source, StringName("body_velocity"));
    const double obstacle_velocity = get_numeric_dictionary_value(source, StringName("obstacle_velocity"));
    const double row_velocity = std::fabs(get_numeric_dictionary_value(source, StringName("contact_velocity")));
    const double legacy_relative_speed = std::fabs(get_numeric_dictionary_value(source, StringName("relative_speed")));
    const double relative_speed = std::fmax(
        0.0,
        std::fmax(std::fmax(row_velocity, legacy_relative_speed), std::fabs(body_velocity - obstacle_velocity))
    );
    normalized["relative_speed"] = relative_speed;
    const Variant contact_point = source.get("contact_point", Dictionary());
    const Variant contact_normal = source.get("contact_normal", source.get("normal", Dictionary()));
    normalized["contact_point"] = contact_point;
    normalized["contact_normal"] = contact_normal;
    normalized["normal"] = contact_normal;
    normalized["frame"] = static_cast<int64_t>(source.get("frame", static_cast<int64_t>(0)));
    normalized["body_mass"] = get_numeric_dictionary_value(source, StringName("body_mass"));
    normalized["collider_mass"] = get_numeric_dictionary_value(source, StringName("collider_mass"));
    return normalized;
}

Array collect_input_field_handles(
    const Dictionary &frame_inputs,
    IFieldRegistry *registry,
    bool &did_inject_handles
) {
    Array field_handles;
    if (registry == nullptr) {
        did_inject_handles = false;
        return field_handles;
    }

    std::set<String> emitted_handles;
    bool injected = false;

    const auto add_handle_from_payload = [&](const Dictionary &handle_payload) {
        const bool ok = static_cast<bool>(handle_payload.get("ok", false));
        if (!ok) {
            return;
        }
        const String handle_id = String(handle_payload.get("handle_id", String()));
        if (handle_id.is_empty() || emitted_handles.count(handle_id) > 0) {
            return;
        }

        emitted_handles.insert(handle_id);
        Dictionary handle_entry = handle_payload.duplicate(true);
        handle_entry.erase("ok");
        if (!handle_entry.has("handle_id")) {
            handle_entry["handle_id"] = handle_id;
        }
        if (!handle_entry.has("id")) {
            handle_entry["id"] = handle_id;
        }
        field_handles.append(handle_entry);
        injected = true;
    };

    const auto resolve_field_reference = [&](const String &candidate_token) {
        if (candidate_token.is_empty()) {
            return;
        }
        const String token = candidate_token.strip_edges();
        const Dictionary resolved = registry->resolve_field_handle(token);
        if (static_cast<bool>(resolved.get("ok", false))) {
            add_handle_from_payload(resolved);
            return;
        }
        const Dictionary created = registry->create_field_handle(token);
        add_handle_from_payload(created);
    };

    if (frame_inputs.has("field_handles")) {
        const Variant explicit_handles_variant = frame_inputs.get("field_handles", Variant());
        if (explicit_handles_variant.get_type() == Variant::ARRAY) {
            const Array explicit_handles = explicit_handles_variant;
            for (int64_t i = 0; i < explicit_handles.size(); i += 1) {
                const Variant explicit_handle = explicit_handles[i];
                if (explicit_handle.get_type() == Variant::STRING || explicit_handle.get_type() == Variant::STRING_NAME) {
                    resolve_field_reference(String(explicit_handle));
                    continue;
                }
                if (explicit_handle.get_type() == Variant::DICTIONARY) {
                    String explicit_reference;
                    if (extract_reference_from_dictionary(explicit_handle, explicit_reference)) {
                        resolve_field_reference(explicit_reference);
                    }
                }
            }
        }
    }

    const Array input_keys = frame_inputs.keys();
    for (int64_t i = 0; i < input_keys.size(); i += 1) {
        const String key = String(input_keys[i]);
        if (key == String("field_handles")) {
            continue;
        }
        const Variant input_value = frame_inputs.get(key, Variant());
        String field_reference;
        if (input_value.get_type() == Variant::STRING || input_value.get_type() == Variant::STRING_NAME) {
            field_reference = String(input_value);
        } else if (input_value.get_type() == Variant::DICTIONARY) {
            if (extract_reference_from_dictionary(input_value, field_reference)) {
                // Intentionally keep empty reference values out.
            }
        }
        if (!field_reference.is_empty()) {
            resolve_field_reference(field_reference);
        }
    }

    did_inject_handles = injected;
    if (!injected) {
        return {};
    }
    return field_handles;
}

Dictionary maybe_inject_field_handles_into_environment_inputs(
    const Dictionary &environment_payload,
    IFieldRegistry *registry
) {
    const Dictionary source_inputs = environment_payload.get("inputs", Dictionary());
    if (source_inputs.is_empty()) {
        return source_inputs;
    }

    bool did_inject_handles = false;
    const Array field_handles = collect_input_field_handles(source_inputs, registry, did_inject_handles);
    if (!did_inject_handles) {
        return source_inputs;
    }

    Dictionary pipeline_inputs = source_inputs.duplicate(true);
    pipeline_inputs["field_handles"] = field_handles;
    return pipeline_inputs;
}

} // namespace local_agents::simulation::helpers
