#ifndef LOCAL_AGENTS_VOXEL_GPU_RESOURCE_CACHE_HPP
#define LOCAL_AGENTS_VOXEL_GPU_RESOURCE_CACHE_HPP

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace local_agents::simulation {

struct VoxelGpuResourceBindings {
    godot::RenderingDevice *rd = nullptr;
    godot::RID pipeline_rid;
    godot::RID ops_rid;
    godot::RID out_rid;
    godot::RID params_rid;
    godot::RID value_rid;
    godot::RID value_hash_rid;
    godot::RID uniform_set_rid;
    int64_t value_capacity_entries = 0;
    int64_t value_hash_capacity_entries = 0;
    uint64_t max_workgroup_size_x = 0;
    uint64_t max_workgroup_invocations = 0;
    uint64_t max_workgroup_count_x = 0;
};

struct VoxelGpuResourceAcquireResult {
    bool ok = false;
    godot::String error_code;
    VoxelGpuResourceBindings bindings;
};

class VoxelGpuResourceCache final {
public:
    static VoxelGpuResourceCache &for_current_thread();
    static void release_all_thread_caches();
    static void mark_engine_terminating();

    VoxelGpuResourceAcquireResult acquire(const godot::String &shader_path, int64_t dispatch_count);

    ~VoxelGpuResourceCache();

private:
    VoxelGpuResourceCache() = default;
    VoxelGpuResourceCache(const VoxelGpuResourceCache &) = delete;
    VoxelGpuResourceCache &operator=(const VoxelGpuResourceCache &) = delete;

    bool ensure_device(godot::String &error_code);
    bool ensure_shader_pipeline(const godot::String &shader_path, godot::String &error_code);
    bool ensure_buffers(int64_t dispatch_count, godot::String &error_code);
    bool rebuild_uniform_set(godot::String &error_code);

    void free_pipeline_resources();
    void free_buffer_resources();
    void release();

    godot::RenderingDevice *rd_ = nullptr;
    godot::String shader_path_;

    godot::RID shader_rid_;
    godot::RID pipeline_rid_;
    godot::RID ops_rid_;
    godot::RID out_rid_;
    godot::RID params_rid_;
    godot::RID value_rid_;
    godot::RID value_hash_rid_;
    godot::RID uniform_set_rid_;

    bool owns_rd_ = false;
    int64_t ops_capacity_entries_ = 0;
    int64_t out_capacity_entries_ = 0;
    int64_t value_capacity_entries_ = 0;
    int64_t value_hash_capacity_entries_ = 0;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_VOXEL_GPU_RESOURCE_CACHE_HPP
