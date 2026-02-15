#ifndef LOCAL_AGENTS_VOXEL_GPU_DISPATCH_METADATA_HPP
#define LOCAL_AGENTS_VOXEL_GPU_DISPATCH_METADATA_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>

namespace local_agents::simulation {

struct VoxelGpuDispatchMetadataInput {
    godot::String stage_domain;
    godot::StringName stage_name;
    godot::String backend_name;
    int64_t ops_requested = 0;
    int64_t ops_scanned = 0;
    int64_t ops_processed = 0;
    int64_t ops_requeued = 0;
    int64_t ops_changed = 0;
    int64_t queue_pending_before = 0;
    int64_t queue_pending_after = 0;
    int32_t voxel_scale = 1;
    int32_t op_stride = 1;
    int32_t stride_phase = 0;
    double zoom_factor = 0.0;
    double uniformity_score = 0.0;
    bool zoom_throttle_applied = false;
    bool uniformity_upscale_applied = false;
    godot::String kernel_pass;
    godot::String dispatch_reason;
    godot::Dictionary changed_region;
    godot::Array changed_chunks;
};

godot::Dictionary build_voxel_gpu_dispatch_metadata(const VoxelGpuDispatchMetadataInput &input);

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_VOXEL_GPU_DISPATCH_METADATA_HPP
