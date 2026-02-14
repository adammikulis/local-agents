#include "sim/VoxelEditGpuExecutor.hpp"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/rd_shader_file.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>
#include <cstdint>
#include <set>
#include <tuple>
#include <vector>

using namespace godot;

namespace local_agents::simulation {
namespace {

constexpr int64_t k_workgroup_size = 64;
constexpr int64_t k_op_stride_bytes = 48;
constexpr int64_t k_out_stride_bytes = 32;
constexpr int64_t k_param_stride_bytes = 16;

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

void add_storage_uniform(const RID &buffer_rid, const int32_t binding, TypedArray<Ref<RDUniform>> &uniforms) {
    Ref<RDUniform> uniform;
    uniform.instantiate();
    uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
    uniform->set_binding(binding);
    uniform->add_id(buffer_rid);
    uniforms.append(uniform);
}

void free_if_valid(RenderingDevice *rd, RID &rid) {
    if (rd != nullptr && rid.is_valid()) {
        rd->free_rid(rid);
        rid = RID();
    }
}

VoxelGpuExecutionResult fail_result(const String &error_code, const std::vector<VoxelEditOp> &pending_ops) {
    VoxelGpuExecutionResult result;
    result.ok = false;
    result.error_code = error_code;
    result.deferred_ops = pending_ops;
    return result;
}

} // namespace

VoxelGpuExecutionResult VoxelEditGpuExecutor::execute(
    const std::vector<VoxelEditOp> &ops,
    const std::vector<float> &previous_values,
    const VoxelGpuRuntimePolicy &policy,
    const int32_t chunk_size,
    const String &shader_path
) {
    VoxelGpuExecutionStats stats;
    stats.ops_scanned = static_cast<int64_t>(ops.size());

    std::vector<VoxelEditOp> deferred_ops;
    std::vector<VoxelEditOp> dispatch_ops;
    std::vector<float> dispatch_previous_values;
    deferred_ops.reserve(ops.size());
    dispatch_ops.reserve(ops.size());
    dispatch_previous_values.reserve(ops.size());

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
        dispatch_previous_values.push_back(op_index < previous_values.size() ? previous_values[op_index] : 0.0f);
    }
    stats.ops_processed = static_cast<int64_t>(dispatch_ops.size());

    OS *os = OS::get_singleton();
    if (os != nullptr && os->has_feature(StringName("headless"))) {
        return fail_result(String("gpu_backend_unavailable"), ops);
    }

    DisplayServer *display_server = DisplayServer::get_singleton();
    if (display_server == nullptr) {
        return fail_result(String("gpu_backend_unavailable"), ops);
    }

    RenderingServer *rendering_server = RenderingServer::get_singleton();
    if (rendering_server == nullptr) {
        return fail_result(String("gpu_rendering_server_unavailable"), ops);
    }

    RenderingDevice *rd = rendering_server->create_local_rendering_device();
    if (rd == nullptr) {
        return fail_result(String("gpu_device_create_failed"), ops);
    }

    RID shader_rid;
    RID pipeline_rid;
    RID ops_rid;
    RID out_rid;
    RID params_rid;
    RID uniform_set_rid;

    const Ref<Resource> shader_resource = ResourceLoader::get_singleton()->load(shader_path, String("RDShaderFile"));
    const Ref<RDShaderFile> shader_file = shader_resource;
    if (shader_file.is_null()) {
        memdelete(rd);
        return fail_result(String("gpu_shader_load_failed"), ops);
    }

    const Ref<RDShaderSPIRV> shader_spirv = shader_file->get_spirv();
    if (shader_spirv.is_null()) {
        memdelete(rd);
        return fail_result(String("gpu_shader_spirv_missing"), ops);
    }

    shader_rid = rd->shader_create_from_spirv(shader_spirv, String("VoxelEditStageCompute"));
    if (!shader_rid.is_valid()) {
        memdelete(rd);
        return fail_result(String("gpu_shader_create_failed"), ops);
    }

    pipeline_rid = rd->compute_pipeline_create(shader_rid);
    if (!pipeline_rid.is_valid()) {
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_pipeline_create_failed"), ops);
    }

    const int64_t dispatch_count = std::max<int64_t>(1, static_cast<int64_t>(dispatch_ops.size()));

    PackedByteArray op_bytes;
    op_bytes.resize(dispatch_count * k_op_stride_bytes);
    for (int64_t i = 0; i < dispatch_count; i += 1) {
        const int64_t offset = i * k_op_stride_bytes;
        if (i >= static_cast<int64_t>(dispatch_ops.size())) {
            op_bytes.encode_s32(offset + 0, 0);
            op_bytes.encode_s32(offset + 4, 0);
            op_bytes.encode_s32(offset + 8, 0);
            op_bytes.encode_s32(offset + 12, 0);
            op_bytes.encode_u32(offset + 16, 0);
            op_bytes.encode_u32(offset + 20, 0);
            op_bytes.encode_float(offset + 24, 0.0);
            op_bytes.encode_float(offset + 28, 0.0);
            op_bytes.encode_float(offset + 32, 0.0);
            op_bytes.encode_float(offset + 36, 0.0);
            op_bytes.encode_float(offset + 40, 0.0);
            op_bytes.encode_float(offset + 44, 0.0);
            continue;
        }

        const VoxelEditOp &op = dispatch_ops[static_cast<size_t>(i)];
        op_bytes.encode_s32(offset + 0, op.voxel.x);
        op_bytes.encode_s32(offset + 4, op.voxel.y);
        op_bytes.encode_s32(offset + 8, op.voxel.z);
        op_bytes.encode_s32(offset + 12, operation_to_code(op.operation));
        op_bytes.encode_u32(offset + 16, static_cast<int64_t>(static_cast<uint32_t>(op.sequence_id & 0xffffffffULL)));
        op_bytes.encode_u32(offset + 20, static_cast<int64_t>(static_cast<uint32_t>((op.sequence_id >> 32u) & 0xffffffffULL)));
        op_bytes.encode_float(offset + 24, static_cast<float>(op.value));
        op_bytes.encode_float(offset + 28, dispatch_previous_values[static_cast<size_t>(i)]);
        op_bytes.encode_float(offset + 32, static_cast<float>(op.cleave_normal_x));
        op_bytes.encode_float(offset + 36, static_cast<float>(op.cleave_normal_y));
        op_bytes.encode_float(offset + 40, static_cast<float>(op.cleave_normal_z));
        op_bytes.encode_float(offset + 44, static_cast<float>(op.cleave_plane_offset));
    }

    PackedByteArray out_bytes;
    out_bytes.resize(dispatch_count * k_out_stride_bytes);

    PackedByteArray param_bytes;
    param_bytes.resize(k_param_stride_bytes);
    param_bytes.encode_u32(0, static_cast<int64_t>(dispatch_ops.size()));
    param_bytes.encode_s32(4, std::max(1, policy.voxel_scale));
    param_bytes.encode_s32(8, 0);
    param_bytes.encode_s32(12, 0);

    ops_rid = rd->storage_buffer_create(static_cast<uint32_t>(op_bytes.size()), op_bytes);
    out_rid = rd->storage_buffer_create(static_cast<uint32_t>(out_bytes.size()), out_bytes);
    params_rid = rd->storage_buffer_create(static_cast<uint32_t>(param_bytes.size()), param_bytes);
    if (!ops_rid.is_valid() || !out_rid.is_valid() || !params_rid.is_valid()) {
        free_if_valid(rd, params_rid);
        free_if_valid(rd, out_rid);
        free_if_valid(rd, ops_rid);
        free_if_valid(rd, pipeline_rid);
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_buffer_create_failed"), ops);
    }

    TypedArray<Ref<RDUniform>> uniforms;
    add_storage_uniform(ops_rid, 0, uniforms);
    add_storage_uniform(out_rid, 1, uniforms);
    add_storage_uniform(params_rid, 2, uniforms);
    uniform_set_rid = rd->uniform_set_create(uniforms, shader_rid, 0);
    if (!uniform_set_rid.is_valid()) {
        free_if_valid(rd, params_rid);
        free_if_valid(rd, out_rid);
        free_if_valid(rd, ops_rid);
        free_if_valid(rd, pipeline_rid);
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_uniform_set_create_failed"), ops);
    }

    const uint64_t max_workgroup_size_x = rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X);
    const uint64_t max_workgroup_invocations = rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS);
    const uint64_t max_workgroup_count_x = rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X);
    if (max_workgroup_size_x == 0 || max_workgroup_invocations == 0 || max_workgroup_count_x == 0) {
        free_if_valid(rd, uniform_set_rid);
        free_if_valid(rd, params_rid);
        free_if_valid(rd, out_rid);
        free_if_valid(rd, ops_rid);
        free_if_valid(rd, pipeline_rid);
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_compute_limits_unavailable"), ops);
    }
    if (k_workgroup_size > static_cast<int64_t>(max_workgroup_size_x) || k_workgroup_size > static_cast<int64_t>(max_workgroup_invocations)) {
        free_if_valid(rd, uniform_set_rid);
        free_if_valid(rd, params_rid);
        free_if_valid(rd, out_rid);
        free_if_valid(rd, ops_rid);
        free_if_valid(rd, pipeline_rid);
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_compute_workgroup_unsupported"), ops);
    }

    const uint32_t group_count = static_cast<uint32_t>((dispatch_count + (k_workgroup_size - 1)) / k_workgroup_size);
    if (group_count > max_workgroup_count_x) {
        free_if_valid(rd, uniform_set_rid);
        free_if_valid(rd, params_rid);
        free_if_valid(rd, out_rid);
        free_if_valid(rd, ops_rid);
        free_if_valid(rd, pipeline_rid);
        free_if_valid(rd, shader_rid);
        memdelete(rd);
        return fail_result(String("gpu_compute_dispatch_too_large"), ops);
    }

    const int64_t compute_list = rd->compute_list_begin();
    rd->compute_list_bind_compute_pipeline(compute_list, pipeline_rid);
    rd->compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0);
    rd->compute_list_dispatch(compute_list, std::max<uint32_t>(1, group_count), 1, 1);
    rd->compute_list_end();
    rd->submit();
    rd->sync();

    const PackedByteArray readback = rd->buffer_get_data(out_rid);

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

    free_if_valid(rd, uniform_set_rid);
    free_if_valid(rd, params_rid);
    free_if_valid(rd, out_rid);
    free_if_valid(rd, ops_rid);
    free_if_valid(rd, pipeline_rid);
    free_if_valid(rd, shader_rid);
    memdelete(rd);

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
