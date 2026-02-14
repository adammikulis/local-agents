#include "sim/VoxelEditGpuExecutor.hpp"
#include "sim/VoxelGpuResourceCache.hpp"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/classes/rendering_device.hpp>

#include <algorithm>
#include <cstdint>
#include <set>
#include <tuple>
#include <vector>

using namespace godot;

namespace local_agents::simulation {
namespace {

constexpr int64_t k_workgroup_size = 64;
constexpr int64_t k_op_stride_bytes = 88;
constexpr int64_t k_out_stride_bytes = 32;

struct ChunkKey {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;

    bool operator<(const ChunkKey &other) const {
        return std::tie(x, y, z) < std::tie(other.x, other.y, other.z);
    }
};

int32_t floor_div(const int32_t value, const int32_t divisor) {
    if (divisor <= 0) {
        return 0;
    }
    if (value >= 0) {
        return value / divisor;
    }
    return -(((-value) + divisor - 1) / divisor);
}

Dictionary build_point_dict(const int32_t x, const int32_t y, const int32_t z) {
    Dictionary point;
    point["x"] = x;
    point["y"] = y;
    point["z"] = z;
    return point;
}

int32_t operation_to_code(const String &operation) {
    if (operation == String("set")) {
        return 1;
    }
    if (operation == String("add")) {
        return 2;
    }
    if (operation == String("max")) {
        return 3;
    }
    if (operation == String("min")) {
        return 4;
    }
    if (operation == String("fracture")) {
        return 5;
    }
    if (operation == String("cleave")) {
        return 6;
    }
    return 0;
}

int32_t shape_to_code(const String &shape) {
    String normalized = shape.to_lower();
    if (normalized == String("radial")) {
        return 1;
    }
    return 0;
}

int32_t noise_mode_to_code(const String &noise_mode) {
    const String normalized = noise_mode.to_lower();
    if (normalized == String("multiply")) {
        return 1;
    }
    if (normalized == String("replace")) {
        return 2;
    }
    if (normalized == String("add")) {
        return 3;
    }
    return 0;
}

VoxelGpuExecutionResult fail_result(const String &error_code, const std::vector<VoxelEditOp> &pending_ops) {
    VoxelGpuExecutionResult result;
    result.ok = false;
    result.error_code = error_code;
    result.deferred_ops = pending_ops;
    return result;
}

String unavailable_error_code(const bool gpu_required, const String &fallback_error) {
    if (gpu_required) {
        return String("gpu_required_but_unavailable");
    }
    return fallback_error;
}

} // namespace

VoxelGpuExecutionResult VoxelEditGpuExecutor::execute(
    const std::vector<VoxelEditOp> &ops,
    const VoxelGpuRuntimePolicy &policy,
    const int32_t chunk_size,
    const String &shader_path
) {
    VoxelGpuExecutionStats stats;
    stats.ops_scanned = static_cast<int64_t>(ops.size());

    std::vector<VoxelEditOp> deferred_ops;
    std::vector<VoxelEditOp> dispatch_ops;
    deferred_ops.reserve(ops.size());
    dispatch_ops.reserve(ops.size());

    const int32_t op_stride = std::max(1, policy.op_stride);
    const int32_t stride_phase = static_cast<int32_t>(policy.stride_phase % op_stride);
    for (size_t op_index = 0; op_index < ops.size(); op_index += 1) {
        const VoxelEditOp &op = ops[op_index];
        if (op_stride > 1) {
            if (static_cast<int32_t>((op.sequence_id + static_cast<uint64_t>(stride_phase)) % static_cast<uint64_t>(op_stride)) != 0) {
                deferred_ops.push_back(op);
                stats.ops_requeued += 1;
                continue;
            }
        }
        dispatch_ops.push_back(op);
    }
    stats.ops_processed = static_cast<int64_t>(dispatch_ops.size());
    const bool gpu_required = true;
    if (dispatch_ops.empty()) {
        Dictionary changed_region;
        changed_region["valid"] = false;
        changed_region["min"] = Dictionary();
        changed_region["max"] = Dictionary();

        stats.changed_region = changed_region;
        stats.changed_chunks = Array();
        stats.changed_entries = Array();

        VoxelGpuExecutionResult result;
        result.ok = true;
        result.stats = stats;
        result.deferred_ops = std::move(deferred_ops);
        return result;
    }

    OS *os = OS::get_singleton();
    if (os != nullptr && os->has_feature(StringName("headless"))) {
        return fail_result(unavailable_error_code(gpu_required, String("gpu_backend_unavailable")), ops);
    }

    DisplayServer *display_server = DisplayServer::get_singleton();
    if (display_server == nullptr) {
        return fail_result(unavailable_error_code(gpu_required, String("gpu_backend_unavailable")), ops);
    }

    const int64_t dispatch_count = static_cast<int64_t>(dispatch_ops.size());
    VoxelGpuResourceCache &cache = VoxelGpuResourceCache::for_current_thread();
    const VoxelGpuResourceAcquireResult acquire_result = cache.acquire(shader_path, dispatch_count);
    if (!acquire_result.ok || acquire_result.bindings.rd == nullptr) {
        return fail_result(acquire_result.error_code, ops);
    }

    RenderingDevice *rd = acquire_result.bindings.rd;

    const int32_t voxel_scale = std::max(1, policy.voxel_scale);

    PackedByteArray op_bytes;
    op_bytes.resize(dispatch_count * k_op_stride_bytes);
    for (int64_t i = 0; i < dispatch_count; i += 1) {
        const int64_t offset = i * k_op_stride_bytes;
        const VoxelEditOp &op = dispatch_ops[static_cast<size_t>(i)];
        const int32_t aligned_x = floor_div(op.voxel.x, voxel_scale) * voxel_scale;
        const int32_t aligned_y = floor_div(op.voxel.y, voxel_scale) * voxel_scale;
        const int32_t aligned_z = floor_div(op.voxel.z, voxel_scale) * voxel_scale;
        op_bytes.encode_s32(offset + 0, op.voxel.x);
        op_bytes.encode_s32(offset + 4, op.voxel.y);
        op_bytes.encode_s32(offset + 8, op.voxel.z);
        op_bytes.encode_s32(offset + 12, aligned_x);
        op_bytes.encode_s32(offset + 16, aligned_y);
        op_bytes.encode_s32(offset + 20, aligned_z);
        op_bytes.encode_s32(offset + 24, operation_to_code(op.operation));
        op_bytes.encode_u32(offset + 28, static_cast<int64_t>(static_cast<uint32_t>(op.sequence_id & 0xffffffffULL)));
        op_bytes.encode_u32(offset + 32, static_cast<int64_t>(static_cast<uint32_t>((op.sequence_id >> 32u) & 0xffffffffULL)));
        op_bytes.encode_float(offset + 36, static_cast<float>(op.value));
        op_bytes.encode_float(offset + 40, 0.0f);
        op_bytes.encode_float(offset + 44, static_cast<float>(op.cleave_normal_x));
        op_bytes.encode_float(offset + 48, static_cast<float>(op.cleave_normal_y));
        op_bytes.encode_float(offset + 52, static_cast<float>(op.cleave_normal_z));
        op_bytes.encode_float(offset + 56, static_cast<float>(op.cleave_plane_offset));
        op_bytes.encode_float(offset + 60, static_cast<float>(op.radius));
        op_bytes.encode_s32(offset + 64, shape_to_code(op.shape));
        op_bytes.encode_u32(offset + 68, static_cast<int64_t>(static_cast<uint32_t>(op.noise_seed & 0xffffffffULL)));
        op_bytes.encode_u32(offset + 72, static_cast<int64_t>(static_cast<uint32_t>((static_cast<uint64_t>(op.noise_seed) >> 32u) & 0xffffffffULL)));
        op_bytes.encode_float(offset + 76, static_cast<float>(op.noise_amplitude));
        op_bytes.encode_float(offset + 80, static_cast<float>(op.noise_frequency));
        op_bytes.encode_s32(offset + 84, noise_mode_to_code(op.noise_mode));
    }

    PackedByteArray param_bytes;
    param_bytes.resize(8);
    param_bytes.encode_u32(0, static_cast<int64_t>(dispatch_ops.size()));
    param_bytes.encode_s32(4, voxel_scale);

    rd->buffer_update(acquire_result.bindings.ops_rid, 0, static_cast<uint32_t>(op_bytes.size()), op_bytes);
    rd->buffer_update(acquire_result.bindings.params_rid, 0, static_cast<uint32_t>(param_bytes.size()), param_bytes);

    const uint64_t max_workgroup_size_x = acquire_result.bindings.max_workgroup_size_x;
    const uint64_t max_workgroup_invocations = acquire_result.bindings.max_workgroup_invocations;
    const uint64_t max_workgroup_count_x = acquire_result.bindings.max_workgroup_count_x;
    if (max_workgroup_size_x == 0 || max_workgroup_invocations == 0 || max_workgroup_count_x == 0) {
        return fail_result(String("gpu_compute_limits_unavailable"), ops);
    }
    if (k_workgroup_size > static_cast<int64_t>(max_workgroup_size_x) || k_workgroup_size > static_cast<int64_t>(max_workgroup_invocations)) {
        return fail_result(String("gpu_compute_workgroup_unsupported"), ops);
    }

    const uint32_t group_count = static_cast<uint32_t>((dispatch_count + (k_workgroup_size - 1)) / k_workgroup_size);
    if (group_count > max_workgroup_count_x) {
        return fail_result(String("gpu_compute_dispatch_too_large"), ops);
    }

    const int64_t compute_list = rd->compute_list_begin();
    rd->compute_list_bind_compute_pipeline(compute_list, acquire_result.bindings.pipeline_rid);
    rd->compute_list_bind_uniform_set(compute_list, acquire_result.bindings.uniform_set_rid, 0);
    rd->compute_list_dispatch(compute_list, std::max<uint32_t>(1, group_count), 1, 1);
    rd->compute_list_end();
    rd->submit();
    rd->sync();

    const PackedByteArray readback = rd->buffer_get_data(acquire_result.bindings.out_rid);

    bool has_region = false;
    int32_t min_x = 0;
    int32_t min_y = 0;
    int32_t min_z = 0;
    int32_t max_x = 0;
    int32_t max_y = 0;
    int32_t max_z = 0;
    std::set<ChunkKey> changed_chunks;
    Array changed_entries;

    const int64_t readable_entries = std::min<int64_t>(
        static_cast<int64_t>(dispatch_ops.size()),
        readback.size() / k_out_stride_bytes
    );

    for (int64_t i = 0; i < readable_entries; i += 1) {
        const int64_t offset = i * k_out_stride_bytes;
        const int32_t x = static_cast<int32_t>(readback.decode_s32(offset + 0));
        const int32_t y = static_cast<int32_t>(readback.decode_s32(offset + 4));
        const int32_t z = static_cast<int32_t>(readback.decode_s32(offset + 8));
        const bool changed = readback.decode_u32(offset + 12) != 0;
        const uint64_t sequence_low = static_cast<uint64_t>(readback.decode_u32(offset + 16));
        const uint64_t sequence_high = static_cast<uint64_t>(readback.decode_u32(offset + 20));
        const uint64_t sequence_id = sequence_low | (sequence_high << 32u);
        const float result_value = readback.decode_float(offset + 24);

        Dictionary changed_entry;
        changed_entry["x"] = x;
        changed_entry["y"] = y;
        changed_entry["z"] = z;
        changed_entry["changed"] = changed;
        changed_entry["sequence_id"] = static_cast<int64_t>(sequence_id);
        changed_entry["result_value"] = static_cast<double>(result_value);
        changed_entries.append(changed_entry);

        if (!changed) {
            continue;
        }

        stats.ops_changed += 1;
        if (!has_region) {
            min_x = x;
            min_y = y;
            min_z = z;
            max_x = x;
            max_y = y;
            max_z = z;
            has_region = true;
        } else {
            min_x = std::min(min_x, x);
            min_y = std::min(min_y, y);
            min_z = std::min(min_z, z);
            max_x = std::max(max_x, x);
            max_y = std::max(max_y, y);
            max_z = std::max(max_z, z);
        }
        changed_chunks.insert(ChunkKey{
            floor_div(x, chunk_size),
            floor_div(y, chunk_size),
            floor_div(z, chunk_size),
        });
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

    Array changed_chunks_array;
    for (const ChunkKey &chunk : changed_chunks) {
        changed_chunks_array.append(build_point_dict(chunk.x, chunk.y, chunk.z));
    }

    stats.changed_region = changed_region;
    stats.changed_chunks = changed_chunks_array;
    stats.changed_entries = changed_entries;

    VoxelGpuExecutionResult result;
    result.ok = true;
    result.stats = stats;
    result.deferred_ops = std::move(deferred_ops);
    return result;
}

} // namespace local_agents::simulation
