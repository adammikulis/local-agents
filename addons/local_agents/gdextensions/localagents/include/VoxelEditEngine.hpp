#ifndef VOXEL_EDIT_ENGINE_HPP
#define VOXEL_EDIT_ENGINE_HPP

#include "VoxelEditOp.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace local_agents::simulation {

class VoxelEditEngine final {
public:
    bool configure(const godot::Dictionary &config);
    godot::Dictionary enqueue_op(
        const godot::String &stage_domain,
        const godot::StringName &stage_name,
        const godot::Dictionary &op_payload
    );
    godot::Dictionary execute_stage(
        const godot::String &stage_domain,
        const godot::StringName &stage_name,
        const godot::Dictionary &payload = godot::Dictionary()
    );
    godot::Dictionary get_debug_snapshot() const;
    void reset();

private:
    struct StageBuffer {
        godot::String stage_domain;
        godot::StringName stage_name;
        std::vector<VoxelEditOp> pending_ops;
        int64_t enqueued_total = 0;
        int64_t execute_total = 0;
        int64_t applied_total = 0;
        godot::Dictionary last_changed_region;
        godot::Array last_changed_chunks;
        godot::Dictionary last_execution;
    };

    struct VoxelKey {
        int32_t x = 0;
        int32_t y = 0;
        int32_t z = 0;

        bool operator==(const VoxelKey &other) const {
            return x == other.x && y == other.y && z == other.z;
        }
    };

    struct VoxelKeyHash {
        std::size_t operator()(const VoxelKey &key) const;
    };

    struct StageExecutionStats {
        int64_t ops_processed = 0;
        int64_t ops_changed = 0;
        godot::Dictionary changed_region;
        godot::Array changed_chunks;
    };
    struct StageRuntimePolicy {
        int32_t voxel_scale = 1;
        int32_t op_stride = 1;
        double zoom_factor = 1.0;
        double uniformity_score = 0.0;
        bool zoom_throttle_applied = false;
        bool uniformity_upscale_applied = false;
    };

    static constexpr int32_t k_default_chunk_size = 16;

    static bool is_valid_operation(const godot::String &operation);
    static std::string to_stage_key(const godot::String &stage_domain, const godot::StringName &stage_name);

    static godot::Dictionary make_stage_identity(
        const godot::String &stage_domain,
        const godot::StringName &stage_name,
        const godot::Dictionary &payload
    );

    static godot::Dictionary make_error_result(
        const godot::String &stage_domain,
        const godot::StringName &stage_name,
        const godot::Dictionary &payload,
        const godot::String &error_code
    );

    bool parse_stage_domain(const godot::String &stage_domain, VoxelEditDomain &domain_out) const;
    bool parse_op_payload(
        const godot::String &stage_domain,
        const godot::StringName &stage_name,
        const godot::Dictionary &op_payload,
        VoxelEditOp &op_out,
        godot::String &error_code_out
    ) const;
    StageBuffer &ensure_stage_buffer(const godot::String &stage_domain, const godot::StringName &stage_name);
    StageExecutionStats execute_cpu_stage(
        const std::vector<VoxelEditOp> &ops,
        StageBuffer &buffer,
        const StageRuntimePolicy &policy
    );
    StageRuntimePolicy build_runtime_policy(const godot::Dictionary &payload) const;

    int32_t chunk_size_ = k_default_chunk_size;
    bool adaptive_multires_enabled_ = true;
    int32_t min_voxel_scale_ = 1;
    int32_t max_voxel_scale_ = 4;
    double uniformity_threshold_ = 0.72;
    double near_distance_ = 24.0;
    double far_distance_ = 140.0;
    double zoom_throttle_threshold_ = 0.55;
    uint64_t next_sequence_id_ = 1;
    godot::Dictionary config_;
    std::map<std::string, StageBuffer> stage_buffers_;
    std::unordered_map<VoxelKey, double, VoxelKeyHash> voxel_values_;
};

} // namespace local_agents::simulation

#endif // VOXEL_EDIT_ENGINE_HPP
