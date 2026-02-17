#include "LocalAgentsNativeVoxelTerrainMutator.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <string>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "helpers/NativeVoxelTerrainMutatorSurfaceDeltaHelpers.hpp"

using namespace godot;

namespace {

constexpr int kWallHeightLevels = 6;
constexpr int kWallHalfSpanTiles = 4;
constexpr int kWallThicknessTiles = 1;
constexpr int kWallColumnSpanInterval = 3;
constexpr int kWallColumnExtraLevels = 4;
constexpr int kWallColumnExtraMaxScale = 3;
constexpr double kWallPillarHeightScaleMin = 0.25;
constexpr double kWallPillarHeightScaleMax = 3.0;
constexpr double kWallPillarDensityScaleMin = 0.25;
constexpr double kWallPillarDensityScaleMax = 3.0;
constexpr double kNativeOpValueToLevels = 3.0;
constexpr int kNativeOpMaxLevels = 6;
constexpr double kWallBrittleness = 1.0;
constexpr double kColumnChipProgressMax = 0.999;
constexpr double kDurabilityScaleMin = 0.45;
constexpr double kDurabilityScaleMax = 3.5;
constexpr double kDurabilityFallback = 1.1;
constexpr double kMaterialDurabilitySand = 0.55;
constexpr double kMaterialDurabilityDirt = 0.8;
constexpr double kMaterialDurabilityGravel = 1.15;
constexpr double kMaterialDurabilityClay = 1.35;
constexpr double kMaterialDurabilityRock = 1.9;
constexpr double kMaterialDurabilityBasalt = 2.2;
constexpr double kMaterialDurabilityMetal = 2.8;
constexpr double kMaterialDurabilityWood = 1.0;

constexpr int kNativeOpEmptyLevel = 0;
constexpr int kWallForwardDistanceMeters = 9;
constexpr int kWallDefaultChunkSize = 12;
constexpr int kSeaLevelFallback = 1;
constexpr int kWorldHeightMin = 2;
constexpr int kTileValueMin = 0;

constexpr const char *kPathInvalidController = "stage_invalid_controller";
constexpr const char *kPathNativeOpsPrimary = "native_ops_payload_primary";
constexpr const char *kPathNoMutation = "native_voxel_stage_no_mutation";
constexpr const char *kGlobalSolidDestructibleTag = "solid_voxel";

static int clamp_i64_to_int(const double value, const int min_value, const int max_value, const int fallback) {
    if (!std::isfinite(value)) {
        return fallback;
    }
    const int resolved = static_cast<int>(std::llround(value));
    if (resolved < min_value) {
        return min_value;
    }
    if (resolved > max_value) {
        return max_value;
    }
    return resolved;
}

static int read_int_from_variant(const Variant &value, int fallback) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int>(static_cast<int64_t>(value));
    }
    if (value.get_type() == Variant::FLOAT) {
        const double float_value = static_cast<double>(value);
        if (std::isfinite(float_value)) {
            return static_cast<int>(static_cast<int64_t>(float_value));
        }
    }
    return fallback;
}

static double read_float_from_variant(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        const double v = static_cast<double>(value);
        return std::isfinite(v) ? v : fallback;
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

static String read_string_from_variant(const Variant &value, const String &fallback) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}

static String tile_id(const int x, const int z) {
    return String::num_int64(x, 10) + ":" + String::num_int64(z, 10);
}

static int floor_divide_to_cell(const int value, const int scale) {
    if (scale <= 0) {
        return 0;
    }
    if (value >= 0) {
        return static_cast<int>(std::floor(static_cast<double>(value) / static_cast<double>(scale)));
    }
    return -static_cast<int>(std::ceil(static_cast<double>(-value) / static_cast<double>(scale)));
}

static bool parse_tile_id(const String &tile_id, int &x, int &z) {
    const PackedStringArray parts = tile_id.split(":");
    if (parts.size() != 2) {
        return false;
    }
    x = parts[0].to_int();
    z = parts[1].to_int();
    return true;
}

static Dictionary stage_result(const Dictionary &payload, const String &path_tag, bool default_changed = false) {
    Dictionary out = payload.duplicate(true);
    const bool changed = out.get("changed", default_changed);
    out["mutation_path"] = path_tag;
    out["mutation_path_state"] = changed ? String("success") : String("failure");
    return out;
}

static Dictionary make_failed_missing_controller_result(int64_t tick) {
    Dictionary out;
    out["ok"] = false;
    out["changed"] = false;
    out["error"] = String(kPathInvalidController);
    out["tick"] = tick;
    out["changed_tiles"] = Array();
    out["changed_chunks"] = Array();
    return out;
}

static Dictionary make_no_snapshot(const int64_t tick, const Array &changed_chunks) {
    Dictionary out;
    out["ok"] = false;
    out["changed"] = false;
    out["error"] = String("native_voxel_op_payload_missing");
    out["details"] = String("native voxel op payload required; CPU fallback disabled");
    out["tick"] = tick;
    out["changed_tiles"] = Array();
    out["changed_chunks"] = changed_chunks;
    out["failure_paths"] = Array::make("native_voxel_op_payload_missing");
    return out;
}

static Array resolve_changed_chunks_from_payload(const Dictionary &payload) {
    Array out;
    const Array keys = Array::make("voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source");
    std::function<void(const Dictionary &, Array &, int)> walk;
    walk = [&](const Dictionary &source, Array &rows, int depth) {
        if (depth > 3) {
            return;
        }
        const Variant changed_rows_variant = source.get("changed_chunks", Array());
        if (changed_rows_variant.get_type() == Variant::ARRAY) {
            const Array changed_rows = static_cast<Array>(changed_rows_variant);
            const int changed_size = changed_rows.size();
            for (int64_t i = 0; i < changed_size; i += 1) {
                const Variant row_variant = changed_rows[i];
                if (row_variant.get_type() == Variant::DICTIONARY || row_variant.get_type() == Variant::STRING) {
                    rows.append(row_variant);
                }
            }
        }
        for (int64_t k = 0; k < keys.size(); k += 1) {
            const String key = static_cast<String>(keys[k]);
            const Variant nested_variant = source.get(key, Variant());
            if (nested_variant.get_type() == Variant::DICTIONARY) {
                walk(static_cast<Dictionary>(nested_variant), rows, depth + 1);
            }
        }
    };
    walk(payload, out, 0);
    return out;
}

static Array normalize_chunk_keys(const Array &rows) {
    Dictionary seen;
    std::vector<int> xs;
    std::vector<int> ys;
    std::vector<int> zs;
    std::vector<String> keys;
    const int64_t input_size = rows.size();
    for (int64_t i = 0; i < input_size; i += 1) {
        const Variant row_variant = rows[i];
        int chunk_x = 0;
        int chunk_y = 0;
        int chunk_z = 0;
        if (row_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary chunk_row = static_cast<Dictionary>(row_variant);
            chunk_x = read_int_from_variant(chunk_row.get("x", 0), 0);
            chunk_y = read_int_from_variant(chunk_row.get("y", 0), 0);
            chunk_z = read_int_from_variant(chunk_row.get("z", chunk_row.get("y", 0)), 0);
        } else if (row_variant.get_type() == Variant::STRING) {
            const String key = String(row_variant);
            const PackedStringArray parts = key.split(":");
            if (parts.size() != 2) {
                continue;
            }
            chunk_x = parts[0].to_int();
            chunk_y = 0;
            chunk_z = parts[1].to_int();
        } else {
            continue;
        }
        const String normalized_key = String::num_int64(chunk_x, 10) + ":" + String::num_int64(chunk_y, 10) + ":" + String::num_int64(chunk_z, 10);
        if (seen.has(normalized_key)) {
            continue;
        }
        seen[normalized_key] = true;
        xs.push_back(chunk_x);
        ys.push_back(chunk_y);
        zs.push_back(chunk_z);
        keys.push_back(normalized_key);
    }

    std::vector<size_t> sort_keys(xs.size());
    for (size_t i = 0; i < sort_keys.size(); i += 1) {
        sort_keys[i] = i;
    }
    std::sort(sort_keys.begin(), sort_keys.end(), [&](size_t a, size_t b) {
        if (xs[a] != xs[b]) {
            return xs[a] < xs[b];
        }
        if (ys[a] != ys[b]) {
            return ys[a] < ys[b];
        }
        return zs[a] < zs[b];
    });

    Array out;
    for (const size_t index : sort_keys) {
        Dictionary chunk;
        chunk["x"] = static_cast<int64_t>(xs[index]);
        chunk["y"] = static_cast<int64_t>(ys[index]);
        chunk["z"] = static_cast<int64_t>(zs[index]);
        out.append(chunk);
    }
    return out;
}

static Array resolve_native_ops_payload(const Dictionary &payload) {
    Array out;
    const Variant native_ops_variant = payload.get("native_ops", nullptr);
    if (native_ops_variant.get_type() != Variant::ARRAY) {
        return out;
    }
    const Array native_ops = static_cast<Array>(native_ops_variant);
    for (int64_t i = 0; i < native_ops.size(); i += 1) {
        const Variant row_variant = native_ops[i];
        if (row_variant.get_type() == Variant::DICTIONARY) {
            out.append(static_cast<Dictionary>(row_variant).duplicate(true));
        }
    }
    return out;
}

static void normalize_target_wall_profile(Dictionary &profile, const Variant &target_wall_profile) {
    profile["wall_height_levels"] = kWallHeightLevels;
    profile["column_extra_levels"] = kWallColumnExtraLevels;
    profile["column_span_interval"] = kWallColumnSpanInterval;
    profile["material_profile_key"] = String("rock");
    profile["destructible_tag"] = String("target_wall");
    profile["brittleness"] = kWallBrittleness;
    profile["pillar_height_scale"] = 1.0;
    profile["pillar_density_scale"] = 1.0;

    Dictionary values;
    if (target_wall_profile.get_type() == Variant::DICTIONARY) {
        values = static_cast<Dictionary>(target_wall_profile);
    } else if (target_wall_profile.get_type() == Variant::OBJECT) {
        Object *profile_object = Object::cast_to<Object>(static_cast<Object *>(target_wall_profile));
        if (profile_object != nullptr && profile_object->has_method("to_dict")) {
            const Variant dict_variant = profile_object->call("to_dict");
            if (dict_variant.get_type() == Variant::DICTIONARY) {
                values = static_cast<Dictionary>(dict_variant);
            }
        }
    }

    const double brittleness = std::clamp(read_float_from_variant(values.get("brittleness", kWallBrittleness), kWallBrittleness), 0.1, 3.0);
    const double pillar_height_scale = std::clamp(
        read_float_from_variant(values.get("pillar_height_scale", 1.0), 1.0), kWallPillarHeightScaleMin, kWallPillarHeightScaleMax);
    const double pillar_density_scale = std::clamp(
        read_float_from_variant(values.get("pillar_density_scale", 1.0), 1.0), kWallPillarDensityScaleMin, kWallPillarDensityScaleMax);
    profile["wall_height_levels"] = std::max(1, read_int_from_variant(values.get("wall_height_levels", kWallHeightLevels), kWallHeightLevels));
    profile["column_extra_levels"] = std::max(0, read_int_from_variant(values.get("column_extra_levels", kWallColumnExtraLevels), kWallColumnExtraLevels));
    profile["column_span_interval"] = std::max(1, read_int_from_variant(values.get("column_span_interval", kWallColumnSpanInterval), kWallColumnSpanInterval));
    profile["material_profile_key"] = read_string_from_variant(values.get("material_profile_key", String("rock")), String("rock")).strip_edges();
    if (profile["material_profile_key"] == String()) {
        profile["material_profile_key"] = String("rock");
    }
    profile["destructible_tag"] = read_string_from_variant(values.get("destructible_tag", String("target_wall")), String("target_wall")).strip_edges();
    if (profile["destructible_tag"] == String()) {
        profile["destructible_tag"] = String("target_wall");
    }
    profile["brittleness"] = brittleness;
    profile["pillar_height_scale"] = pillar_height_scale;
    profile["pillar_density_scale"] = pillar_density_scale;
}

static double strength_scale_for_brittleness(const double brittleness) {
    const double clamped = std::clamp(brittleness, 0.1, 3.0);
    return std::clamp(1.15 - (clamped * 0.35), 0.15, 1.15);
}

static Dictionary wall_material_blocks(const String &material_profile_key, const double brittleness) {
    const String key = material_profile_key.strip_edges().to_lower();
    const double clamped = std::clamp(brittleness, 0.1, 3.0);
    Dictionary profile;
    if (key.find("sand") != -1) {
        profile["top_block"] = String("sand");
        profile["subsoil_block"] = String("sand");
        return profile;
    }
    if (key.find("clay") != -1) {
        profile["top_block"] = String("clay");
        profile["subsoil_block"] = (clamped <= 1.4) ? String("clay") : String("sand");
        return profile;
    }
    if (key.find("gravel") != -1) {
        profile["top_block"] = String("gravel");
        profile["subsoil_block"] = String("gravel");
        return profile;
    }
    if (clamped >= 2.0) {
        profile["top_block"] = String("sand");
        profile["subsoil_block"] = String("gravel");
        return profile;
    }
    if (clamped >= 1.2) {
        profile["top_block"] = String("gravel");
        profile["subsoil_block"] = String("dirt");
        return profile;
    }
    if (clamped <= 0.6) {
        profile["top_block"] = String("clay");
        profile["subsoil_block"] = String("dirt");
        return profile;
    }
    profile["top_block"] = String("dirt");
    profile["subsoil_block"] = String("gravel");
    return profile;
}

static bool is_non_solid_block_type(const String &block_type) {
    const String key = block_type.strip_edges().to_lower();
    return key == String("air") || key == String("water") || key == String("void") || key == String("empty");
}

static bool is_solid_column(const Dictionary &column) {
    const String top_block = read_string_from_variant(column.get("top_block", String("stone")), String("stone"));
    return !is_non_solid_block_type(top_block);
}

static String resolve_column_material_key(const Dictionary &column) {
    String material_key = read_string_from_variant(column.get("material_profile_key", String()), String()).strip_edges().to_lower();
    if (!material_key.is_empty()) {
        return material_key;
    }
    material_key = read_string_from_variant(column.get("top_block", String()), String()).strip_edges().to_lower();
    if (!material_key.is_empty()) {
        return material_key;
    }
    material_key = read_string_from_variant(column.get("subsoil_block", String()), String()).strip_edges().to_lower();
    if (!material_key.is_empty()) {
        return material_key;
    }
    return String("rock");
}

static double base_material_durability(const String &material_key) {
    const String key = material_key.strip_edges().to_lower();
    if (key.find("sand") != -1) {
        return kMaterialDurabilitySand;
    }
    if (key.find("dirt") != -1 || key.find("soil") != -1) {
        return kMaterialDurabilityDirt;
    }
    if (key.find("gravel") != -1) {
        return kMaterialDurabilityGravel;
    }
    if (key.find("clay") != -1) {
        return kMaterialDurabilityClay;
    }
    if (key.find("basalt") != -1) {
        return kMaterialDurabilityBasalt;
    }
    if (key.find("metal") != -1 || key.find("steel") != -1 || key.find("iron") != -1) {
        return kMaterialDurabilityMetal;
    }
    if (key.find("wood") != -1 || key.find("timber") != -1) {
        return kMaterialDurabilityWood;
    }
    if (key.find("rock") != -1 || key.find("stone") != -1) {
        return kMaterialDurabilityRock;
    }
    return kDurabilityFallback;
}

static double resolve_column_durability(const Dictionary &column, const String &material_key) {
    if (column.has("durability_hits")) {
        return std::max(0.1, read_float_from_variant(column.get("durability_hits", kDurabilityFallback), kDurabilityFallback));
    }
    const double base = base_material_durability(material_key);
    const double fracture_threshold_scale = std::clamp(read_float_from_variant(column.get("fracture_threshold_scale", 1.0), 1.0), 0.25, 4.0);
    const double structural_strength_scale = std::clamp(read_float_from_variant(column.get("structural_strength_scale", fracture_threshold_scale), fracture_threshold_scale), 0.25, 4.0);
    const double durability_scale = std::clamp((fracture_threshold_scale + structural_strength_scale) * 0.5, kDurabilityScaleMin, kDurabilityScaleMax);
    return std::max(0.1, base * durability_scale);
}

static String resolve_spawn_material_tag(const Dictionary &op, const String &fallback) {
    const Array keys = Array::make("destroyed_voxel_material_tag", "projectile_material_tag", "material_tag", "material_profile_key");
    for (int64_t i = 0; i < keys.size(); i += 1) {
        const String key = String(keys[i]);
        const String value = read_string_from_variant(op.get(key, String()), String()).strip_edges();
        if (!value.is_empty()) {
            return value;
        }
    }
    return fallback;
}

static Dictionary resolve_column_index_by_tile(const Array &columns, const Dictionary &voxel_world) {
    Dictionary column_index_by_tile = voxel_world.get("column_index_by_tile", Dictionary());
    if (!column_index_by_tile.is_empty()) {
        return column_index_by_tile;
    }
    const int64_t columns_size = columns.size();
    for (int64_t i = 0; i < columns_size; i += 1) {
        const Variant column_variant = columns[i];
        if (column_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary column = static_cast<Dictionary>(column_variant);
        const String key = tile_id(read_int_from_variant(column.get("x", 0), 0), read_int_from_variant(column.get("z", 0), 0));
        column_index_by_tile[key] = i;
    }
    return column_index_by_tile;
}

static Array chunk_keys_for_tiles(const Dictionary &env_snapshot, const Array &changed_tiles) {
    Dictionary voxel_world = env_snapshot.get("voxel_world", Dictionary());
    const int chunk_size = std::max(4, read_int_from_variant(voxel_world.get("block_rows_chunk_size", kWallDefaultChunkSize), kWallDefaultChunkSize));
    Dictionary chunks;
    const int64_t changed_size = changed_tiles.size();
    for (int64_t i = 0; i < changed_size; i += 1) {
        const String tile_key = String(changed_tiles[i]).strip_edges();
        int x = 0;
        int z = 0;
        if (!parse_tile_id(tile_key, x, z)) {
            continue;
        }
        const String key = tile_id(std::floor(static_cast<double>(x) / static_cast<double>(chunk_size)), std::floor(static_cast<double>(z) / static_cast<double>(chunk_size)));
        chunks[key] = true;
    }
    Array out;
    const Array keys = chunks.keys();
    std::vector<String> sorted;
    sorted.reserve(keys.size());
    for (int64_t i = 0; i < keys.size(); i += 1) {
        sorted.push_back(String(keys[i]));
    }
    std::sort(sorted.begin(), sorted.end());
    for (const String &chunk_key : sorted) {
        out.append(chunk_key);
    }
    return out;
}

} // namespace

using namespace godot;

void LocalAgentsNativeVoxelTerrainMutator::_bind_methods() {
    ClassDB::bind_method(D_METHOD("apply_native_voxel_stage_delta", "simulation_controller", "tick", "payload"),
                         &LocalAgentsNativeVoxelTerrainMutator::apply_native_voxel_stage_delta);
    ClassDB::bind_method(D_METHOD("apply_native_voxel_ops_payload", "simulation_controller", "tick", "payload"),
                         &LocalAgentsNativeVoxelTerrainMutator::apply_native_voxel_ops_payload);
    ClassDB::bind_method(D_METHOD("stamp_default_target_wall", "simulation_controller", "tick", "camera_transform", "target_wall_profile"),
                         &LocalAgentsNativeVoxelTerrainMutator::stamp_default_target_wall, DEFVAL(Variant()));
}

Dictionary LocalAgentsNativeVoxelTerrainMutator::apply_native_voxel_stage_delta(Object *simulation_controller, int64_t tick, const Dictionary &payload) {
    if (simulation_controller == nullptr) {
        return stage_result(make_failed_missing_controller_result(tick), String(kPathInvalidController), false);
    }

    Dictionary ops_result = apply_native_voxel_ops_payload(simulation_controller, tick, payload);
    Dictionary last = stage_result(ops_result, String(kPathNativeOpsPrimary), false);
    if (bool(last.get("changed", false))) {
        return last;
    }

    const String error_code = read_string_from_variant(last.get("error", String()), String());
    if (!error_code.is_empty()) {
        if (last.get("failure_paths", Variant()) == Variant()) {
            Array failure_paths;
            failure_paths.append(error_code);
            last["failure_paths"] = failure_paths;
        }
        return last;
    }

    const Array resolved_chunks = normalize_chunk_keys(resolve_changed_chunks_from_payload(payload));
    Dictionary no_mutation;
    no_mutation["ok"] = false;
    no_mutation["changed"] = false;
    no_mutation["error"] = String("native_voxel_stage_no_mutation");
    no_mutation["details"] = String("native voxel stage produced no native-op mutations");
    no_mutation["tick"] = tick;
    no_mutation["changed_tiles"] = Array();
    no_mutation["changed_chunks"] = resolved_chunks;
    no_mutation["failure_paths"] = Array::make(String("native_voxel_stage_no_mutation"));
    return stage_result(no_mutation, String(kPathNoMutation), false);
}

Dictionary LocalAgentsNativeVoxelTerrainMutator::apply_native_voxel_ops_payload(Object *simulation_controller, int64_t tick, const Dictionary &payload) {
    Dictionary ops_result;
    if (simulation_controller == nullptr) {
        return make_failed_missing_controller_result(tick);
    }

    const Array changed_chunks_rows = resolve_changed_chunks_from_payload(payload);
    Array changed_chunks = normalize_chunk_keys(changed_chunks_rows);

    const Array ops = resolve_native_ops_payload(payload);
    if (ops.is_empty()) {
        return make_no_snapshot(tick, changed_chunks);
    }

    Variant env_snapshot_variant = simulation_controller->get("_environment_snapshot");
    if (env_snapshot_variant.get_type() != Variant::DICTIONARY) {
        ops_result["ok"] = false;
        ops_result["changed"] = false;
        ops_result["error"] = String("environment_snapshot_unavailable");
        ops_result["tick"] = tick;
        ops_result["changed_tiles"] = Array();
        ops_result["changed_chunks"] = changed_chunks;
        return stage_result(ops_result, String(kPathNativeOpsPrimary), false);
    }

    Dictionary env_snapshot = static_cast<Dictionary>(env_snapshot_variant).duplicate(true);
    const int width = read_int_from_variant(env_snapshot.get("width", 0), 0);
    const int height = read_int_from_variant(env_snapshot.get("height", 0), 0);
    if (width <= 0 || height <= 0) {
        ops_result["ok"] = false;
        ops_result["changed"] = false;
        ops_result["error"] = String("environment_dimensions_invalid");
        ops_result["tick"] = tick;
        ops_result["changed_tiles"] = Array();
        ops_result["changed_chunks"] = changed_chunks;
        return stage_result(ops_result, String(kPathNativeOpsPrimary), false);
    }

    std::vector<Dictionary> sorted_ops;
    sorted_ops.reserve(ops.size());
    for (int64_t i = 0; i < ops.size(); i += 1) {
        const Variant op_variant = ops[i];
        if (op_variant.get_type() == Variant::DICTIONARY) {
            sorted_ops.push_back(static_cast<Dictionary>(op_variant));
        }
    }
    std::sort(sorted_ops.begin(), sorted_ops.end(), [](const Dictionary &left, const Dictionary &right) {
        const int left_sequence = left.get("sequence_id", 0);
        const int right_sequence = right.get("sequence_id", 0);
        if (left_sequence != right_sequence) {
            return left_sequence < right_sequence;
        }
        const int left_x = int(left.get("x", 0));
        const int right_x = int(right.get("x", 0));
        if (left_x != right_x) {
            return left_x < right_x;
        }
        const int left_y = int(left.get("y", 0));
        const int right_y = int(right.get("y", 0));
        if (left_y != right_y) {
            return left_y < right_y;
        }
        const int left_z = int(left.get("z", 0));
        const int right_z = int(right.get("z", 0));
        if (left_z != right_z) {
            return left_z < right_z;
        }
        return String(left.get("operation", String("set"))) < String(right.get("operation", String("set")));
    });

    Dictionary signed_levels;
    Dictionary impact_damage_by_tile;
    Dictionary impact_material_tag_by_tile;
    for (const Dictionary &op : sorted_ops) {
        const int x = read_int_from_variant(op.get("x", 0), 0);
        const int z = read_int_from_variant(op.get("z", 0), 0);
        String op_name = read_string_from_variant(op.get("operation", String("fracture")), String("fracture")).to_lower();
        const double value = std::max(0.05, read_float_from_variant(op.get("value", 0.0), 0.0));
        const int levels = clamp_i64_to_int(value * kNativeOpValueToLevels, 1, kNativeOpMaxLevels, 1);
        const double radius = std::max(0.0, read_float_from_variant(op.get("radius", 0.0), 0.0));
        const bool raise_surface = (op_name == String("add")) || (op_name == String("max")) || (op_name == String("set") && value >= 1.0);
        const int sign = raise_surface ? 1 : -1;
        const int radius_cells = static_cast<int>(std::ceil(radius));

        for (int dz = -radius_cells; dz <= radius_cells; dz += 1) {
            for (int dx = -radius_cells; dx <= radius_cells; dx += 1) {
                if (radius_cells > 0 && static_cast<float>(dx * dx + dz * dz) > static_cast<float>(radius * radius)) {
                    continue;
                }
                const int tx = std::clamp(x + dx, 0, width - 1);
                const int tz = std::clamp(z + dz, 0, height - 1);
                const String tile_key = tile_id(tx, tz);
                if (raise_surface) {
                    const int prior = read_int_from_variant(signed_levels.get(tile_key, 0), 0);
                    signed_levels[tile_key] = prior + sign * levels;
                } else {
                    const double prior_damage = read_float_from_variant(impact_damage_by_tile.get(tile_key, 0.0), 0.0);
                    impact_damage_by_tile[tile_key] = prior_damage + static_cast<double>(levels);
                    const String fallback_material = read_string_from_variant(impact_material_tag_by_tile.get(tile_key, String()), String());
                    const String resolved_material_tag = resolve_spawn_material_tag(op, fallback_material).strip_edges();
                    if (!resolved_material_tag.is_empty()) {
                        impact_material_tag_by_tile[tile_key] = resolved_material_tag;
                    }
                }
            }
        }
    }

    if (signed_levels.is_empty() && impact_damage_by_tile.is_empty()) {
        ops_result["ok"] = false;
        ops_result["changed"] = false;
        ops_result["error"] = String("native_voxel_ops_empty_after_normalization");
        ops_result["tick"] = tick;
        ops_result["changed_tiles"] = Array();
        ops_result["changed_chunks"] = changed_chunks;
        return stage_result(ops_result, String(kPathNativeOpsPrimary), false);
    }

    Dictionary lower_overrides;
    Dictionary lower_metadata_overrides;
    Dictionary raise_overrides;
    const Array signed_keys = signed_levels.keys();
    for (int64_t i = 0; i < signed_keys.size(); i += 1) {
        const String tile_key = String(signed_keys[i]);
        const int signed_level = read_int_from_variant(signed_levels.get(tile_key, 0), 0);
        if (signed_level < 0) {
            lower_overrides[tile_key] = abs(signed_level);
        } else if (signed_level > 0) {
            raise_overrides[tile_key] = signed_level;
        }
    }

    Dictionary voxel_world = env_snapshot.get("voxel_world", Dictionary());
    const Array columns = voxel_world.get("columns", Array());
    const Dictionary column_index_by_tile = resolve_column_index_by_tile(columns, voxel_world);
    const int world_height = std::max(kWorldHeightMin, read_int_from_variant(voxel_world.get("height", 0), 0));
    Array spawn_entries;
    bool chip_spawn_required = false;
    int64_t chip_progress_spawn_count = 0;
    const Array damage_keys = impact_damage_by_tile.keys();
    for (int64_t i = 0; i < damage_keys.size(); i += 1) {
        const String tile_key = String(damage_keys[i]).strip_edges();
        if (tile_key.is_empty() || !column_index_by_tile.has(tile_key)) {
            continue;
        }
        const int64_t column_index = read_int_from_variant(column_index_by_tile.get(tile_key, -1), -1);
        if (column_index < 0 || column_index >= columns.size()) {
            continue;
        }
        const Variant column_variant = columns[column_index];
        if (column_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary column = static_cast<Dictionary>(column_variant);
        if (!is_solid_column(column)) {
            continue;
        }

        const String material_key = resolve_column_material_key(column);
        const double durability = resolve_column_durability(column, material_key);
        const double impact_damage = std::max(0.0, read_float_from_variant(impact_damage_by_tile.get(tile_key, 0.0), 0.0));
        if (impact_damage <= 0.0) {
            continue;
        }

        const double prior_chip_progress = std::clamp(read_float_from_variant(column.get("fracture_chip_progress", 0.0), 0.0), 0.0, kColumnChipProgressMax);
        const double normalized_damage = impact_damage / std::max(0.1, durability);
        const double total_progress = prior_chip_progress + normalized_damage;
        const int levels_to_remove = std::max(0, static_cast<int>(std::floor(total_progress + 1.0e-6)));
        const double next_chip_progress = std::clamp(total_progress - static_cast<double>(levels_to_remove), 0.0, kColumnChipProgressMax);
        const int current_surface = std::clamp(read_int_from_variant(column.get("surface_y", 0), 0), kTileValueMin, std::max(kTileValueMin, world_height - 1));
        const int next_surface = std::clamp(current_surface - levels_to_remove, kTileValueMin, std::max(kTileValueMin, world_height - 1));

        if (levels_to_remove > 0) {
            lower_overrides[tile_key] = levels_to_remove;
        } else {
            lower_overrides[tile_key] = kNativeOpEmptyLevel;
        }

        Dictionary row_metadata;
        row_metadata["destructible"] = true;
        row_metadata["destructible_tag"] = String(kGlobalSolidDestructibleTag);
        row_metadata["material_profile_key"] = material_key;
        row_metadata["durability_hits"] = durability;
        row_metadata["fracture_chip_progress"] = next_chip_progress;
        row_metadata["fracture_chip_hits"] = read_int_from_variant(column.get("fracture_chip_hits", 0), 0) + 1;
        row_metadata["fracture_chip_damage_last"] = normalized_damage;
        row_metadata["fracture_chip_state"] = levels_to_remove > 0 ? String("fractured") : String("chipped");
        lower_metadata_overrides[tile_key] = row_metadata;

        const bool chip_progress_increased = next_chip_progress > (prior_chip_progress + 1.0e-6);
        const bool voxel_not_fully_removed = levels_to_remove <= 0 || next_surface > kTileValueMin;
        const bool emit_spawn_entry = (chip_progress_increased && voxel_not_fully_removed) || (levels_to_remove > 0 && voxel_not_fully_removed);
        if (emit_spawn_entry) {
            const String op_material_tag = read_string_from_variant(impact_material_tag_by_tile.get(tile_key, String()), String()).strip_edges();
            const String resolved_material_tag = op_material_tag.is_empty()
                ? (material_key.is_empty() ? String("dense_voxel") : material_key)
                : op_material_tag;

            Dictionary spawn_entry;
            spawn_entry["x"] = read_int_from_variant(column.get("x", 0), 0);
            spawn_entry["y"] = current_surface;
            spawn_entry["z"] = read_int_from_variant(column.get("z", 0), 0);

            Dictionary position;
            position["x"] = spawn_entry["x"];
            position["y"] = spawn_entry["y"];
            position["z"] = spawn_entry["z"];
            spawn_entry["position"] = position;

            Dictionary impulse_direction;
            impulse_direction["x"] = 0.0;
            impulse_direction["y"] = 1.0;
            impulse_direction["z"] = 0.0;
            spawn_entry["impulse_direction"] = impulse_direction;
            spawn_entry["impulse_size"] = std::max(0.35, std::min(6.0, normalized_damage + 0.2));
            spawn_entry["projectile_kind"] = String("voxel_chunk");
            spawn_entry["projectile_material_tag"] = resolved_material_tag;
            spawn_entry["destroyed_voxel_material_tag"] = material_key;
            spawn_entry["material_tag"] = resolved_material_tag;
            spawn_entry["projectile_hardness_tag"] = String("hard");
            spawn_entry["projectile_radius"] = 0.07;
            spawn_entry["projectile_ttl"] = 1.2;
            spawn_entry["spawn_synthesized"] = true;
            spawn_entry["fracture_chip_progress_prior"] = prior_chip_progress;
            spawn_entry["fracture_chip_progress_next"] = next_chip_progress;
            spawn_entry["fracture_chip_state"] = levels_to_remove > 0 ? String("fractured") : String("chipped");
            spawn_entry["sequence_id"] = read_int_from_variant(column.get("fracture_chip_hits", 0), 0) + 1;
            spawn_entries.append(spawn_entry);
            chip_spawn_required = true;
            if (chip_progress_increased) {
                chip_progress_spawn_count += 1;
            }
        }
    }

    Dictionary merged_tiles;
    Array merged_tiles_sorted;

    if (!lower_overrides.is_empty()) {
        Dictionary lower_result = local_agents::mutator::helpers::apply_column_surface_delta(
            simulation_controller,
            env_snapshot,
            lower_overrides.keys(),
            lower_overrides,
            false,
            lower_metadata_overrides,
            false);
        if (bool(lower_result.get("changed", false))) {
            const Variant tiles_variant = lower_result.get("changed_tiles", Array());
            if (tiles_variant.get_type() == Variant::ARRAY) {
                Array tiles_array = static_cast<Array>(tiles_variant);
                for (int64_t i = 0; i < tiles_array.size(); i += 1) {
                    const String tile_id = String(tiles_array[i]);
                    merged_tiles[tile_id] = true;
                }
            }
        }
        if (simulation_controller != nullptr) {
            const Variant env_snapshot_after = simulation_controller->get("_environment_snapshot");
            if (env_snapshot_after.get_type() == Variant::DICTIONARY) {
                env_snapshot = static_cast<Dictionary>(env_snapshot_after);
            }
        }
    }

    if (!raise_overrides.is_empty()) {
        Dictionary raise_result = local_agents::mutator::helpers::apply_column_surface_delta(simulation_controller, env_snapshot, raise_overrides.keys(), raise_overrides, true, Dictionary(), false);
        if (bool(raise_result.get("changed", false))) {
            const Variant tiles_variant = raise_result.get("changed_tiles", Array());
            if (tiles_variant.get_type() == Variant::ARRAY) {
                Array tiles_array = static_cast<Array>(tiles_variant);
                for (int64_t i = 0; i < tiles_array.size(); i += 1) {
                    const String tile_id = String(tiles_array[i]);
                    merged_tiles[tile_id] = true;
                }
            }
        }
        if (simulation_controller != nullptr) {
            const Variant env_snapshot_after = simulation_controller->get("_environment_snapshot");
            if (env_snapshot_after.get_type() == Variant::DICTIONARY) {
                env_snapshot = static_cast<Dictionary>(env_snapshot_after);
            }
        }
    }

    Array changed_tiles;
    const Array merged_keys = merged_tiles.keys();
    for (int64_t i = 0; i < merged_keys.size(); i += 1) {
        changed_tiles.append(String(merged_keys[i]));
    }
    std::vector<String> changed_tiles_sorted;
    changed_tiles_sorted.reserve(changed_tiles.size());
    for (int64_t i = 0; i < changed_tiles.size(); i += 1) {
        changed_tiles_sorted.push_back(String(changed_tiles[i]));
    }
    std::sort(changed_tiles_sorted.begin(), changed_tiles_sorted.end());
    changed_tiles.clear();
    for (const String &changed_tile : changed_tiles_sorted) {
        changed_tiles.append(changed_tile);
    }

    const Array changed_chunks_final = chunk_keys_for_tiles(env_snapshot, changed_tiles);

    Dictionary out;
    out["tick"] = tick;
    out["changed"] = !changed_tiles.is_empty();
    out["error"] = bool(out.get("changed", false)) ? String() : String("native_voxel_stage_no_mutation");
    out["ok"] = bool(out["changed"]);
    out["changed_tiles"] = changed_tiles;
    out["changed_chunks"] = changed_chunks_final;
    out["spawn_entries"] = spawn_entries;
    out["spawn_entries_required"] = chip_spawn_required;
    out["spawn_entries_status"] = chip_spawn_required ? String("required") : String("not_required");
    out["spawn_entries_warning"] = String();
    out["chip_progress_spawn_count"] = chip_progress_spawn_count;
    Dictionary mutator_spawn_payload;
    mutator_spawn_payload["tick"] = tick;
    mutator_spawn_payload["spawn_entries"] = spawn_entries.duplicate(true);
    mutator_spawn_payload["spawn_entries_required"] = chip_spawn_required;
    mutator_spawn_payload["chip_progress_spawn_count"] = chip_progress_spawn_count;
    simulation_controller->set(StringName("_native_mutator_spawn_payload"), mutator_spawn_payload);
    if (bool(out["changed"])) {
        const Variant env_snapshot_result = simulation_controller->get("_environment_snapshot");
        const Variant network_snapshot = simulation_controller->get("_network_state_snapshot");
        out["environment_snapshot"] = env_snapshot_result;
        if (network_snapshot.get_type() == Variant::NIL) {
            out["network_state_snapshot"] = Dictionary();
        } else {
            out["network_state_snapshot"] = network_snapshot;
        }
    }
    return out;
}

Dictionary LocalAgentsNativeVoxelTerrainMutator::stamp_default_target_wall(
    Object *simulation_controller,
    int64_t tick,
    const Transform3D &camera_transform,
    const Variant &target_wall_profile
) {
    if (simulation_controller == nullptr) {
        return make_failed_missing_controller_result(tick);
    }

    Variant env_snapshot_variant = simulation_controller->get("_environment_snapshot");
    if (env_snapshot_variant.get_type() != Variant::DICTIONARY) {
        Dictionary result;
        result["ok"] = false;
        result["changed"] = false;
        result["error"] = String("environment_snapshot_unavailable");
        result["tick"] = tick;
        result["changed_tiles"] = Array();
        result["changed_chunks"] = Array();
        return result;
    }

    Dictionary env_snapshot = static_cast<Dictionary>(env_snapshot_variant);
    const int width = read_int_from_variant(env_snapshot.get("width", 0), 0);
    const int height = read_int_from_variant(env_snapshot.get("height", 0), 0);
    if (width <= 0 || height <= 0) {
        Dictionary result;
        result["ok"] = true;
        result["changed"] = false;
        result["error"] = String();
        result["tick"] = tick;
        result["changed_tiles"] = Array();
        result["changed_chunks"] = Array();
        return result;
    }

    Dictionary profile;
    normalize_target_wall_profile(profile, target_wall_profile);

    Vector3 forward = -camera_transform.basis.get_column(2);
    forward.y = 0.0;
    if (forward.length_squared() <= 0.0001) {
        forward = Vector3(0.0, 0.0, -1.0);
    }
    forward = forward.normalized();

    const int anchor_x = std::clamp(static_cast<int>(std::round(camera_transform.origin.x + forward.x * kWallForwardDistanceMeters)), 0, width - 1);
    const int anchor_z = std::clamp(static_cast<int>(std::round(camera_transform.origin.z + forward.z * kWallForwardDistanceMeters)), 0, height - 1);

    const bool axis_z_dominant = std::abs(forward.z) >= std::abs(forward.x);

    const int wall_height_levels = std::max(1, read_int_from_variant(profile.get("wall_height_levels", kWallHeightLevels), kWallHeightLevels));
    const int column_span_interval = std::max(1, read_int_from_variant(profile.get("column_span_interval", kWallColumnSpanInterval), kWallColumnSpanInterval));
    const int column_extra_levels = std::max(0, read_int_from_variant(profile.get("column_extra_levels", kWallColumnExtraLevels), kWallColumnExtraLevels));
    const String destructible_tag = read_string_from_variant(profile.get("destructible_tag", String("target_wall")), String("target_wall"));
    const String material_profile_key = read_string_from_variant(profile.get("material_profile_key", String("rock")), String("rock"));
    const double brittleness = std::clamp(read_float_from_variant(profile.get("brittleness", kWallBrittleness), kWallBrittleness), 0.1, 3.0);
    const double pillar_height_scale = std::clamp(
        read_float_from_variant(profile.get("pillar_height_scale", 1.0), 1.0), kWallPillarHeightScaleMin, kWallPillarHeightScaleMax);
    const double pillar_density_scale = std::clamp(
        read_float_from_variant(profile.get("pillar_density_scale", 1.0), 1.0), kWallPillarDensityScaleMin, kWallPillarDensityScaleMax);

    const int effective_column_span_interval = std::max(1, static_cast<int>(std::round(static_cast<double>(column_span_interval) / pillar_density_scale)));
    const int effective_column_extra_levels = std::max(0, static_cast<int>(std::round(static_cast<double>(column_extra_levels) * pillar_height_scale)));
    const double structural_strength_scale = strength_scale_for_brittleness(brittleness);

    Dictionary height_overrides;
    Dictionary column_metadata;

    for (int span = -kWallHalfSpanTiles; span <= kWallHalfSpanTiles; span += 1) {
        for (int depth = 0; depth < kWallThicknessTiles; depth += 1) {
            int tx = anchor_x;
            int tz = anchor_z;
            if (axis_z_dominant) {
                tx += span;
                tz += depth;
            } else {
                tx += depth;
                tz += span;
            }
            if (tx < 0 || tx >= width || tz < 0 || tz >= height) {
                continue;
            }
            const String tile_id_variant = tile_id(tx, tz);
            const int effective_span = (abs(span) % effective_column_span_interval);
            int column_height = wall_height_levels;
            if (depth == 0 && effective_span == 0) {
                column_height += effective_column_extra_levels;
            }
            height_overrides[tile_id_variant] = column_height;
            Dictionary row_metadata;
            row_metadata["destructible"] = true;
            row_metadata["destructible_tag"] = destructible_tag;
            row_metadata["material_profile_key"] = material_profile_key;
            row_metadata["brittleness"] = brittleness;
            row_metadata["structural_strength_scale"] = structural_strength_scale;
            row_metadata["fracture_threshold_scale"] = structural_strength_scale;
            column_metadata[tile_id_variant] = row_metadata;
        }
    }

    Dictionary result = local_agents::mutator::helpers::apply_column_surface_delta(simulation_controller, env_snapshot, height_overrides.keys(), height_overrides, true, column_metadata, true);
    result["tick"] = tick;
    const Array empty_rows;
    if (!result.has("changed_tiles")) {
        result["changed_tiles"] = empty_rows;
    }
    if (!result.has("changed_chunks")) {
        result["changed_chunks"] = empty_rows;
    }
    if (!result.has("environment_snapshot")) {
        result["environment_snapshot"] = env_snapshot;
    }
    if (!result.has("network_state_snapshot")) {
        const Variant network_snapshot = simulation_controller->get("_network_state_snapshot");
        if (network_snapshot.get_type() == Variant::NIL) {
            result["network_state_snapshot"] = Dictionary();
        } else {
            result["network_state_snapshot"] = network_snapshot;
        }
    }
    return result;
}
