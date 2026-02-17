#include "sim/VoxelGpuResourceCache.hpp"

#include <godot_cpp/classes/rd_shader_file.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <vector>

using namespace godot;

namespace local_agents::simulation {
namespace {

std::atomic<bool> g_rd_api_available = true;
std::mutex g_cache_registry_mutex;
std::vector<VoxelGpuResourceCache *> g_cache_registry;

constexpr int64_t k_op_stride_bytes = 88;
constexpr int64_t k_out_stride_bytes = 56;
constexpr int64_t k_param_stride_bytes = 40;
constexpr int64_t k_value_stride_bytes = 32;
constexpr int64_t k_hash_stride_bytes = 4;

uint32_t hash_u32(uint32_t value) {
    value ^= (value >> 16U);
    value *= 0x7feb352dU;
    value ^= (value >> 15U);
    value *= 0x846ca68bU;
    value ^= (value >> 16U);
    return value;
}

uint32_t coord_hash(const int32_t x, const int32_t y, const int32_t z) {
    uint32_t value = hash_u32(static_cast<uint32_t>(x) * 73856093U);
    value = hash_u32(value ^ hash_u32(static_cast<uint32_t>(y) * 19349663U));
    value = hash_u32(value ^ hash_u32(static_cast<uint32_t>(z) * 83492791U));
    return value;
}

int64_t next_hash_capacity(const int64_t value_capacity_entries) {
    const int64_t target = std::max<int64_t>(1, value_capacity_entries * 2);
    int64_t capacity = 1;
    while (capacity < target) {
        capacity <<= 1;
    }
    return capacity;
}

int64_t normalize_hash_capacity(const int64_t hash_capacity_entries) {
    int64_t capacity = std::max<int64_t>(1, hash_capacity_entries);
    if ((capacity & (capacity - 1)) == 0) {
        return capacity;
    }
    int64_t normalized = 1;
    while (normalized < capacity) {
        normalized <<= 1;
    }
    return normalized;
}

void clear_link_fields(PackedByteArray &value_bytes, const uint32_t value_count, const int64_t value_capacity_entries) {
    const uint32_t clamped_count = std::min<uint32_t>(value_count, static_cast<uint32_t>(std::max<int64_t>(0, value_capacity_entries)));
    for (uint32_t index = 0; index < clamped_count; index += 1U) {
        const int64_t offset = static_cast<int64_t>(index) * k_value_stride_bytes;
        value_bytes.encode_u32(offset + 20, 0);
    }
}

PackedByteArray rebuild_hash_bytes(PackedByteArray &value_bytes, const uint32_t value_count, const int64_t value_capacity_entries, const int64_t hash_capacity_entries) {
    PackedByteArray hash_bytes;
    const int64_t clamped_hash_capacity = normalize_hash_capacity(hash_capacity_entries);
    hash_bytes.resize(clamped_hash_capacity * k_hash_stride_bytes);
    for (int64_t byte_index = 0; byte_index < hash_bytes.size(); byte_index += 1) {
        hash_bytes.set(byte_index, 0);
    }
    clear_link_fields(value_bytes, value_count, value_capacity_entries);

    const uint32_t clamped_count = std::min<uint32_t>(value_count, static_cast<uint32_t>(std::max<int64_t>(0, value_capacity_entries)));
    for (uint32_t index = 0; index < clamped_count; index += 1U) {
        const int64_t value_offset = static_cast<int64_t>(index) * k_value_stride_bytes;
        const uint32_t occupied = static_cast<uint32_t>(value_bytes.decode_u32(value_offset + 16));
        if (occupied == 0U) {
            continue;
        }
        const int32_t x = static_cast<int32_t>(value_bytes.decode_s32(value_offset + 0));
        const int32_t y = static_cast<int32_t>(value_bytes.decode_s32(value_offset + 4));
        const int32_t z = static_cast<int32_t>(value_bytes.decode_s32(value_offset + 8));
        const uint32_t bucket = coord_hash(x, y, z) & static_cast<uint32_t>(clamped_hash_capacity - 1);
        const int64_t bucket_offset = static_cast<int64_t>(bucket) * k_hash_stride_bytes;
        const uint32_t previous_head = static_cast<uint32_t>(hash_bytes.decode_u32(bucket_offset));
        value_bytes.encode_u32(value_offset + 20, static_cast<int64_t>(previous_head));
        hash_bytes.encode_u32(bucket_offset, static_cast<int64_t>(index + 1U));
    }
    return hash_bytes;
}

void free_if_valid(RenderingDevice *rd, RID &rid) {
    if (!rid.is_valid()) {
        return;
    }
    if (g_rd_api_available.load(std::memory_order_acquire) && rd != nullptr) {
        rd->free_rid(rid);
    }
    rid = RID();
}

void add_storage_uniform(const RID &buffer_rid, const int32_t binding, TypedArray<Ref<RDUniform>> &uniforms) {
    Ref<RDUniform> uniform;
    uniform.instantiate();
    uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
    uniform->set_binding(binding);
    uniform->add_id(buffer_rid);
    uniforms.append(uniform);
}

} // namespace

VoxelGpuResourceCache &VoxelGpuResourceCache::for_current_thread() {
    thread_local VoxelGpuResourceCache cache;
    thread_local bool registered = false;
    if (!registered) {
        std::lock_guard<std::mutex> lock(g_cache_registry_mutex);
        g_cache_registry.push_back(&cache);
        registered = true;
    }
    return cache;
}

void VoxelGpuResourceCache::release_all_thread_caches() {
    std::vector<VoxelGpuResourceCache *> caches;
    {
        std::lock_guard<std::mutex> lock(g_cache_registry_mutex);
        caches = g_cache_registry;
    }

    for (VoxelGpuResourceCache *cache : caches) {
        if (cache != nullptr) {
            cache->release();
        }
    }
}

void VoxelGpuResourceCache::mark_engine_terminating() {
    g_rd_api_available.store(false, std::memory_order_release);
}

VoxelGpuResourceAcquireResult VoxelGpuResourceCache::acquire(const String &shader_path, const int64_t dispatch_count) {
    VoxelGpuResourceAcquireResult result;

    String error_code;
    if (!ensure_device(error_code) || !ensure_shader_pipeline(shader_path, error_code) || !ensure_buffers(dispatch_count, error_code)) {
        result.ok = false;
        result.error_code = error_code;
        return result;
    }

    result.ok = true;
    result.bindings.rd = rd_;
    result.bindings.pipeline_rid = pipeline_rid_;
    result.bindings.ops_rid = ops_rid_;
    result.bindings.out_rid = out_rid_;
    result.bindings.params_rid = params_rid_;
    result.bindings.value_rid = value_rid_;
    result.bindings.value_hash_rid = value_hash_rid_;
    result.bindings.uniform_set_rid = uniform_set_rid_;
    result.bindings.value_capacity_entries = value_capacity_entries_;
    result.bindings.value_hash_capacity_entries = value_hash_capacity_entries_;
    result.bindings.max_workgroup_size_x = rd_->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X);
    result.bindings.max_workgroup_invocations = rd_->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS);
    result.bindings.max_workgroup_count_x = rd_->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X);
    return result;
}

VoxelGpuResourceCache::~VoxelGpuResourceCache() {
    release();
}

bool VoxelGpuResourceCache::ensure_device(String &error_code) {
    if (!g_rd_api_available.load(std::memory_order_acquire)) {
        error_code = String("gpu_rendering_device_unavailable");
        return false;
    }
    if (rd_ != nullptr) {
        return true;
    }

    RenderingServer *rendering_server = RenderingServer::get_singleton();
    if (rendering_server == nullptr) {
        error_code = String("gpu_rendering_server_unavailable");
        return false;
    }

    rd_ = rendering_server->create_local_rendering_device();
    owns_rd_ = rd_ != nullptr;
    if (rd_ == nullptr) {
        rd_ = rendering_server->get_rendering_device();
        owns_rd_ = false;
    }
    if (rd_ == nullptr) {
        error_code = String("gpu_rendering_device_unavailable");
        return false;
    }

    return true;
}

bool VoxelGpuResourceCache::ensure_shader_pipeline(const String &shader_path, String &error_code) {
    if (pipeline_rid_.is_valid() && shader_rid_.is_valid() && shader_path_ == shader_path) {
        return true;
    }

    free_pipeline_resources();

    const Ref<Resource> shader_resource = ResourceLoader::get_singleton()->load(shader_path, String("RDShaderFile"));
    const Ref<RDShaderFile> shader_file = shader_resource;
    if (shader_file.is_null()) {
        error_code = String("gpu_shader_load_failed");
        return false;
    }

    const Ref<RDShaderSPIRV> shader_spirv = shader_file->get_spirv();
    if (shader_spirv.is_null()) {
        error_code = String("gpu_shader_spirv_missing");
        return false;
    }

    shader_rid_ = rd_->shader_create_from_spirv(shader_spirv, String("VoxelEditStageCompute"));
    if (!shader_rid_.is_valid()) {
        error_code = String("gpu_shader_create_failed");
        return false;
    }

    pipeline_rid_ = rd_->compute_pipeline_create(shader_rid_);
    if (!pipeline_rid_.is_valid()) {
        free_if_valid(rd_, shader_rid_);
        error_code = String("gpu_pipeline_create_failed");
        return false;
    }

    shader_path_ = shader_path;
    if (ops_rid_.is_valid() && out_rid_.is_valid() && params_rid_.is_valid() && value_rid_.is_valid() && value_hash_rid_.is_valid() &&
        !rebuild_uniform_set(error_code)) {
        return false;
    }
    return true;
}

bool VoxelGpuResourceCache::ensure_buffers(const int64_t dispatch_count, String &error_code) {
    const int64_t required_count = std::max<int64_t>(1, dispatch_count);
    const int64_t required_hash_count = next_hash_capacity(required_count);
    if (ops_rid_.is_valid() && out_rid_.is_valid() && params_rid_.is_valid() && value_rid_.is_valid() && value_hash_rid_.is_valid() &&
        ops_capacity_entries_ >= required_count && out_capacity_entries_ >= required_count &&
        value_capacity_entries_ >= required_count && value_hash_capacity_entries_ >= required_hash_count) {
        return true;
    }

    PackedByteArray preserved_value_bytes;
    uint32_t preserved_value_count = 0;
    if (rd_ != nullptr && value_rid_.is_valid()) {
        preserved_value_bytes = rd_->buffer_get_data(value_rid_);
    }
    if (rd_ != nullptr && params_rid_.is_valid()) {
        const PackedByteArray existing_params = rd_->buffer_get_data(params_rid_);
        if (existing_params.size() >= 12) {
            preserved_value_count = static_cast<uint32_t>(existing_params.decode_u32(8));
        }
    }

    free_buffer_resources();

    PackedByteArray op_bytes;
    op_bytes.resize(required_count * k_op_stride_bytes);
    PackedByteArray out_bytes;
    out_bytes.resize(required_count * k_out_stride_bytes);
    PackedByteArray value_bytes;
    value_bytes.resize(required_count * k_value_stride_bytes);
    const int64_t preserved_copy_size = std::min<int64_t>(preserved_value_bytes.size(), value_bytes.size());
    for (int64_t i = 0; i < preserved_copy_size; i += 1) {
        value_bytes.set(i, preserved_value_bytes[static_cast<int32_t>(i)]);
    }
    const PackedByteArray hash_bytes = rebuild_hash_bytes(
        value_bytes,
        static_cast<uint32_t>(std::min<uint32_t>(preserved_value_count, static_cast<uint32_t>(required_count))),
        required_count,
        required_hash_count
    );

    PackedByteArray param_bytes;
    param_bytes.resize(k_param_stride_bytes);
    param_bytes.encode_u32(0, 0);
    param_bytes.encode_s32(4, 1);
    param_bytes.encode_u32(8, static_cast<int64_t>(std::min<uint32_t>(preserved_value_count, static_cast<uint32_t>(required_count))));
    param_bytes.encode_u32(12, static_cast<int64_t>(required_count));
    param_bytes.encode_u32(16, static_cast<int64_t>(required_hash_count));
    param_bytes.encode_u32(20, 0U);
    param_bytes.encode_u32(24, 0U);
    param_bytes.encode_u32(28, 0U);
    param_bytes.encode_u32(32, 0U);
    param_bytes.encode_u32(36, 0U);

    ops_rid_ = rd_->storage_buffer_create(static_cast<uint32_t>(op_bytes.size()), op_bytes);
    out_rid_ = rd_->storage_buffer_create(static_cast<uint32_t>(out_bytes.size()), out_bytes);
    params_rid_ = rd_->storage_buffer_create(static_cast<uint32_t>(param_bytes.size()), param_bytes);
    value_rid_ = rd_->storage_buffer_create(static_cast<uint32_t>(value_bytes.size()), value_bytes);
    value_hash_rid_ = rd_->storage_buffer_create(static_cast<uint32_t>(hash_bytes.size()), hash_bytes);
    if (!ops_rid_.is_valid() || !out_rid_.is_valid() || !params_rid_.is_valid() || !value_rid_.is_valid() || !value_hash_rid_.is_valid()) {
        free_buffer_resources();
        error_code = String("gpu_buffer_create_failed");
        return false;
    }

    ops_capacity_entries_ = required_count;
    out_capacity_entries_ = required_count;
    value_capacity_entries_ = required_count;
    value_hash_capacity_entries_ = required_hash_count;
    return rebuild_uniform_set(error_code);
}

bool VoxelGpuResourceCache::rebuild_uniform_set(String &error_code) {
    free_if_valid(rd_, uniform_set_rid_);

    if (!shader_rid_.is_valid() || !ops_rid_.is_valid() || !out_rid_.is_valid() || !params_rid_.is_valid() || !value_rid_.is_valid() ||
        !value_hash_rid_.is_valid()) {
        error_code = String("gpu_uniform_set_create_failed");
        return false;
    }

    TypedArray<Ref<RDUniform>> uniforms;
    add_storage_uniform(ops_rid_, 0, uniforms);
    add_storage_uniform(out_rid_, 1, uniforms);
    add_storage_uniform(params_rid_, 2, uniforms);
    add_storage_uniform(value_rid_, 3, uniforms);
    add_storage_uniform(value_hash_rid_, 4, uniforms);
    uniform_set_rid_ = rd_->uniform_set_create(uniforms, shader_rid_, 0);
    if (!uniform_set_rid_.is_valid()) {
        error_code = String("gpu_uniform_set_create_failed");
        return false;
    }

    return true;
}

void VoxelGpuResourceCache::free_pipeline_resources() {
    free_if_valid(rd_, uniform_set_rid_);
    free_if_valid(rd_, pipeline_rid_);
    free_if_valid(rd_, shader_rid_);
    shader_path_ = String();
}

void VoxelGpuResourceCache::free_buffer_resources() {
    free_if_valid(rd_, uniform_set_rid_);
    free_if_valid(rd_, params_rid_);
    free_if_valid(rd_, out_rid_);
    free_if_valid(rd_, ops_rid_);
    free_if_valid(rd_, value_rid_);
    free_if_valid(rd_, value_hash_rid_);
    ops_capacity_entries_ = 0;
    out_capacity_entries_ = 0;
    value_capacity_entries_ = 0;
    value_hash_capacity_entries_ = 0;
}

void VoxelGpuResourceCache::release() {
    if (rd_ == nullptr) {
        return;
    }

    if (!g_rd_api_available.load(std::memory_order_acquire)) {
        shader_rid_ = RID();
        pipeline_rid_ = RID();
        ops_rid_ = RID();
        out_rid_ = RID();
        params_rid_ = RID();
        value_rid_ = RID();
        value_hash_rid_ = RID();
        uniform_set_rid_ = RID();
        shader_path_ = String();
        ops_capacity_entries_ = 0;
        out_capacity_entries_ = 0;
        value_capacity_entries_ = 0;
        value_hash_capacity_entries_ = 0;
        owns_rd_ = false;
        rd_ = nullptr;
        return;
    }

    free_pipeline_resources();
    free_buffer_resources();
    if (owns_rd_) {
        memdelete(rd_);
    }
    owns_rd_ = false;
    rd_ = nullptr;
}

} // namespace local_agents::simulation
