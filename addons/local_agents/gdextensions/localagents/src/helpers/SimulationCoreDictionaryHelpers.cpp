#include "helpers/SimulationCoreDictionaryHelpers.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

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

double read_nonnegative_contact_velocity(const Variant &raw_value) {
    if (raw_value.get_type() == Variant::VECTOR2) {
        return std::fmax(0.0, static_cast<Vector2>(raw_value).length());
    }
    if (raw_value.get_type() == Variant::VECTOR3) {
        return std::fmax(0.0, static_cast<Vector3>(raw_value).length());
    }
    if (raw_value.get_type() == Variant::ARRAY) {
        const Array values = raw_value;
        const int64_t size = values.size();
        if (size >= 3) {
            const double x = static_cast<double>(values[0]);
            const double y = static_cast<double>(values[1]);
            const double z = static_cast<double>(values[2]);
            return std::fmax(0.0, std::sqrt((x * x) + (y * y) + (z * z)));
        }
        if (size == 2) {
            const double x = static_cast<double>(values[0]);
            const double y = static_cast<double>(values[1]);
            return std::fmax(0.0, std::sqrt((x * x) + (y * y)));
        }
        return 0.0;
    }
    return std::fmax(0.0, static_cast<double>(raw_value));
}

Vector3 read_vector3(const Variant &raw_value) {
    if (raw_value.get_type() == Variant::VECTOR3) {
        return static_cast<Vector3>(raw_value);
    }
    if (raw_value.get_type() == Variant::VECTOR2) {
        const Vector2 vec = static_cast<Vector2>(raw_value);
        return Vector3(vec.x, vec.y, 0.0);
    }
    if (raw_value.get_type() == Variant::ARRAY) {
        const Array values = raw_value;
        if (values.size() >= 3) {
            return Vector3(
                static_cast<double>(values[0]),
                static_cast<double>(values[1]),
                static_cast<double>(values[2]));
        }
        if (values.size() == 2) {
            return Vector3(
                static_cast<double>(values[0]),
                static_cast<double>(values[1]),
                0.0);
        }
        return Vector3();
    }
    if (raw_value.get_type() == Variant::DICTIONARY) {
        const Dictionary row = raw_value;
        return Vector3(
            static_cast<double>(row.get("x", 0.0)),
            static_cast<double>(row.get("y", 0.0)),
            static_cast<double>(row.get("z", 0.0)));
    }
    return Vector3();
}

Vector3 read_vector3_from_keys(const Dictionary &source, const std::vector<StringName> &keys) {
    for (const StringName &key : keys) {
        if (!source.has(key)) {
            continue;
        }
        return read_vector3(source[key]);
    }
    return Vector3();
}

double read_weighted_contact_impulse(const Dictionary &row) {
    return std::fmax(0.0, static_cast<double>(row.get("contact_impulse", 0.0)));
}

void collect_nested_dictionaries(
    const Dictionary &source,
    Array &out,
    int depth
) {
    if (depth > 3) {
        return;
    }
    out.append(source);
    static const std::vector<StringName> keys = {
        StringName("voxel_failure_emission"),
        StringName("result_fields"),
        StringName("result"),
        StringName("payload"),
        StringName("execution"),
        StringName("voxel_result"),
        StringName("source"),
        StringName("authoritative_mutation"),
        StringName("authoritative_voxel_execution")
    };
    for (const StringName &key : keys) {
        const Variant nested_variant = source.get(key, Dictionary());
        if (nested_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        collect_nested_dictionaries(Dictionary(nested_variant), out, depth + 1);
    }
}

void collect_native_ops_recursive(const Dictionary &source, Array &out, int depth) {
    if (depth > 3) {
        return;
    }
    static const std::vector<StringName> op_keys = {
        StringName("native_ops"),
        StringName("op_payloads"),
        StringName("operations"),
        StringName("voxel_ops")
    };
    for (const StringName &key : op_keys) {
        const Variant rows_variant = source.get(key, Array());
        if (rows_variant.get_type() != Variant::ARRAY) {
            continue;
        }
        const Array rows = rows_variant;
        for (int64_t i = 0; i < rows.size(); i += 1) {
            const Variant row_variant = rows[i];
            if (row_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            out.append(Dictionary(row_variant).duplicate(true));
        }
    }
    static const std::vector<StringName> nested_keys = {
        StringName("voxel_failure_emission"),
        StringName("result_fields"),
        StringName("result"),
        StringName("payload"),
        StringName("execution"),
        StringName("voxel_result"),
        StringName("source"),
        StringName("authoritative_mutation"),
        StringName("authoritative_voxel_execution")
    };
    for (const StringName &key : nested_keys) {
        const Variant nested_variant = source.get(key, Dictionary());
        if (nested_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        collect_native_ops_recursive(Dictionary(nested_variant), out, depth + 1);
    }
}

void collect_changed_chunk_rows_recursive(const Dictionary &source, Array &out, int depth) {
    if (depth > 3) {
        return;
    }
    const Variant rows_variant = source.get("changed_chunks", Array());
    if (rows_variant.get_type() == Variant::ARRAY) {
        const Array rows = rows_variant;
        for (int64_t i = 0; i < rows.size(); i += 1) {
            const Variant row_variant = rows[i];
            if (row_variant.get_type() == Variant::DICTIONARY || row_variant.get_type() == Variant::STRING) {
                out.append(row_variant);
            }
        }
    }
    static const std::vector<StringName> nested_keys = {
        StringName("voxel_failure_emission"),
        StringName("result_fields"),
        StringName("result"),
        StringName("payload"),
        StringName("execution"),
        StringName("voxel_result"),
        StringName("source"),
        StringName("authoritative_mutation"),
        StringName("authoritative_voxel_execution")
    };
    for (const StringName &key : nested_keys) {
        const Variant nested_variant = source.get(key, Dictionary());
        if (nested_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        collect_changed_chunk_rows_recursive(Dictionary(nested_variant), out, depth + 1);
    }
}

Dictionary find_changed_region_recursive(const Dictionary &source, int depth) {
    if (depth > 3) {
        return Dictionary();
    }
    const Variant region_variant = source.get("changed_region", Dictionary());
    if (region_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary region = region_variant;
        if (static_cast<bool>(region.get("valid", false))) {
            return region.duplicate(true);
        }
    }
    static const std::vector<StringName> nested_keys = {
        StringName("voxel_failure_emission"),
        StringName("result_fields"),
        StringName("result"),
        StringName("payload"),
        StringName("execution"),
        StringName("voxel_result"),
        StringName("source"),
        StringName("authoritative_mutation"),
        StringName("authoritative_voxel_execution")
    };
    for (const StringName &key : nested_keys) {
        const Variant nested_variant = source.get(key, Dictionary());
        if (nested_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary nested_region = find_changed_region_recursive(Dictionary(nested_variant), depth + 1);
        if (!nested_region.is_empty()) {
            return nested_region;
        }
    }
    return Dictionary();
}

Array normalize_changed_chunks(const Array &rows) {
    struct Chunk {
        int64_t x = 0;
        int64_t y = 0;
        int64_t z = 0;
    };

    std::set<std::tuple<int64_t, int64_t, int64_t>> seen;
    std::vector<Chunk> normalized;
    normalized.reserve(static_cast<size_t>(rows.size()));

    for (int64_t i = 0; i < rows.size(); i += 1) {
        const Variant row_variant = rows[i];
        Chunk chunk;
        bool valid = false;
        if (row_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary row = row_variant;
            chunk.x = static_cast<int64_t>(row.get("x", static_cast<int64_t>(0)));
            chunk.y = static_cast<int64_t>(row.get("y", static_cast<int64_t>(0)));
            chunk.z = static_cast<int64_t>(row.get("z", row.get("y", static_cast<int64_t>(0))));
            valid = true;
        } else if (row_variant.get_type() == Variant::STRING || row_variant.get_type() == Variant::STRING_NAME) {
            const String key = String(row_variant).strip_edges();
            if (key.is_empty()) {
                continue;
            }
            const PackedStringArray parts = key.split(":");
            if (parts.size() != 2) {
                continue;
            }
            chunk.x = static_cast<int64_t>(parts[0].to_int());
            chunk.y = 0;
            chunk.z = static_cast<int64_t>(parts[1].to_int());
            valid = true;
        }
        if (!valid) {
            continue;
        }
        const auto marker = std::make_tuple(chunk.x, chunk.y, chunk.z);
        if (seen.find(marker) != seen.end()) {
            continue;
        }
        seen.insert(marker);
        normalized.push_back(chunk);
    }

    std::sort(
        normalized.begin(),
        normalized.end(),
        [](const Chunk &left, const Chunk &right) {
            if (left.x != right.x) {
                return left.x < right.x;
            }
            if (left.y != right.y) {
                return left.y < right.y;
            }
            return left.z < right.z;
        });

    Array out;
    for (const Chunk &chunk : normalized) {
        Dictionary row;
        row["x"] = chunk.x;
        row["y"] = chunk.y;
        row["z"] = chunk.z;
        out.append(row);
    }
    return out;
}

void merge_authority_fields(Dictionary &target, const Dictionary &source) {
    if (source.has("ops_changed")) {
        target["ops_changed"] = std::max(static_cast<int64_t>(0), static_cast<int64_t>(source.get("ops_changed", static_cast<int64_t>(0))));
    }
    if (source.has("changed")) {
        target["changed"] = static_cast<bool>(source.get("changed", false));
    } else if (source.has("voxel_changed") && !target.has("changed")) {
        target["changed"] = static_cast<bool>(source.get("voxel_changed", false));
    }
    if (source.has("changed_chunks")) {
        const Variant changed_chunks_variant = source.get("changed_chunks", Array());
        if (changed_chunks_variant.get_type() == Variant::ARRAY) {
            target["changed_chunks"] = normalize_changed_chunks(changed_chunks_variant);
        }
    }
    if (source.has("changed_region")) {
        const Variant changed_region_variant = source.get("changed_region", Dictionary());
        if (changed_region_variant.get_type() == Variant::DICTIONARY) {
            target["changed_region"] = Dictionary(changed_region_variant).duplicate(true);
        }
    }
}

bool authority_reports_changed(const Dictionary &authority, const Array &changed_chunks, const Dictionary &changed_region) {
    if (authority.has("changed")) {
        return static_cast<bool>(authority.get("changed", false));
    }
    if (authority.has("ops_changed")) {
        return static_cast<int64_t>(authority.get("ops_changed", static_cast<int64_t>(0))) > 0;
    }
    if (authority.has("changed_chunks")) {
        const Variant changed_chunks_variant = authority.get("changed_chunks", Array());
        if (changed_chunks_variant.get_type() == Variant::ARRAY && Array(changed_chunks_variant).size() > 0) {
            return true;
        }
    }
    if (authority.has("changed_region")) {
        const Variant changed_region_variant = authority.get("changed_region", Dictionary());
        if (changed_region_variant.get_type() == Variant::DICTIONARY &&
            static_cast<bool>(Dictionary(changed_region_variant).get("valid", false))) {
            return true;
        }
    }
    if (!changed_chunks.is_empty()) {
        return true;
    }
    return static_cast<bool>(changed_region.get("valid", false));
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
    normalized["contact_velocity"] = read_nonnegative_contact_velocity(source.get("contact_velocity", relative_speed));
    normalized["body_velocity"] = read_nonnegative_contact_velocity(
        source.get("body_velocity", source.get("linear_velocity", source.get("velocity", 0.0))));
    normalized["obstacle_velocity"] = read_nonnegative_contact_velocity(
        source.get("obstacle_velocity", source.get("motion_speed", 0.0)));
    normalized["obstacle_trajectory"] = read_vector3_from_keys(
        source,
        {StringName("obstacle_trajectory"), StringName("motion_trajectory"), StringName("trajectory")});
    normalized["body_id"] = static_cast<int64_t>(source.get("body_id", source.get("id", source.get("rid", static_cast<int64_t>(-1)))));
    normalized["rigid_obstacle_mask"] = std::max(
        static_cast<int64_t>(0),
        static_cast<int64_t>(source.get(
            "rigid_obstacle_mask",
            source.get("obstacle_mask", source.get("collision_mask", source.get("collision_layer", static_cast<int64_t>(0)))))));

    const std::vector<StringName> preserved_projectile_fields = {
        StringName("projectile_kind"),
        StringName("projectile_density_tag"),
        StringName("projectile_hardness_tag"),
        StringName("projectile_material_tag"),
        StringName("failure_emission_profile"),
        StringName("projectile_radius"),
        StringName("projectile_ttl"),
        StringName("projectile_id"),
        StringName("hit_frame"),
        StringName("deadline_frame"),
        StringName("collider_id"),
        StringName("contact_index"),
        StringName("impact_mode"),
    };
    for (const StringName &preserved_key : preserved_projectile_fields) {
        if (source.has(preserved_key)) {
            normalized[preserved_key] = source[preserved_key];
        }
    }
    return normalized;
}

Array normalize_contact_rows(const Array &contact_rows) {
    Array normalized_rows;
    for (int64_t i = 0; i < contact_rows.size(); i += 1) {
        const Dictionary normalized = normalize_contact_row(contact_rows[i]);
        if (normalized.is_empty()) {
            continue;
        }
        normalized_rows.append(normalized);
    }
    return normalized_rows;
}

Dictionary aggregate_contact_rows(const Array &normalized_contact_rows) {
    Dictionary aggregate;
    if (normalized_contact_rows.is_empty()) {
        return aggregate;
    }

    std::vector<Dictionary> deterministic_rows;
    deterministic_rows.reserve(static_cast<size_t>(normalized_contact_rows.size()));
    for (int64_t i = 0; i < normalized_contact_rows.size(); i += 1) {
        const Variant row_variant = normalized_contact_rows[i];
        if (row_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        deterministic_rows.push_back(Dictionary(row_variant));
    }
    std::sort(
        deterministic_rows.begin(),
        deterministic_rows.end(),
        [](const Dictionary &left, const Dictionary &right) {
            const int64_t left_body = static_cast<int64_t>(left.get("body_id", static_cast<int64_t>(0)));
            const int64_t right_body = static_cast<int64_t>(right.get("body_id", static_cast<int64_t>(0)));
            if (left_body != right_body) {
                return left_body < right_body;
            }
            const int64_t left_mask = static_cast<int64_t>(left.get("rigid_obstacle_mask", static_cast<int64_t>(0)));
            const int64_t right_mask = static_cast<int64_t>(right.get("rigid_obstacle_mask", static_cast<int64_t>(0)));
            if (left_mask != right_mask) {
                return left_mask < right_mask;
            }
            const double left_impulse = static_cast<double>(left.get("contact_impulse", 0.0));
            const double right_impulse = static_cast<double>(right.get("contact_impulse", 0.0));
            if (left_impulse != right_impulse) {
                return left_impulse < right_impulse;
            }
            const double left_velocity = static_cast<double>(left.get("body_velocity", 0.0));
            const double right_velocity = static_cast<double>(right.get("body_velocity", 0.0));
            if (left_velocity != right_velocity) {
                return left_velocity < right_velocity;
            }
            const double left_obstacle_velocity = static_cast<double>(left.get("obstacle_velocity", 0.0));
            const double right_obstacle_velocity = static_cast<double>(right.get("obstacle_velocity", 0.0));
            if (left_obstacle_velocity != right_obstacle_velocity) {
                return left_obstacle_velocity < right_obstacle_velocity;
            }
            const Vector3 left_trajectory = read_vector3(left.get("obstacle_trajectory", Vector3()));
            const Vector3 right_trajectory = read_vector3(right.get("obstacle_trajectory", Vector3()));
            if (left_trajectory.x != right_trajectory.x) {
                return left_trajectory.x < right_trajectory.x;
            }
            if (left_trajectory.y != right_trajectory.y) {
                return left_trajectory.y < right_trajectory.y;
            }
            if (left_trajectory.z != right_trajectory.z) {
                return left_trajectory.z < right_trajectory.z;
            }
            const Vector3 left_normal = read_vector3(left.get("contact_normal", Vector3()));
            const Vector3 right_normal = read_vector3(right.get("contact_normal", Vector3()));
            if (left_normal.x != right_normal.x) {
                return left_normal.x < right_normal.x;
            }
            if (left_normal.y != right_normal.y) {
                return left_normal.y < right_normal.y;
            }
            if (left_normal.z != right_normal.z) {
                return left_normal.z < right_normal.z;
            }
            const Vector3 left_point = read_vector3(left.get("contact_point", Vector3()));
            const Vector3 right_point = read_vector3(right.get("contact_point", Vector3()));
            if (left_point.x != right_point.x) {
                return left_point.x < right_point.x;
            }
            if (left_point.y != right_point.y) {
                return left_point.y < right_point.y;
            }
            return left_point.z < right_point.z;
        });

    double total_impulse = 0.0;
    Vector3 normal_sum;
    double contact_velocity_sum = 0.0;
    Vector3 point_sum;
    double velocity_sum = 0.0;
    double obstacle_velocity_sum = 0.0;
    Vector3 obstacle_trajectory_sum;
    double body_mass_sum = 0.0;
    double collider_mass_sum = 0.0;
    double strongest_impulse = -1.0;
    int64_t strongest_body_id = -1;
    int64_t strongest_mask = 0;

    for (const Dictionary &row : deterministic_rows) {
        const double impulse = read_weighted_contact_impulse(row);
        const double weight = impulse > 0.0 ? impulse : 1.0;
        total_impulse += impulse;
        normal_sum += read_vector3(row.get("contact_normal", Vector3())) * weight;
        point_sum += read_vector3(row.get("contact_point", Vector3())) * weight;
        velocity_sum += std::fmax(0.0, static_cast<double>(row.get("body_velocity", 0.0))) * weight;
        obstacle_velocity_sum += std::fmax(0.0, static_cast<double>(row.get("obstacle_velocity", 0.0))) * weight;
        obstacle_trajectory_sum += read_vector3(row.get("obstacle_trajectory", Vector3())) * weight;
        contact_velocity_sum += std::fmax(0.0, static_cast<double>(row.get("contact_velocity", 0.0))) * weight;
        body_mass_sum += std::fmax(0.0, static_cast<double>(row.get("body_mass", 0.0))) * weight;
        collider_mass_sum += std::fmax(0.0, static_cast<double>(row.get("collider_mass", 0.0))) * weight;
        if (impulse > strongest_impulse) {
            strongest_impulse = impulse;
            strongest_body_id = static_cast<int64_t>(row.get("body_id", static_cast<int64_t>(-1)));
            strongest_mask = std::max(static_cast<int64_t>(0), static_cast<int64_t>(row.get("rigid_obstacle_mask", static_cast<int64_t>(0))));
        }
    }

    const double weight_total = total_impulse > 0.0 ? total_impulse : static_cast<double>(deterministic_rows.size());
    Vector3 average_normal = normal_sum / std::fmax(weight_total, 1.0);
    if (average_normal.length_squared() > 0.0) {
        average_normal = average_normal.normalized();
    }

    aggregate["contact_impulse"] = total_impulse;
    aggregate["contact_velocity"] = contact_velocity_sum / std::fmax(weight_total, 1.0);
    aggregate["contact_normal"] = average_normal;
    aggregate["contact_point"] = point_sum / std::fmax(weight_total, 1.0);
    aggregate["body_velocity"] = velocity_sum / std::fmax(weight_total, 1.0);
    aggregate["obstacle_velocity"] = obstacle_velocity_sum / std::fmax(weight_total, 1.0);
    aggregate["body_mass"] = body_mass_sum / std::fmax(weight_total, 1.0);
    aggregate["collider_mass"] = collider_mass_sum / std::fmax(weight_total, 1.0);
    aggregate["obstacle_trajectory"] = obstacle_trajectory_sum / std::fmax(weight_total, 1.0);
    aggregate["body_id"] = strongest_body_id;
    aggregate["rigid_obstacle_mask"] = strongest_mask;
    return aggregate;
}

Dictionary normalize_and_aggregate_contact_rows(const Array &contact_rows) {
    const Array normalized_rows = normalize_contact_rows(contact_rows);
    Dictionary result;
    result["normalized_rows"] = normalized_rows;
    result["aggregated_inputs"] = aggregate_contact_rows(normalized_rows);
    result["row_count"] = normalized_rows.size();
    return result;
}

Dictionary build_canonical_voxel_dispatch_contract(const Dictionary &dispatch_payload) {
    Dictionary contract;
    const Array dictionaries = [&dispatch_payload]() {
        Array rows;
        collect_nested_dictionaries(dispatch_payload, rows, 0);
        return rows;
    }();

    Array native_ops;
    collect_native_ops_recursive(dispatch_payload, native_ops, 0);
    contract["native_ops"] = native_ops;

    Array changed_chunk_rows;
    collect_changed_chunk_rows_recursive(dispatch_payload, changed_chunk_rows, 0);
    const Array normalized_changed_chunks = normalize_changed_chunks(changed_chunk_rows);
    contract["changed_chunks"] = normalized_changed_chunks;

    const Dictionary changed_region = find_changed_region_recursive(dispatch_payload, 0);
    if (!changed_region.is_empty()) {
        contract["changed_region"] = changed_region.duplicate(true);
    }

    Dictionary native_authority;
    const Variant explicit_authority_variant = dispatch_payload.get("native_mutation_authority", Dictionary());
    if (explicit_authority_variant.get_type() == Variant::DICTIONARY) {
        native_authority = Dictionary(explicit_authority_variant).duplicate(true);
    }
    if (native_authority.is_empty()) {
        for (int64_t i = 0; i < dictionaries.size(); i += 1) {
            const Variant dictionary_variant = dictionaries[i];
            if (dictionary_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            merge_authority_fields(native_authority, Dictionary(dictionary_variant));
        }
    }
    if (!native_authority.has("changed_chunks")) {
        native_authority["changed_chunks"] = normalized_changed_chunks.duplicate(true);
    }
    if (!native_authority.has("changed_region") && !changed_region.is_empty()) {
        native_authority["changed_region"] = changed_region.duplicate(true);
    }
    native_authority["changed"] = authority_reports_changed(native_authority, normalized_changed_chunks, changed_region);
    contract["native_mutation_authority"] = native_authority;
    return contract;
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
