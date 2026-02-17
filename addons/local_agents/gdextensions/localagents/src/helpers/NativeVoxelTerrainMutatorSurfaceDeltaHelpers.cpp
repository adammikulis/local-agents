#include "helpers/NativeVoxelTerrainMutatorSurfaceDeltaHelpers.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace {

constexpr int kWallDefaultChunkSize = 12;
constexpr int kSeaLevelFallback = 1;
constexpr int kWorldHeightMin = 2;
constexpr int kTileValueMin = 0;
constexpr double kWallBrittleness = 1.0;

int read_int_from_variant(const Variant &value, int fallback) {
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

double read_float_from_variant(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        const double v = static_cast<double>(value);
        return std::isfinite(v) ? v : fallback;
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

String read_string_from_variant(const Variant &value, const String &fallback) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}

String tile_id(int x, int z) {
    return String::num_int64(x, 10) + ":" + String::num_int64(z, 10);
}

int floor_divide_to_cell(int value, int scale) {
    if (scale <= 0) {
        return 0;
    }
    if (value >= 0) {
        return static_cast<int>(std::floor(static_cast<double>(value) / static_cast<double>(scale)));
    }
    return -static_cast<int>(std::ceil(static_cast<double>(-value) / static_cast<double>(scale)));
}

double strength_scale_for_brittleness(double brittleness) {
    const double clamped = std::clamp(brittleness, 0.1, 3.0);
    return std::clamp(1.15 - (clamped * 0.35), 0.15, 1.15);
}

Dictionary wall_material_blocks(const String &material_profile_key, double brittleness) {
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

void rebuild_chunk_rows_from_columns(
    const Array &columns,
    Dictionary &chunk_rows_by_chunk,
    int chunk_size,
    int sea_level,
    const Array &target_chunks
) {
    Dictionary target;
    const int64_t target_count = target_chunks.size();
    for (int64_t i = 0; i < target_count; i += 1) {
        const Variant chunk_key_variant = target_chunks[i];
        const String key = read_string_from_variant(chunk_key_variant, String()).strip_edges();
        if (!key.is_empty()) {
            target[key] = true;
        }
    }

    Array keys;
    for (const String &key : target.keys()) {
        keys.append(key);
    }
    if (keys.is_empty()) {
        return;
    }

    for (const String &key : keys) {
        const PackedStringArray parts = key.split(":");
        if (parts.size() != 2) {
            continue;
        }
        const int chunk_x = parts[0].to_int();
        const int chunk_z = parts[1].to_int();
        Array rows;
        const int64_t columns_size = columns.size();
        for (int64_t i = 0; i < columns_size; i += 1) {
            const Variant column_variant = columns[i];
            if (column_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            const Dictionary column = static_cast<Dictionary>(column_variant);
            const int x = read_int_from_variant(column.get("x", 0), 0);
            const int z = read_int_from_variant(column.get("z", 0), 0);
            const int column_chunk_x = static_cast<int>(std::floor(static_cast<double>(x) / static_cast<double>(chunk_size)));
            const int column_chunk_z = static_cast<int>(std::floor(static_cast<double>(z) / static_cast<double>(chunk_size)));
            if (column_chunk_x != chunk_x || column_chunk_z != chunk_z) {
                continue;
            }
            const int surface_y = read_int_from_variant(column.get("surface_y", sea_level), sea_level);
            const String top_block = read_string_from_variant(column.get("top_block", String("stone")), String("stone"));
            const String subsoil_block = read_string_from_variant(column.get("subsoil_block", String("stone")), String("stone"));

            for (int y = 0; y <= surface_y; y += 1) {
                Dictionary row;
                row["x"] = static_cast<int64_t>(x);
                row["y"] = static_cast<int64_t>(y);
                row["z"] = static_cast<int64_t>(z);
                if (y == surface_y) {
                    row["type"] = top_block;
                } else if (y >= surface_y - 2) {
                    row["type"] = subsoil_block;
                } else {
                    row["type"] = String("stone");
                }
                rows.append(row);
            }
            if (surface_y < sea_level) {
                for (int y = surface_y + 1; y <= sea_level; y += 1) {
                    Dictionary row;
                    row["x"] = static_cast<int64_t>(x);
                    row["y"] = static_cast<int64_t>(y);
                    row["z"] = static_cast<int64_t>(z);
                    row["type"] = String("water");
                    rows.append(row);
                }
            }
        }
        chunk_rows_by_chunk[key] = rows;
    }
}

PackedInt32Array pack_surface_y_buffer(const Array &columns, int width, int height) {
    PackedInt32Array packed;
    if (width <= 0 || height <= 0) {
        return packed;
    }
    packed.resize(width * height);
    const int64_t columns_size = columns.size();
    for (int64_t i = 0; i < columns_size; i += 1) {
        const Variant column_variant = columns[i];
        if (column_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary column = static_cast<Dictionary>(column_variant);
        const int x = read_int_from_variant(column.get("x", 0), 0);
        const int z = read_int_from_variant(column.get("z", 0), 0);
        if (x < 0 || x >= width || z < 0 || z >= height) {
            continue;
        }
        packed[z * width + x] = static_cast<int32_t>(read_int_from_variant(column.get("surface_y", 0), 0));
    }
    return packed;
}

} // namespace

namespace local_agents::mutator::helpers {

Dictionary apply_column_surface_delta(
    Object *simulation_controller,
    Dictionary &env_snapshot,
    const Array &changed_tiles,
    const Dictionary &height_overrides,
    const bool raise_surface,
    const Dictionary &column_metadata_overrides,
    const bool include_snapshots
) {
    Dictionary result;
    Dictionary failed;
    failed["ok"] = true;
    failed["changed"] = false;
    failed["error"] = String();
    failed["changed_tiles"] = Array();
    failed["changed_chunks"] = Array();

    Dictionary voxel_world = env_snapshot.get("voxel_world", Dictionary()).duplicate(true);
    if (voxel_world.is_empty()) {
        return failed;
    }
    Array columns = voxel_world.get("columns", Array());
    if (columns.is_empty()) {
        return failed;
    }

    const int width = read_int_from_variant(env_snapshot.get("width", 0), 0);
    const int height = read_int_from_variant(env_snapshot.get("height", 0), 0);
    const int world_height = std::max(kWorldHeightMin, read_int_from_variant(voxel_world.get("height", 0), 0));
    const int sea_level = std::max(kTileValueMin, read_int_from_variant(voxel_world.get("sea_level", kSeaLevelFallback), kSeaLevelFallback));
    const int chunk_size = std::max(4, read_int_from_variant(voxel_world.get("block_rows_chunk_size", kWallDefaultChunkSize), kWallDefaultChunkSize));

    Dictionary column_index_by_tile = voxel_world.get("column_index_by_tile", Dictionary());
    if (column_index_by_tile.is_empty()) {
        const int64_t columns_size = columns.size();
        for (int64_t i = 0; i < columns_size; i += 1) {
            const Variant column_variant = columns[i];
            if (column_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            const Dictionary column = static_cast<Dictionary>(column_variant);
            const String column_key = tile_id(read_int_from_variant(column.get("x", 0), 0), read_int_from_variant(column.get("z", 0), 0));
            column_index_by_tile[column_key] = i;
        }
    }

    Dictionary tile_index = env_snapshot.get("tile_index", Dictionary());
    Dictionary touched_chunks;
    Array changed_tiles_sorted;
    const int64_t changed_size = changed_tiles.size();
    for (int64_t tile_index_i = 0; tile_index_i < changed_size; tile_index_i += 1) {
        const String tile_key = String(changed_tiles[tile_index_i]).strip_edges();
        if (!column_index_by_tile.has(tile_key)) {
            continue;
        }
        const int64_t column_index = column_index_by_tile.get(tile_key, static_cast<int64_t>(-1));
        if (column_index < 0 || column_index >= columns.size()) {
            continue;
        }
        const Variant raw_column = columns[column_index];
        if (raw_column.get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary column = static_cast<Dictionary>(raw_column);
        const int x = read_int_from_variant(column.get("x", 0), 0);
        const int z = read_int_from_variant(column.get("z", 0), 0);
        const int current_surface = read_int_from_variant(column.get("surface_y", sea_level), sea_level);
        const int delta_levels = std::max(0, read_int_from_variant(height_overrides.get(tile_key, 0), 0));
        int next_surface = current_surface;
        if (raise_surface) {
            next_surface = std::clamp(current_surface + delta_levels, 0, std::max(0, world_height - 2));
        } else {
            next_surface = std::clamp(current_surface - delta_levels, kTileValueMin, std::max(0, world_height - 2));
        }

        bool metadata_changed = false;
        const Variant metadata_variant = column_metadata_overrides.get(tile_key, Dictionary());
        if (metadata_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary metadata = static_cast<Dictionary>(metadata_variant);
            const Array metadata_keys = metadata.keys();
            const int64_t metadata_size = metadata_keys.size();
            for (int64_t key_i = 0; key_i < metadata_size; key_i += 1) {
                const String key = String(metadata_keys[key_i]);
                const Variant next_value = metadata.get(key, Variant());
                if (column.get(key, Variant()) == next_value) {
                    continue;
                }
                column[key] = next_value;
                metadata_changed = true;
            }
        }

        if (next_surface == current_surface && !metadata_changed) {
            continue;
        }

        column["surface_y"] = next_surface;
        if (raise_surface && next_surface != current_surface) {
            const String material_profile_key = read_string_from_variant(column.get("material_profile_key", String("rock")), String("rock"));
            const double brittleness = std::clamp(read_float_from_variant(column.get("brittleness", kWallBrittleness), kWallBrittleness), 0.1, 3.0);
            const Dictionary block_profile = wall_material_blocks(material_profile_key, brittleness);
            column["top_block"] = read_string_from_variant(block_profile.get("top_block", String("gravel")), String("gravel"));
            column["subsoil_block"] = read_string_from_variant(block_profile.get("subsoil_block", String("dirt")), String("dirt"));
            const double strength_scale = strength_scale_for_brittleness(brittleness);
            column["structural_strength_scale"] = strength_scale;
            column["fracture_threshold_scale"] = strength_scale;
        }

        columns[column_index] = column;
        touched_chunks[tile_id(floor_divide_to_cell(x, chunk_size), floor_divide_to_cell(z, chunk_size))] = true;
        changed_tiles_sorted.append(tile_key);
        if (tile_index.has(tile_key)) {
            const Variant tile_row_variant = tile_index.get(tile_key, Dictionary());
            if (tile_row_variant.get_type() == Variant::DICTIONARY) {
                Dictionary tile_row = static_cast<Dictionary>(tile_row_variant);
                const int32_t normalized_surface = std::clamp(next_surface, kTileValueMin, std::max(1, world_height - 1));
                tile_row["elevation"] = static_cast<double>(normalized_surface) / static_cast<double>(std::max(1, world_height - 1));
                tile_index[tile_key] = tile_row;
            }
        }
    }

    if (changed_tiles_sorted.is_empty()) {
        failed["changed_tiles"] = changed_tiles_sorted;
        failed["changed_chunks"] = Array();
        return failed;
    }

    std::vector<String> changed_tile_keys;
    changed_tile_keys.reserve(changed_tiles_sorted.size());
    for (int64_t i = 0; i < changed_tiles_sorted.size(); i += 1) {
        changed_tile_keys.push_back(String(changed_tiles_sorted[i]));
    }
    std::sort(changed_tile_keys.begin(), changed_tile_keys.end());
    changed_tiles_sorted.clear();
    for (const String &changed_tile_key : changed_tile_keys) {
        changed_tiles_sorted.append(changed_tile_key);
    }

    Array touched_chunk_keys;
    const Array touched_chunk_dict_keys = touched_chunks.keys();
    for (int64_t i = 0; i < touched_chunk_dict_keys.size(); i += 1) {
        touched_chunk_keys.append(touched_chunk_dict_keys[i]);
    }
    std::vector<String> touched_chunk_keys_sorted;
    touched_chunk_keys_sorted.reserve(touched_chunk_keys.size());
    for (int64_t i = 0; i < touched_chunk_keys.size(); i += 1) {
        touched_chunk_keys_sorted.push_back(String(touched_chunk_keys[i]));
    }
    std::sort(touched_chunk_keys_sorted.begin(), touched_chunk_keys_sorted.end());
    touched_chunk_keys.clear();
    for (const String &touched_chunk_key : touched_chunk_keys_sorted) {
        touched_chunk_keys.append(touched_chunk_key);
    }

    Dictionary chunk_rows_by_chunk = voxel_world.get("block_rows_by_chunk", Dictionary());
    if (chunk_rows_by_chunk.is_empty()) {
        const int64_t columns_size = columns.size();
        for (int64_t i = 0; i < columns_size; i += 1) {
            const Variant column_variant = columns[i];
            if (column_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            const Dictionary column = static_cast<Dictionary>(column_variant);
            const int cx = floor_divide_to_cell(read_int_from_variant(column.get("x", 0), 0), chunk_size);
            const int cz = floor_divide_to_cell(read_int_from_variant(column.get("z", 0), 0), chunk_size);
            touched_chunks[tile_id(cx, cz)] = true;
        }
    }

    Array rebuild_chunks;
    const Array rebuild_dict_keys = touched_chunks.keys();
    for (int64_t i = 0; i < rebuild_dict_keys.size(); i += 1) {
        rebuild_chunks.append(rebuild_dict_keys[i]);
    }

    rebuild_chunk_rows_from_columns(columns, chunk_rows_by_chunk, chunk_size, sea_level, rebuild_chunks);

    Array block_rows;
    Dictionary block_counts;
    const Array chunk_keys = chunk_rows_by_chunk.keys();
    std::vector<String> chunk_keys_sorted;
    chunk_keys_sorted.reserve(chunk_keys.size());
    for (int64_t i = 0; i < chunk_keys.size(); i += 1) {
        chunk_keys_sorted.push_back(String(chunk_keys[i]));
    }
    std::sort(chunk_keys_sorted.begin(), chunk_keys_sorted.end());
    for (const String &chunk_key : chunk_keys_sorted) {
        const Variant rows_variant = chunk_rows_by_chunk.get(chunk_key, Array());
        if (rows_variant.get_type() != Variant::ARRAY) {
            continue;
        }
        const Array rows = static_cast<Array>(rows_variant);
        block_rows.append_array(rows);
        const int64_t row_count = rows.size();
        for (int64_t r = 0; r < row_count; r += 1) {
            const Variant row_variant = rows[r];
            if (row_variant.get_type() != Variant::DICTIONARY) {
                continue;
            }
            const Dictionary row = static_cast<Dictionary>(row_variant);
            const String type = read_string_from_variant(row.get("type", String("air")), String("air"));
            const int prior = read_int_from_variant(block_counts.get(type, 0), 0);
            block_counts[type] = prior + 1;
        }
    }

    voxel_world["columns"] = columns;
    voxel_world["column_index_by_tile"] = column_index_by_tile;
    voxel_world["block_rows_by_chunk"] = chunk_rows_by_chunk;
    voxel_world["block_rows_chunk_size"] = chunk_size;
    voxel_world["block_rows"] = block_rows;
    voxel_world["block_type_counts"] = block_counts;
    voxel_world["surface_y_buffer"] = pack_surface_y_buffer(columns, width, height);
    env_snapshot["voxel_world"] = voxel_world;
    env_snapshot["tile_index"] = tile_index;

    Array tiles = env_snapshot.get("tiles", Array());
    const int64_t tiles_size = tiles.size();
    for (int64_t ti = 0; ti < tiles_size; ti += 1) {
        const Variant tile_variant = tiles[ti];
        if (tile_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary tile = static_cast<Dictionary>(tile_variant);
        const String row_tile_id = read_string_from_variant(tile.get("tile_id", String()), String());
        if (row_tile_id.is_empty()) {
            continue;
        }
        const Variant tile_index_row_variant = tile_index.get(row_tile_id, Dictionary());
        if (tile_index_row_variant.get_type() == Variant::DICTIONARY) {
            tiles[ti] = static_cast<Dictionary>(tile_index_row_variant).duplicate(true);
        }
    }
    env_snapshot["tiles"] = tiles;

    if (simulation_controller != nullptr) {
        simulation_controller->set(StringName("_environment_snapshot"), env_snapshot);
        simulation_controller->set(StringName("_transform_changed_last_tick"), true);
        simulation_controller->set(StringName("_transform_changed_tiles_last_tick"), changed_tiles_sorted.duplicate(true));
    }

    result["ok"] = true;
    result["changed"] = true;
    result["error"] = String();
    result["changed_tiles"] = changed_tiles_sorted;
    result["changed_chunks"] = touched_chunk_keys;
    if (include_snapshots && simulation_controller != nullptr) {
        result["environment_snapshot"] = env_snapshot.duplicate(true);
        const Variant network_snapshot = simulation_controller->get("_network_state_snapshot");
        if (network_snapshot.get_type() == Variant::NIL) {
            result["network_state_snapshot"] = Dictionary();
        } else {
            result["network_state_snapshot"] = network_snapshot;
        }
    }
    return result;
}

} // namespace local_agents::mutator::helpers
