#include "helpers/VoxelEditCpuExecutionHelpers.hpp"

#include "FailureEmissionDeterministicNoise.hpp"
#include "helpers/VoxelEditParsingHelpers.hpp"

#include <algorithm>
#include <cmath>
#include <set>
#include <tuple>

using namespace godot;

namespace local_agents::simulation::helpers {

namespace {
struct ChunkKey {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;

    bool operator<(const ChunkKey &other) const {
        return std::tie(x, y, z) < std::tie(other.x, other.y, other.z);
    }
};
} // namespace

std::size_t VoxelEditCpuVoxelKeyHash::operator()(const VoxelEditCpuVoxelKey &key) const {
    const uint32_t ux = static_cast<uint32_t>(key.x);
    const uint32_t uy = static_cast<uint32_t>(key.y);
    const uint32_t uz = static_cast<uint32_t>(key.z);
    std::size_t hash = ux;
    hash ^= static_cast<std::size_t>(uy) + 0x9e3779b9 + (hash << 6u) + (hash >> 2u);
    hash ^= static_cast<std::size_t>(uz) + 0x9e3779b9 + (hash << 6u) + (hash >> 2u);
    return hash;
}

int32_t floor_div(int32_t value, int32_t divisor) {
    if (divisor <= 0) {
        return 0;
    }
    if (value >= 0) {
        return value / divisor;
    }
    return -(((-value) + divisor - 1) / divisor);
}

VoxelEditCpuExecutionOutput execute_cpu_stage(
    const std::vector<VoxelEditOp> &ops,
    const VoxelGpuRuntimePolicy &policy,
    int32_t chunk_size,
    std::unordered_map<VoxelEditCpuVoxelKey, double, VoxelEditCpuVoxelKeyHash> &voxel_values
) {
    VoxelEditCpuExecutionOutput output;
    const int32_t voxel_scale = std::max(1, policy.voxel_scale);
    const int32_t op_stride = std::max(1, policy.op_stride);
    const int32_t stride_phase = static_cast<int32_t>(policy.stride_phase % op_stride);
    output.stats.ops_scanned = static_cast<int64_t>(ops.size());
    output.stats.ops_processed = 0;
    output.stats.ops_requeued = 0;

    bool has_region = false;
    int32_t min_x = 0;
    int32_t min_y = 0;
    int32_t min_z = 0;
    int32_t max_x = 0;
    int32_t max_y = 0;
    int32_t max_z = 0;
    std::set<ChunkKey> changed_chunks;
    output.deferred_ops.reserve(ops.size());

    const auto apply_voxel_delta = [&](const VoxelEditCpuVoxelKey &key, double previous_value, double next_value) {
        if (next_value == previous_value) {
            return;
        }
        const double clamped_next = std::max(0.0, next_value);
        if (previous_value <= 0.0 && clamped_next == 0.0) {
            return;
        }
        if (clamped_next == 0.0) {
            voxel_values.erase(key);
        } else {
            voxel_values[key] = clamped_next;
        }
        output.stats.ops_changed += 1;

        const int32_t qx = key.x;
        const int32_t qy = key.y;
        const int32_t qz = key.z;
        if (!has_region) {
            min_x = qx;
            min_y = qy;
            min_z = qz;
            max_x = qx;
            max_y = qy;
            max_z = qz;
            has_region = true;
        } else {
            min_x = std::min(min_x, qx);
            min_y = std::min(min_y, qy);
            min_z = std::min(min_z, qz);
            max_x = std::max(max_x, qx);
            max_y = std::max(max_y, qy);
            max_z = std::max(max_z, qz);
        }
        changed_chunks.insert(ChunkKey{
            floor_div(qx, chunk_size),
            floor_div(qy, chunk_size),
            floor_div(qz, chunk_size),
        });
    };

    for (const VoxelEditOp &op : ops) {
        if (op_stride > 1) {
            if (static_cast<int32_t>((op.sequence_id + static_cast<uint64_t>(stride_phase)) % static_cast<uint64_t>(op_stride)) != 0) {
                output.deferred_ops.push_back(op);
                output.stats.ops_requeued += 1;
                continue;
            }
        }
        const int32_t qx = floor_div(op.voxel.x, voxel_scale) * voxel_scale;
        const int32_t qy = floor_div(op.voxel.y, voxel_scale) * voxel_scale;
        const int32_t qz = floor_div(op.voxel.z, voxel_scale) * voxel_scale;
        output.stats.ops_processed += 1;

        const VoxelEditCpuVoxelKey voxel_key{qx, qy, qz};
        const auto voxel_iter = voxel_values.find(voxel_key);
        const double previous_value = voxel_iter == voxel_values.end() ? 0.0 : voxel_iter->second;

        if (op.operation == String("fracture") || op.operation == String("cleave")) {
            const double radius = std::max(0.0, op.radius);
            const int32_t radius_cells = static_cast<int32_t>(std::floor(radius / static_cast<double>(voxel_scale)));
            const double radius_squared = radius * radius;
            const bool radial_shape = op.shape == String("radial");
            const bool is_cleave = op.operation == String("cleave");
            const DeterministicNoiseProfile noise_profile = {
                op.noise_seed,
                op.noise_amplitude,
                op.noise_frequency,
                op.noise_octaves,
                op.noise_lacunarity,
                op.noise_gain,
                op.noise_mode
            };
            for (int32_t dz = -radius_cells; dz <= radius_cells; ++dz) {
                const double world_dz = static_cast<double>(dz) * static_cast<double>(voxel_scale);
                const int32_t z = qz + dz * voxel_scale;
                const double dz_sq = world_dz * world_dz;
                for (int32_t dy = -radius_cells; dy <= radius_cells; ++dy) {
                    const double world_dy = static_cast<double>(dy) * static_cast<double>(voxel_scale);
                    const int32_t y = qy + dy * voxel_scale;
                    for (int32_t dx = -radius_cells; dx <= radius_cells; ++dx) {
                        const double world_dx = static_cast<double>(dx) * static_cast<double>(voxel_scale);
                        const int32_t x = qx + dx * voxel_scale;
                        const double dist2 = world_dx * world_dx + (radial_shape ? dz_sq : dz_sq + world_dy * world_dy);
                        if (dist2 > radius_squared) {
                            continue;
                        }
                        const double base_falloff = radius == 0.0 ? 1.0 : std::max(0.0, 1.0 - std::sqrt(dist2) / radius);
                        double falloff = base_falloff;
                        if (is_cleave) {
                            const double signed_distance = op.cleave_normal_x * static_cast<double>(x)
                                + op.cleave_normal_y * static_cast<double>(y)
                                + op.cleave_normal_z * static_cast<double>(z)
                                - op.cleave_plane_offset;
                            if (signed_distance < 0.0) {
                                continue;
                            }
                            const double directional_component = std::clamp(
                                signed_distance / std::max(1.0, radius),
                                0.0,
                                1.0);
                            falloff *= (0.25 + 0.75 * directional_component);
                        }
                        falloff = sample_deterministic_noise_falloff(
                            noise_profile,
                            qx,
                            qy,
                            qz,
                            x,
                            y,
                            z,
                            falloff);
                        const VoxelEditCpuVoxelKey fracture_key{x, y, z};
                        const auto fracture_iter = voxel_values.find(fracture_key);
                        const double fracture_prev = fracture_iter == voxel_values.end() ? 0.0 : fracture_iter->second;
                        apply_voxel_delta(fracture_key, fracture_prev, fracture_prev - op.value * falloff);
                    }
                }
            }
            continue;
        }
        double next_value = previous_value;
        if (op.operation == String("set")) {
            next_value = op.value;
        } else if (op.operation == String("add")) {
            next_value = previous_value + op.value;
        } else if (op.operation == String("max")) {
            next_value = std::max(previous_value, op.value);
        } else if (op.operation == String("min")) {
            next_value = std::min(previous_value, op.value);
        }
        apply_voxel_delta(voxel_key, previous_value, next_value);
    }

    Dictionary changed_region;
    changed_region["valid"] = has_region;
    if (has_region) {
        changed_region["min"] = build_point_dict(min_x, min_y, min_z);
        changed_region["max"] = build_point_dict(max_x, max_y, max_z);
    } else {
        changed_region["min"] = Dictionary();
        changed_region["max"] = Dictionary();
    }
    output.stats.changed_region = changed_region;

    Array changed_chunks_array;
    for (const ChunkKey &chunk : changed_chunks) {
        changed_chunks_array.append(build_point_dict(chunk.x, chunk.y, chunk.z));
    }
    output.stats.changed_chunks = changed_chunks_array;
    output.last_changed_region = changed_region.duplicate(true);
    output.last_changed_chunks = changed_chunks_array.duplicate(true);
    return output;
}

} // namespace local_agents::simulation::helpers
