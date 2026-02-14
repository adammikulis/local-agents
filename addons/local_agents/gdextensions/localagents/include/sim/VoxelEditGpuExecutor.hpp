#ifndef LOCAL_AGENTS_VOXEL_EDIT_GPU_EXECUTOR_HPP
#define LOCAL_AGENTS_VOXEL_EDIT_GPU_EXECUTOR_HPP

#include "VoxelEditOp.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>
#include <vector>

namespace local_agents::simulation {

struct VoxelGpuRuntimePolicy {
    int32_t voxel_scale = 1;
    int32_t op_stride = 1;
    int32_t stride_phase = 0;
    double zoom_factor = 1.0;
    double uniformity_score = 0.0;
    bool zoom_throttle_applied = false;
    bool uniformity_upscale_applied = false;
};

struct VoxelGpuExecutionStats {
    int64_t ops_scanned = 0;
    int64_t ops_processed = 0;
    int64_t ops_requeued = 0;
    int64_t ops_changed = 0;
    godot::Dictionary changed_region;
    godot::Array changed_chunks;
    godot::Array changed_entries;
};

struct VoxelGpuExecutionResult {
    bool ok = false;
    godot::String error_code;
    VoxelGpuExecutionStats stats;
    std::vector<VoxelEditOp> deferred_ops;
};

class VoxelEditGpuExecutor final {
public:
    static VoxelGpuExecutionResult execute(
        const std::vector<VoxelEditOp> &ops,
        const VoxelGpuRuntimePolicy &policy,
        int32_t chunk_size,
        const godot::String &shader_path
    );
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_VOXEL_EDIT_GPU_EXECUTOR_HPP
