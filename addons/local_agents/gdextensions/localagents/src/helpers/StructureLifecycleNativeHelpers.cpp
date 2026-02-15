#include "helpers/StructureLifecycleNativeHelpers.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

using namespace godot;

namespace local_agents::simulation::helpers {
namespace {

struct StructureLifecycleConfig {
    double crowding_members_per_hut_threshold = 3.2;
    double throughput_expand_threshold = 0.95;
    int64_t expand_cooldown_ticks = 24;
    double low_throughput_abandon_threshold = 0.35;
    double low_path_strength_abandon_threshold = 0.18;
    int64_t abandon_sustain_ticks = 72;
    int64_t min_huts_per_household = 1;
    int64_t max_huts_per_household = 8;
    double hut_ring_step = 1.8;
    double hut_start_radius = 2.3;
    double depletion_signal_threshold = 0.62;
    int64_t depletion_sustain_ticks = 24;
    int64_t path_extension_trigger_ticks = 16;
    int64_t camp_spawn_cooldown_ticks = 48;
    int64_t max_temporary_camps_per_household = 2;
    double camp_ring_multiplier = 1.8;
};

double read_float_variant(const Variant &value, double fallback) {
    switch (value.get_type()) {
        case Variant::INT:
            return static_cast<double>(static_cast<int64_t>(value));
        case Variant::FLOAT:
            return static_cast<double>(value);
        case Variant::BOOL:
            return static_cast<bool>(value) ? 1.0 : 0.0;
        default:
            return fallback;
    }
}

int64_t read_int_variant(const Variant &value, int64_t fallback) {
    switch (value.get_type()) {
        case Variant::INT:
            return static_cast<int64_t>(value);
        case Variant::FLOAT:
            return static_cast<int64_t>(static_cast<double>(value));
        case Variant::BOOL:
            return static_cast<bool>(value) ? 1 : 0;
        default:
            return fallback;
    }
}

bool read_bool_variant(const Variant &value, bool fallback) {
    switch (value.get_type()) {
        case Variant::BOOL:
            return static_cast<bool>(value);
        case Variant::INT:
            return static_cast<int64_t>(value) != 0;
        case Variant::FLOAT:
            return static_cast<double>(value) != 0.0;
        default:
            return fallback;
    }
}

String read_string_variant(const Variant &value, const String &fallback = String()) {
    if (value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME) {
        return String(value).strip_edges();
    }
    return fallback;
}

double clampf_native(double value, double min_value, double max_value) {
    return std::min(std::max(value, min_value), max_value);
}

Dictionary as_dictionary(const Variant &value) {
    if (value.get_type() == Variant::DICTIONARY) {
        return Dictionary(value);
    }
    return Dictionary();
}

Array as_array(const Variant &value) {
    if (value.get_type() == Variant::ARRAY) {
        return Array(value);
    }
    return Array();
}

Dictionary vector3_to_dictionary(const Vector3 &position) {
    Dictionary row;
    row["x"] = position.x;
    row["y"] = position.y;
    row["z"] = position.z;
    return row;
}

double snapped(double value, double step) {
    if (step <= 0.0) {
        return value;
    }
    return std::round(value / step) * step;
}

StructureLifecycleConfig read_structure_lifecycle_config(const Dictionary &payload) {
    StructureLifecycleConfig config;
    if (payload.has("crowding_members_per_hut_threshold")) {
        config.crowding_members_per_hut_threshold = read_float_variant(
            payload.get("crowding_members_per_hut_threshold", config.crowding_members_per_hut_threshold),
            config.crowding_members_per_hut_threshold
        );
    }
    if (payload.has("throughput_expand_threshold")) {
        config.throughput_expand_threshold = read_float_variant(
            payload.get("throughput_expand_threshold", config.throughput_expand_threshold),
            config.throughput_expand_threshold
        );
    }
    if (payload.has("expand_cooldown_ticks")) {
        config.expand_cooldown_ticks = read_int_variant(payload.get("expand_cooldown_ticks", config.expand_cooldown_ticks), config.expand_cooldown_ticks);
    }
    if (payload.has("low_throughput_abandon_threshold")) {
        config.low_throughput_abandon_threshold = read_float_variant(
            payload.get("low_throughput_abandon_threshold", config.low_throughput_abandon_threshold),
            config.low_throughput_abandon_threshold
        );
    }
    if (payload.has("low_path_strength_abandon_threshold")) {
        config.low_path_strength_abandon_threshold = read_float_variant(
            payload.get("low_path_strength_abandon_threshold", config.low_path_strength_abandon_threshold),
            config.low_path_strength_abandon_threshold
        );
    }
    if (payload.has("abandon_sustain_ticks")) {
        config.abandon_sustain_ticks = read_int_variant(payload.get("abandon_sustain_ticks", config.abandon_sustain_ticks), config.abandon_sustain_ticks);
    }
    if (payload.has("min_huts_per_household")) {
        config.min_huts_per_household = read_int_variant(payload.get("min_huts_per_household", config.min_huts_per_household), config.min_huts_per_household);
    }
    if (payload.has("max_huts_per_household")) {
        config.max_huts_per_household = read_int_variant(payload.get("max_huts_per_household", config.max_huts_per_household), config.max_huts_per_household);
    }
    if (payload.has("hut_ring_step")) {
        config.hut_ring_step = read_float_variant(payload.get("hut_ring_step", config.hut_ring_step), config.hut_ring_step);
    }
    if (payload.has("hut_start_radius")) {
        config.hut_start_radius = read_float_variant(payload.get("hut_start_radius", config.hut_start_radius), config.hut_start_radius);
    }
    if (payload.has("depletion_signal_threshold")) {
        config.depletion_signal_threshold = read_float_variant(
            payload.get("depletion_signal_threshold", config.depletion_signal_threshold),
            config.depletion_signal_threshold
        );
    }
    if (payload.has("depletion_sustain_ticks")) {
        config.depletion_sustain_ticks = read_int_variant(payload.get("depletion_sustain_ticks", config.depletion_sustain_ticks), config.depletion_sustain_ticks);
    }
    if (payload.has("path_extension_trigger_ticks")) {
        config.path_extension_trigger_ticks = read_int_variant(
            payload.get("path_extension_trigger_ticks", config.path_extension_trigger_ticks),
            config.path_extension_trigger_ticks
        );
    }
    if (payload.has("camp_spawn_cooldown_ticks")) {
        config.camp_spawn_cooldown_ticks = read_int_variant(
            payload.get("camp_spawn_cooldown_ticks", config.camp_spawn_cooldown_ticks),
            config.camp_spawn_cooldown_ticks
        );
    }
    if (payload.has("max_temporary_camps_per_household")) {
        config.max_temporary_camps_per_household = read_int_variant(
            payload.get("max_temporary_camps_per_household", config.max_temporary_camps_per_household),
            config.max_temporary_camps_per_household
        );
    }
    if (payload.has("camp_ring_multiplier")) {
        config.camp_ring_multiplier = read_float_variant(
            payload.get("camp_ring_multiplier", config.camp_ring_multiplier),
            config.camp_ring_multiplier
        );
    }
    return config;
}

Array sorted_household_ids_from_members(const Dictionary &household_members) {
    const Array keys = household_members.keys();
    std::vector<String> ids;
    ids.reserve(static_cast<size_t>(keys.size()));
    for (int64_t i = 0; i < keys.size(); i++) {
        ids.push_back(String(keys[i]).strip_edges());
    }
    std::sort(ids.begin(), ids.end(), [](const String &a, const String &b) { return a < b; });
    Array out;
    for (const String &id : ids) {
        out.append(id);
    }
    return out;
}

Array get_household_rows(const Dictionary &structures_by_household, const String &household_id) {
    if (!structures_by_household.has(household_id)) {
        return Array();
    }
    return as_array(structures_by_household[household_id]);
}

int64_t active_structure_count_for_type(
    const Dictionary &structures_by_household,
    const String &household_id,
    const String &structure_type
) {
    const Array rows = get_household_rows(structures_by_household, household_id);
    int64_t count = 0;
    for (int64_t i = 0; i < rows.size(); i++) {
        const Dictionary row = as_dictionary(rows[i]);
        if (row.is_empty()) {
            continue;
        }
        if (read_string_variant(row.get("structure_type", String())) != structure_type) {
            continue;
        }
        if (read_string_variant(row.get("state", String())) == String("active")) {
            count += 1;
        }
    }
    return count;
}

double flood_risk(const Vector3 &world_position, const Dictionary &water_snapshot) {
    const Dictionary water_tiles = as_dictionary(water_snapshot.get("water_tiles", Dictionary()));
    if (water_tiles.is_empty()) {
        return 0.0;
    }
    const int64_t tile_x = static_cast<int64_t>(std::llround(world_position.x));
    const int64_t tile_z = static_cast<int64_t>(std::llround(world_position.z));
    const String tile_id = String::num_int64(tile_x) + ":" + String::num_int64(tile_z);
    const Dictionary row = as_dictionary(water_tiles.get(tile_id, Dictionary()));
    if (row.is_empty()) {
        return 0.0;
    }
    return clampf_native(read_float_variant(row.get("flood_risk", 0.0), 0.0), 0.0, 1.0);
}

Dictionary make_structure_row(
    const String &structure_id,
    const String &structure_type,
    const String &household_id,
    const String &state,
    const Vector3 &position,
    double durability,
    int64_t created_tick,
    int64_t last_updated_tick
) {
    Dictionary row;
    row["schema_version"] = 1;
    row["structure_id"] = structure_id;
    row["structure_type"] = structure_type;
    row["household_id"] = household_id;
    row["state"] = state;
    row["position"] = vector3_to_dictionary(position);
    row["durability"] = durability;
    row["created_tick"] = created_tick;
    row["last_updated_tick"] = last_updated_tick;
    return row;
}

void ensure_household(
    Dictionary &structures_by_household,
    Dictionary &last_expand_tick,
    Dictionary &low_access_ticks,
    Dictionary &depletion_ticks,
    Dictionary &last_camp_tick,
    Dictionary &path_extension_emitted,
    const String &household_id,
    const Vector3 &position,
    int64_t tick
) {
    if (household_id.strip_edges().is_empty()) {
        return;
    }
    const Array existing = get_household_rows(structures_by_household, household_id);
    if (!existing.is_empty()) {
        return;
    }
    Array rows;
    rows.append(make_structure_row(
        String("hut_") + household_id + String("_0"),
        String("hut"),
        household_id,
        String("active"),
        position,
        1.0,
        tick,
        tick));
    structures_by_household[household_id] = rows;
    last_expand_tick[household_id] = tick;
    low_access_ticks[household_id] = 0;
    depletion_ticks[household_id] = 0;
    last_camp_tick[household_id] = -999999;
    path_extension_emitted[household_id] = false;
}

bool should_expand(
    const StructureLifecycleConfig &config,
    const Dictionary &last_expand_tick,
    const String &household_id,
    int64_t tick,
    double crowding,
    double throughput,
    int64_t huts
) {
    if (huts >= config.max_huts_per_household) {
        return false;
    }
    if (crowding < config.crowding_members_per_hut_threshold) {
        return false;
    }
    if (throughput < config.throughput_expand_threshold) {
        return false;
    }
    const int64_t last_tick = read_int_variant(last_expand_tick.get(household_id, -999999), -999999);
    return (tick - last_tick) >= config.expand_cooldown_ticks;
}

String spawn_hut(
    Dictionary &structures_by_household,
    Dictionary &last_expand_tick,
    const StructureLifecycleConfig &config,
    const String &household_id,
    const Variant &base_position_variant,
    int64_t tick,
    const Dictionary &water_snapshot,
    int64_t existing_huts
) {
    Vector3 base_position;
    if (base_position_variant.get_type() == Variant::VECTOR3) {
        base_position = Vector3(base_position_variant);
    }
    const int64_t ring_index = std::max<int64_t>(0, existing_huts);
    const int64_t hash_base = std::llabs(static_cast<int64_t>(household_id.hash()));
    const double angle = static_cast<double>(ring_index) * 1.731 + static_cast<double>(hash_base % 6283) * 0.001;
    const double radius = config.hut_start_radius + static_cast<double>(ring_index) * config.hut_ring_step;
    const Vector3 candidate_a = base_position + Vector3(
        static_cast<float>(std::cos(angle) * radius),
        0.0f,
        static_cast<float>(std::sin(angle) * radius));
    const Vector3 candidate_b = base_position + Vector3(
        static_cast<float>(std::cos(angle + 0.8) * radius),
        0.0f,
        static_cast<float>(std::sin(angle + 0.8) * radius));
    Vector3 best = candidate_a;
    if (flood_risk(candidate_b, water_snapshot) < flood_risk(candidate_a, water_snapshot)) {
        best = candidate_b;
    }

    const String structure_id = String("hut_") + household_id + String("_") + String::num_int64(existing_huts);
    Array rows = get_household_rows(structures_by_household, household_id);
    rows.append(make_structure_row(
        structure_id,
        String("hut"),
        household_id,
        String("active"),
        best,
        1.0,
        tick,
        tick));
    structures_by_household[household_id] = rows;
    last_expand_tick[household_id] = tick;
    return structure_id;
}

double depletion_signal(const StructureLifecycleConfig &config, const Dictionary &metrics, double throughput, double path_strength) {
    const double throughput_ratio = clampf_native(
        throughput / std::max(0.01, config.throughput_expand_threshold),
        0.0,
        1.0
    );
    const double scarcity = 1.0 - throughput_ratio;
    const double route_fragility = 1.0 - path_strength;
    const double partial_pressure = clampf_native(read_float_variant(metrics.get("partial_delivery_ratio", 0.0), 0.0), 0.0, 1.0);
    return clampf_native(scarcity * 0.55 + route_fragility * 0.25 + partial_pressure * 0.2, 0.0, 1.0);
}

int64_t update_depletion_counter(
    const StructureLifecycleConfig &config,
    Dictionary &depletion_ticks,
    const String &household_id,
    double signal
) {
    int64_t next_ticks = 0;
    if (signal >= config.depletion_signal_threshold) {
        next_ticks = read_int_variant(depletion_ticks.get(household_id, 0), 0) + 1;
    } else {
        next_ticks = std::max<int64_t>(0, read_int_variant(depletion_ticks.get(household_id, 0), 0) - 2);
    }
    depletion_ticks[household_id] = next_ticks;
    return next_ticks;
}

bool should_emit_path_extension(
    const StructureLifecycleConfig &config,
    const Dictionary &path_extension_emitted,
    const String &household_id,
    int64_t depletion_ticks
) {
    if (read_bool_variant(path_extension_emitted.get(household_id, false), false)) {
        return false;
    }
    return depletion_ticks >= config.path_extension_trigger_ticks;
}

bool should_spawn_temporary_camp(
    const StructureLifecycleConfig &config,
    const Dictionary &last_camp_tick,
    const Dictionary &structures_by_household,
    const String &household_id,
    int64_t tick,
    int64_t depletion_ticks
) {
    if (depletion_ticks < config.depletion_sustain_ticks) {
        return false;
    }
    const int64_t last = read_int_variant(last_camp_tick.get(household_id, -999999), -999999);
    if ((tick - last) < config.camp_spawn_cooldown_ticks) {
        return false;
    }
    return active_structure_count_for_type(structures_by_household, household_id, String("camp_temp")) <
        config.max_temporary_camps_per_household;
}

Dictionary spawn_temporary_camp(
    Dictionary &structures_by_household,
    const StructureLifecycleConfig &config,
    const String &household_id,
    const Variant &base_position_variant,
    int64_t tick,
    const Dictionary &water_snapshot
) {
    Vector3 base_position;
    if (base_position_variant.get_type() == Variant::VECTOR3) {
        base_position = Vector3(base_position_variant);
    }
    const int64_t camp_index = active_structure_count_for_type(structures_by_household, household_id, String("camp_temp"));
    const int64_t huts = active_structure_count_for_type(structures_by_household, household_id, String("hut"));
    const double ring = config.hut_start_radius +
        static_cast<double>(std::max<int64_t>(1, huts)) * config.hut_ring_step * config.camp_ring_multiplier;
    const String camp_hash_key = household_id + String(":camp");
    const int64_t camp_hash = std::llabs(static_cast<int64_t>(camp_hash_key.hash()));
    const double angle = static_cast<double>(camp_index + huts + 1) * 2.211 + static_cast<double>(camp_hash % 6283) * 0.001;
    const Vector3 candidate_a = base_position + Vector3(
        static_cast<float>(std::cos(angle) * ring),
        0.0f,
        static_cast<float>(std::sin(angle) * ring));
    const Vector3 candidate_b = base_position + Vector3(
        static_cast<float>(std::cos(angle + 0.6) * ring),
        0.0f,
        static_cast<float>(std::sin(angle + 0.6) * ring));
    Vector3 best = candidate_a;
    if (flood_risk(candidate_b, water_snapshot) < flood_risk(candidate_a, water_snapshot)) {
        best = candidate_b;
    }

    const String structure_id = String("camp_") + household_id + String("_") + String::num_int64(tick);
    const Dictionary camp = make_structure_row(
        structure_id,
        String("camp_temp"),
        household_id,
        String("active"),
        best,
        0.7,
        tick,
        tick);
    Array rows = get_household_rows(structures_by_household, household_id);
    rows.append(camp);
    structures_by_household[household_id] = rows;
    return camp;
}

void update_low_access_counter(
    const StructureLifecycleConfig &config,
    Dictionary &low_access_ticks,
    const String &household_id,
    double throughput,
    double path_strength
) {
    const bool low_throughput = throughput < config.low_throughput_abandon_threshold;
    const bool low_path = path_strength < config.low_path_strength_abandon_threshold;
    if (low_throughput && low_path) {
        low_access_ticks[household_id] = read_int_variant(low_access_ticks.get(household_id, 0), 0) + 1;
        return;
    }
    low_access_ticks[household_id] = 0;
}

bool should_abandon(
    const StructureLifecycleConfig &config,
    const Dictionary &low_access_ticks,
    const String &household_id,
    int64_t huts
) {
    if (huts <= config.min_huts_per_household) {
        return false;
    }
    return read_int_variant(low_access_ticks.get(household_id, 0), 0) >= config.abandon_sustain_ticks;
}

String abandon_latest_hut(
    Dictionary &structures_by_household,
    Dictionary &low_access_ticks,
    const String &household_id,
    int64_t tick
) {
    Array rows = get_household_rows(structures_by_household, household_id);
    if (rows.is_empty()) {
        return String();
    }
    for (int64_t index = rows.size() - 1; index >= 0; index--) {
        Dictionary row = as_dictionary(rows[index]);
        if (row.is_empty()) {
            continue;
        }
        if (read_string_variant(row.get("structure_type", String())) != String("hut")) {
            continue;
        }
        if (read_string_variant(row.get("state", String())) != String("active")) {
            continue;
        }
        row["state"] = String("abandoned");
        row["last_updated_tick"] = tick;
        rows[index] = row;
        structures_by_household[household_id] = rows;
        low_access_ticks[household_id] = 0;
        return read_string_variant(row.get("structure_id", String()));
    }
    return String();
}

void retire_temporary_camps(Dictionary &structures_by_household, const String &household_id, int64_t tick) {
    Array rows = get_household_rows(structures_by_household, household_id);
    if (rows.is_empty()) {
        return;
    }
    bool changed = false;
    for (int64_t i = 0; i < rows.size(); i++) {
        Dictionary row = as_dictionary(rows[i]);
        if (row.is_empty()) {
            continue;
        }
        if (read_string_variant(row.get("structure_type", String())) != String("camp_temp")) {
            continue;
        }
        if (read_string_variant(row.get("state", String())) != String("active")) {
            continue;
        }
        row["state"] = String("abandoned");
        row["last_updated_tick"] = tick;
        rows[i] = row;
        changed = true;
    }
    if (changed) {
        structures_by_household[household_id] = rows;
    }
}

double suggested_path_extension_radius(
    const StructureLifecycleConfig &config,
    const Dictionary &structures_by_household,
    const String &household_id
) {
    const int64_t active_camps = active_structure_count_for_type(structures_by_household, household_id, String("camp_temp"));
    const int64_t huts = active_structure_count_for_type(structures_by_household, household_id, String("hut"));
    const double base = config.hut_start_radius + static_cast<double>(std::max<int64_t>(0, huts - 1)) * config.hut_ring_step;
    return snapped(base + static_cast<double>(active_camps + 1) * config.hut_ring_step * 0.75, 0.01);
}

Dictionary export_structures_by_household(const Dictionary &structures_by_household) {
    const Array keys = structures_by_household.keys();
    std::vector<String> household_ids;
    household_ids.reserve(static_cast<size_t>(keys.size()));
    for (int64_t i = 0; i < keys.size(); i++) {
        household_ids.push_back(String(keys[i]).strip_edges());
    }
    std::sort(household_ids.begin(), household_ids.end(), [](const String &a, const String &b) { return a < b; });

    Dictionary out;
    for (const String &household_id : household_ids) {
        const Array raw_rows = get_household_rows(structures_by_household, household_id);
        std::vector<Dictionary> rows;
        rows.reserve(static_cast<size_t>(raw_rows.size()));
        for (int64_t i = 0; i < raw_rows.size(); i++) {
            const Dictionary row = as_dictionary(raw_rows[i]);
            if (!row.is_empty()) {
                rows.push_back(row.duplicate(true));
            }
        }
        std::sort(rows.begin(), rows.end(), [](const Dictionary &a, const Dictionary &b) {
            const String a_id = read_string_variant(a.get("structure_id", String()));
            const String b_id = read_string_variant(b.get("structure_id", String()));
            return a_id < b_id;
        });
        Array sorted_rows;
        for (const Dictionary &row : rows) {
            sorted_rows.append(row);
        }
        out[household_id] = sorted_rows;
    }
    return out;
}

Array export_sorted_anchors(const Array &anchors) {
    std::vector<Dictionary> rows;
    rows.reserve(static_cast<size_t>(anchors.size()));
    for (int64_t i = 0; i < anchors.size(); i++) {
        const Dictionary row = as_dictionary(anchors[i]);
        if (!row.is_empty()) {
            rows.push_back(row.duplicate(true));
        }
    }
    std::sort(rows.begin(), rows.end(), [](const Dictionary &a, const Dictionary &b) {
        const String a_id = read_string_variant(a.get("anchor_id", String()));
        const String b_id = read_string_variant(b.get("anchor_id", String()));
        return a_id < b_id;
    });
    Array out;
    for (const Dictionary &row : rows) {
        out.append(row);
    }
    return out;
}

} // namespace

Dictionary step_structure_lifecycle_native(
    int64_t step_index,
    const Dictionary &lifecycle_payload
) {
    const StructureLifecycleConfig config = read_structure_lifecycle_config(
        as_dictionary(lifecycle_payload.get("config", Dictionary()))
    );
    Dictionary structures_by_household = as_dictionary(
        lifecycle_payload.get("structures", Dictionary())
    ).duplicate(true);
    Array anchors = as_array(lifecycle_payload.get("anchors", Array())).duplicate(true);
    Dictionary runtime_state = as_dictionary(
        lifecycle_payload.get("runtime_state", Dictionary())
    ).duplicate(true);
    const Dictionary household_members = as_dictionary(
        lifecycle_payload.get("household_members", Dictionary())
    );
    const Dictionary household_metrics = as_dictionary(
        lifecycle_payload.get("household_metrics", Dictionary())
    );
    const Dictionary household_positions = as_dictionary(
        lifecycle_payload.get("household_positions", Dictionary())
    );
    const Dictionary water_snapshot = as_dictionary(
        lifecycle_payload.get("water_snapshot", Dictionary())
    );

    Dictionary last_expand_tick = as_dictionary(runtime_state.get("last_expand_tick", Dictionary())).duplicate(true);
    Dictionary low_access_ticks = as_dictionary(runtime_state.get("low_access_ticks", Dictionary())).duplicate(true);
    Dictionary depletion_ticks = as_dictionary(runtime_state.get("depletion_ticks", Dictionary())).duplicate(true);
    Dictionary last_camp_tick = as_dictionary(runtime_state.get("last_camp_tick", Dictionary())).duplicate(true);
    Dictionary path_extension_emitted = as_dictionary(runtime_state.get("path_extension_emitted", Dictionary())).duplicate(true);

    Array expanded;
    Array abandoned;
    Array camps;
    Array path_extensions;
    const Array household_ids = sorted_household_ids_from_members(household_members);
    for (int64_t i = 0; i < household_ids.size(); i++) {
        const String household_id = String(household_ids[i]);
        if (household_id.is_empty()) {
            continue;
        }
        const Variant position_variant = household_positions.has(household_id)
            ? household_positions[household_id]
            : Variant(Vector3());
        if (position_variant.get_type() == Variant::VECTOR3) {
            ensure_household(
                structures_by_household,
                last_expand_tick,
                low_access_ticks,
                depletion_ticks,
                last_camp_tick,
                path_extension_emitted,
                household_id,
                Vector3(position_variant),
                step_index
            );
        }

        const int64_t members = read_int_variant(household_members.get(household_id, 0), 0);
        const int64_t huts = active_structure_count_for_type(structures_by_household, household_id, String("hut"));
        const Dictionary metrics = as_dictionary(household_metrics.get(household_id, Dictionary()));
        const double throughput = clampf_native(
            read_float_variant(metrics.get("throughput", 0.0), 0.0),
            0.0,
            1000.0
        );
        const double path_strength = clampf_native(
            read_float_variant(metrics.get("path_strength", 0.0), 0.0),
            0.0,
            1.0
        );
        const double signal = depletion_signal(config, metrics, throughput, path_strength);
        const double crowding = static_cast<double>(members) / static_cast<double>(std::max<int64_t>(1, huts));

        if (should_expand(config, last_expand_tick, household_id, step_index, crowding, throughput, huts)) {
            const String structure_id = spawn_hut(
                structures_by_household,
                last_expand_tick,
                config,
                household_id,
                position_variant,
                step_index,
                water_snapshot,
                huts
            );
            if (!structure_id.is_empty()) {
                expanded.append(structure_id);
            }
        }

        const int64_t depletion_count = update_depletion_counter(config, depletion_ticks, household_id, signal);
        if (should_emit_path_extension(config, path_extension_emitted, household_id, depletion_count)) {
            Dictionary path_event;
            path_event["household_id"] = household_id;
            path_event["depletion_signal"] = signal;
            path_event["sustain_ticks"] = depletion_count;
            path_event["target_radius"] = suggested_path_extension_radius(config, structures_by_household, household_id);
            path_extensions.append(path_event);
            path_extension_emitted[household_id] = true;
        }

        if (should_spawn_temporary_camp(
                config,
                last_camp_tick,
                structures_by_household,
                household_id,
                step_index,
                depletion_count)) {
            const Dictionary camp = spawn_temporary_camp(
                structures_by_household,
                config,
                household_id,
                position_variant,
                step_index,
                water_snapshot
            );
            if (!camp.is_empty()) {
                camps.append(camp);
                last_camp_tick[household_id] = step_index;
            }
        }

        update_low_access_counter(config, low_access_ticks, household_id, throughput, path_strength);
        if (should_abandon(config, low_access_ticks, household_id, huts)) {
            const String removed_id = abandon_latest_hut(
                structures_by_household,
                low_access_ticks,
                household_id,
                step_index
            );
            if (!removed_id.is_empty()) {
                abandoned.append(removed_id);
            }
        }
        if (depletion_count <= 0) {
            path_extension_emitted[household_id] = false;
            retire_temporary_camps(structures_by_household, household_id, step_index);
        }
    }

    Dictionary result;
    result["ok"] = true;
    result["step_index"] = step_index;
    result["expanded"] = expanded;
    result["abandoned"] = abandoned;
    result["camps"] = camps;
    result["path_extensions"] = path_extensions;
    runtime_state["last_expand_tick"] = last_expand_tick;
    runtime_state["low_access_ticks"] = low_access_ticks;
    runtime_state["depletion_ticks"] = depletion_ticks;
    runtime_state["last_camp_tick"] = last_camp_tick;
    runtime_state["path_extension_emitted"] = path_extension_emitted;
    result["structures"] = export_structures_by_household(structures_by_household);
    result["anchors"] = export_sorted_anchors(anchors);
    result["runtime_state"] = runtime_state;
    return result;
}

} // namespace local_agents::simulation::helpers
