#ifndef VOXEL_EDIT_CPU_EXECUTION_HELPERS_HPP
#define VOXEL_EDIT_CPU_EXECUTION_HELPERS_HPP

#include "VoxelEditOp.hpp"
#include "sim/VoxelEditGpuExecutor.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace local_agents::simulation::helpers {

struct VoxelEditCpuVoxelKey {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;

    bool operator==(const VoxelEditCpuVoxelKey &other) const {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct VoxelEditCpuVoxelKeyHash {
    std::size_t operator()(const VoxelEditCpuVoxelKey &key) const;
};

struct VoxelEditCpuExecutionOutput {
    VoxelGpuExecutionStats stats;
    std::vector<VoxelEditOp> deferred_ops;
    godot::Dictionary last_changed_region;
    godot::Array last_changed_chunks;
};

int32_t floor_div(int32_t value, int32_t divisor);

VoxelEditCpuExecutionOutput execute_cpu_stage(
    const std::vector<VoxelEditOp> &ops,
    const VoxelGpuRuntimePolicy &policy,
    int32_t chunk_size,
    std::unordered_map<VoxelEditCpuVoxelKey, double, VoxelEditCpuVoxelKeyHash> &voxel_values
);

} // namespace local_agents::simulation::helpers

#endif // VOXEL_EDIT_CPU_EXECUTION_HELPERS_HPP
