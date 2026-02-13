#include "VoxelEditEngine.hpp"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <tuple>

using namespace godot;

namespace local_agents::simulation {
namespace {
struct ChunkKey {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;

    bool operator<(const ChunkKey &other) const {
        return std::tie(x, y, z) < std::tie(other.x, other.y, other.z);
    }
};

bool parse_int32_variant(const Variant &value, int32_t &out) {
    if (value.get_type() == Variant::INT) {
        const int64_t raw = static_cast<int64_t>(value);
        if (raw < std::numeric_limits<int32_t>::min() || raw > std::numeric_limits<int32_t>::max()) {
            return false;
        }
        out = static_cast<int32_t>(raw);
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        const double raw = static_cast<double>(value);
        if (!std::isfinite(raw)) {
            return false;
        }
        if (raw < static_cast<double>(std::numeric_limits<int32_t>::min()) ||
            raw > static_cast<double>(std::numeric_limits<int32_t>::max())) {
            return false;
        }
        out = static_cast<int32_t>(raw);
        return true;
    }
    return false;
}

bool parse_double_variant(const Variant &value, double &out) {
    if (value.get_type() == Variant::INT) {
        out = static_cast<double>(static_cast<int64_t>(value));
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        const double raw = static_cast<double>(value);
        if (!std::isfinite(raw)) {
            return false;
        }
        out = raw;
        return true;
    }
    return false;
}

Dictionary build_point_dict(int32_t x, int32_t y, int32_t z) {
    Dictionary point;
    point["x"] = x;
    point["y"] = y;
    point["z"] = z;
    return point;
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
} // namespace

std::size_t VoxelEditEngine::VoxelKeyHash::operator()(const VoxelKey &key) const {
    const uint32_t ux = static_cast<uint32_t>(key.x);
    const uint32_t uy = static_cast<uint32_t>(key.y);
    const uint32_t uz = static_cast<uint32_t>(key.z);
    std::size_t hash = ux;
    hash ^= static_cast<std::size_t>(uy) + 0x9e3779b9 + (hash << 6u) + (hash >> 2u);
    hash ^= static_cast<std::size_t>(uz) + 0x9e3779b9 + (hash << 6u) + (hash >> 2u);
    return hash;
}

bool VoxelEditEngine::configure(const Dictionary &config) {
    if (config.has("chunk_size")) {
        int32_t configured_chunk_size = 0;
        if (!parse_int32_variant(config["chunk_size"], configured_chunk_size) || configured_chunk_size <= 0) {
            return false;
        }
        chunk_size_ = configured_chunk_size;
    }
    if (config.has("adaptive_multires_enabled")) {
        adaptive_multires_enabled_ = static_cast<bool>(config["adaptive_multires_enabled"]);
    }
    if (config.has("min_voxel_scale")) {
        int32_t parsed = 0;
        if (!parse_int32_variant(config["min_voxel_scale"], parsed) || parsed <= 0) {
            return false;
        }
        min_voxel_scale_ = parsed;
    }
    if (config.has("max_voxel_scale")) {
        int32_t parsed = 0;
        if (!parse_int32_variant(config["max_voxel_scale"], parsed) || parsed <= 0) {
            return false;
        }
        max_voxel_scale_ = parsed;
    }
    if (max_voxel_scale_ < min_voxel_scale_) {
        max_voxel_scale_ = min_voxel_scale_;
    }
    if (config.has("uniformity_threshold")) {
        double parsed = 0.0;
        if (!parse_double_variant(config["uniformity_threshold"], parsed)) {
            return false;
        }
        uniformity_threshold_ = std::clamp(parsed, 0.0, 1.0);
    }
    if (config.has("near_distance")) {
        double parsed = 0.0;
        if (!parse_double_variant(config["near_distance"], parsed) || parsed <= 0.0) {
            return false;
        }
        near_distance_ = parsed;
    }
    if (config.has("far_distance")) {
        double parsed = 0.0;
        if (!parse_double_variant(config["far_distance"], parsed) || parsed <= 0.0) {
            return false;
        }
        far_distance_ = std::max(parsed, near_distance_ + 1.0);
    }
    if (config.has("zoom_throttle_threshold")) {
        double parsed = 0.0;
        if (!parse_double_variant(config["zoom_throttle_threshold"], parsed)) {
            return false;
        }
        zoom_throttle_threshold_ = std::clamp(parsed, 0.0, 1.0);
    }
    config_ = config.duplicate(true);
    return true;
}

Dictionary VoxelEditEngine::enqueue_op(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &op_payload
) {
    if (String(stage_name).is_empty()) {
        return make_error_result(stage_domain, stage_name, op_payload, String("invalid_stage_name"));
    }

    VoxelEditOp parsed_op;
    String error_code;
    if (!parse_op_payload(stage_domain, stage_name, op_payload, parsed_op, error_code)) {
        return make_error_result(stage_domain, stage_name, op_payload, error_code);
    }

    parsed_op.sequence_id = next_sequence_id_;
    next_sequence_id_ += 1;

    StageBuffer &buffer = ensure_stage_buffer(stage_domain.to_lower(), stage_name);
    buffer.pending_ops.push_back(parsed_op);
    buffer.enqueued_total += 1;

    Dictionary result = make_stage_identity(stage_domain, stage_name, op_payload);
    result["ok"] = true;
    result["sequence_id"] = static_cast<int64_t>(parsed_op.sequence_id);
    result["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
    result["stage_enqueued_total"] = buffer.enqueued_total;
    return result;
}

Dictionary VoxelEditEngine::execute_stage(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &payload
) {
    if (String(stage_name).is_empty()) {
        return make_error_result(stage_domain, stage_name, payload, String("invalid_stage_name"));
    }

    VoxelEditDomain parsed_domain = VoxelEditDomain::Voxel;
    if (!parse_stage_domain(stage_domain, parsed_domain)) {
        return make_error_result(stage_domain, stage_name, payload, String("invalid_stage_domain"));
    }

    StageBuffer &buffer = ensure_stage_buffer(stage_domain.to_lower(), stage_name);
    const int64_t pending_before = static_cast<int64_t>(buffer.pending_ops.size());
    std::vector<VoxelEditOp> ops_to_execute = buffer.pending_ops;
    buffer.pending_ops.clear();

    std::sort(
        ops_to_execute.begin(),
        ops_to_execute.end(),
        [](const VoxelEditOp &lhs, const VoxelEditOp &rhs) { return lhs.sequence_id < rhs.sequence_id; }
    );
    const StageRuntimePolicy runtime_policy = build_runtime_policy(payload);

    Dictionary execution;
    execution["backend_requested"] = String("gpu");
    execution["gpu_attempted"] = true;
    execution["gpu_dispatched"] = false;
    execution["gpu_status"] = String("not_available");
    execution["backend_used"] = String("cpu_fallback");
    execution["cpu_fallback_used"] = true;
    execution["voxel_scale"] = runtime_policy.voxel_scale;
    execution["op_stride"] = runtime_policy.op_stride;
    execution["zoom_factor"] = runtime_policy.zoom_factor;
    execution["uniformity_score"] = runtime_policy.uniformity_score;
    execution["zoom_throttle_applied"] = runtime_policy.zoom_throttle_applied;
    execution["uniformity_upscale_applied"] = runtime_policy.uniformity_upscale_applied;

    StageExecutionStats cpu_stats = execute_cpu_stage(ops_to_execute, buffer, runtime_policy);

    buffer.execute_total += 1;
    buffer.applied_total += cpu_stats.ops_changed;
    buffer.last_changed_region = cpu_stats.changed_region.duplicate(true);
    buffer.last_changed_chunks = cpu_stats.changed_chunks.duplicate(true);

    Dictionary result = make_stage_identity(stage_domain, stage_name, payload);
    result["ok"] = true;
    result["ops_requested"] = pending_before;
    result["ops_processed"] = cpu_stats.ops_processed;
    result["ops_changed"] = cpu_stats.ops_changed;
    result["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
    result["changed_region"] = cpu_stats.changed_region.duplicate(true);
    result["changed_chunks"] = cpu_stats.changed_chunks.duplicate(true);
    result["execution"] = execution;

    buffer.last_execution = result.duplicate(true);
    return result;
}

Dictionary VoxelEditEngine::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("VoxelEditEngine");
    snapshot["config"] = config_.duplicate(true);
    snapshot["chunk_size"] = chunk_size_;
    snapshot["adaptive_multires_enabled"] = adaptive_multires_enabled_;
    snapshot["min_voxel_scale"] = min_voxel_scale_;
    snapshot["max_voxel_scale"] = max_voxel_scale_;
    snapshot["uniformity_threshold"] = uniformity_threshold_;
    snapshot["near_distance"] = near_distance_;
    snapshot["far_distance"] = far_distance_;
    snapshot["zoom_throttle_threshold"] = zoom_throttle_threshold_;
    snapshot["next_sequence_id"] = static_cast<int64_t>(next_sequence_id_);
    snapshot["stored_voxel_count"] = static_cast<int64_t>(voxel_values_.size());

    Array stage_buffers;
    for (const auto &entry : stage_buffers_) {
        const StageBuffer &buffer = entry.second;
        Dictionary stage_snapshot;
        stage_snapshot["stage_domain"] = buffer.stage_domain;
        stage_snapshot["stage_name"] = buffer.stage_name;
        stage_snapshot["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
        stage_snapshot["enqueued_total"] = buffer.enqueued_total;
        stage_snapshot["execute_total"] = buffer.execute_total;
        stage_snapshot["applied_total"] = buffer.applied_total;
        stage_snapshot["last_changed_region"] = buffer.last_changed_region.duplicate(true);
        stage_snapshot["last_changed_chunks"] = buffer.last_changed_chunks.duplicate(true);
        stage_snapshot["last_execution"] = buffer.last_execution.duplicate(true);
        stage_buffers.append(stage_snapshot);
    }

    snapshot["stage_buffers"] = stage_buffers;
    return snapshot;
}

void VoxelEditEngine::reset() {
    chunk_size_ = k_default_chunk_size;
    adaptive_multires_enabled_ = true;
    min_voxel_scale_ = 1;
    max_voxel_scale_ = 4;
    uniformity_threshold_ = 0.72;
    near_distance_ = 24.0;
    far_distance_ = 140.0;
    zoom_throttle_threshold_ = 0.55;
    next_sequence_id_ = 1;
    config_.clear();
    stage_buffers_.clear();
    voxel_values_.clear();
}

bool VoxelEditEngine::is_valid_operation(const String &operation) {
    return operation == String("set") || operation == String("add") || operation == String("max") ||
           operation == String("min");
}

std::string VoxelEditEngine::to_stage_key(const String &stage_domain, const StringName &stage_name) {
    const std::string domain = std::string(stage_domain.to_lower().utf8().get_data());
    const std::string name = std::string(String(stage_name).utf8().get_data());
    return domain + ":" + name;
}

Dictionary VoxelEditEngine::make_stage_identity(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &payload
) {
    Dictionary identity;
    identity["stage_domain"] = stage_domain;
    identity["stage_name"] = stage_name;
    identity["payload"] = payload.duplicate(true);
    return identity;
}

Dictionary VoxelEditEngine::make_error_result(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &payload,
    const String &error_code
) {
    Dictionary result = make_stage_identity(stage_domain, stage_name, payload);
    result["ok"] = false;
    result["error"] = error_code;
    return result;
}

bool VoxelEditEngine::parse_stage_domain(const String &stage_domain, VoxelEditDomain &domain_out) const {
    const String normalized = stage_domain.to_lower();
    if (normalized == String("environment")) {
        domain_out = VoxelEditDomain::Environment;
        return true;
    }
    if (normalized == String("voxel")) {
        domain_out = VoxelEditDomain::Voxel;
        return true;
    }
    return false;
}

bool VoxelEditEngine::parse_op_payload(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &op_payload,
    VoxelEditOp &op_out,
    String &error_code_out
) const {
    if (String(stage_name).is_empty()) {
        error_code_out = String("invalid_stage_name");
        return false;
    }

    VoxelEditDomain parsed_domain = VoxelEditDomain::Voxel;
    if (!parse_stage_domain(stage_domain, parsed_domain)) {
        error_code_out = String("invalid_stage_domain");
        return false;
    }

    if (!op_payload.has("x") || !op_payload.has("y") || !op_payload.has("z")) {
        error_code_out = String("missing_voxel_coordinate");
        return false;
    }

    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    if (!parse_int32_variant(op_payload["x"], x) || !parse_int32_variant(op_payload["y"], y) ||
        !parse_int32_variant(op_payload["z"], z)) {
        error_code_out = String("invalid_voxel_coordinate");
        return false;
    }

    String operation = String(op_payload.get("operation", String("set"))).to_lower();
    if (!is_valid_operation(operation)) {
        error_code_out = String("invalid_operation");
        return false;
    }

    double value = 1.0;
    if (op_payload.has("value") && !parse_double_variant(op_payload["value"], value)) {
        error_code_out = String("invalid_value");
        return false;
    }

    op_out.domain = parsed_domain;
    op_out.stage_name = stage_name;
    op_out.voxel.x = x;
    op_out.voxel.y = y;
    op_out.voxel.z = z;
    op_out.operation = operation;
    op_out.value = value;
    return true;
}

VoxelEditEngine::StageBuffer &VoxelEditEngine::ensure_stage_buffer(const String &stage_domain, const StringName &stage_name) {
    const std::string key = to_stage_key(stage_domain, stage_name);
    auto found = stage_buffers_.find(key);
    if (found == stage_buffers_.end()) {
        StageBuffer created;
        created.stage_domain = stage_domain;
        created.stage_name = stage_name;
        auto inserted = stage_buffers_.emplace(key, created);
        found = inserted.first;
    }
    return found->second;
}

VoxelEditEngine::StageExecutionStats VoxelEditEngine::execute_cpu_stage(
    const std::vector<VoxelEditOp> &ops,
    StageBuffer &buffer,
    const StageRuntimePolicy &policy
) {
    StageExecutionStats stats;
    const int32_t voxel_scale = std::max(1, policy.voxel_scale);
    const int32_t op_stride = std::max(1, policy.op_stride);
    stats.ops_processed = 0;

    bool has_region = false;
    int32_t min_x = 0;
    int32_t min_y = 0;
    int32_t min_z = 0;
    int32_t max_x = 0;
    int32_t max_y = 0;
    int32_t max_z = 0;
    std::set<ChunkKey> changed_chunks;

    for (const VoxelEditOp &op : ops) {
        if (op_stride > 1) {
            if (static_cast<int32_t>(op.sequence_id % static_cast<uint64_t>(op_stride)) != 0) {
                continue;
            }
        }
        const int32_t qx = floor_div(op.voxel.x, voxel_scale) * voxel_scale;
        const int32_t qy = floor_div(op.voxel.y, voxel_scale) * voxel_scale;
        const int32_t qz = floor_div(op.voxel.z, voxel_scale) * voxel_scale;
        stats.ops_processed += 1;

        const VoxelKey voxel_key{qx, qy, qz};
        const auto voxel_iter = voxel_values_.find(voxel_key);
        const double previous_value = voxel_iter == voxel_values_.end() ? 0.0 : voxel_iter->second;

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

        if (next_value == previous_value) {
            continue;
        }

        if (next_value == 0.0) {
            voxel_values_.erase(voxel_key);
        } else {
            voxel_values_[voxel_key] = next_value;
        }

        stats.ops_changed += 1;

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
            floor_div(qx, chunk_size_),
            floor_div(qy, chunk_size_),
            floor_div(qz, chunk_size_),
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
    stats.changed_region = changed_region;

    Array changed_chunks_array;
    for (const ChunkKey &chunk : changed_chunks) {
        changed_chunks_array.append(build_point_dict(chunk.x, chunk.y, chunk.z));
    }
    stats.changed_chunks = changed_chunks_array;
    buffer.last_changed_region = changed_region.duplicate(true);
    buffer.last_changed_chunks = changed_chunks_array.duplicate(true);
    return stats;
}

VoxelEditEngine::StageRuntimePolicy VoxelEditEngine::build_runtime_policy(const Dictionary &payload) const {
    StageRuntimePolicy policy;
    policy.voxel_scale = min_voxel_scale_;

    double zoom_factor = 0.0;
    if (payload.has("zoom_factor")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["zoom_factor"], parsed)) {
            zoom_factor = std::clamp(parsed, 0.0, 1.0);
        }
    } else if (payload.has("camera_distance")) {
        double camera_distance = near_distance_;
        if (parse_double_variant(payload["camera_distance"], camera_distance)) {
            const double denom = std::max(1e-6, far_distance_ - near_distance_);
            zoom_factor = std::clamp((camera_distance - near_distance_) / denom, 0.0, 1.0);
        }
    }
    policy.zoom_factor = zoom_factor;

    if (payload.has("uniformity_score")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["uniformity_score"], parsed)) {
            policy.uniformity_score = std::clamp(parsed, 0.0, 1.0);
        }
    }

    if (adaptive_multires_enabled_) {
        const int32_t span = std::max(0, max_voxel_scale_ - min_voxel_scale_);
        int32_t zoom_scale = min_voxel_scale_;
        if (span > 0) {
            zoom_scale = min_voxel_scale_ + static_cast<int32_t>(std::llround(static_cast<double>(span) * zoom_factor));
        }
        if (zoom_scale > policy.voxel_scale) {
            policy.voxel_scale = zoom_scale;
        }
        policy.zoom_throttle_applied = zoom_factor >= zoom_throttle_threshold_;

        if (policy.uniformity_score >= uniformity_threshold_) {
            const int32_t uniform_scale = std::min(max_voxel_scale_, std::max(min_voxel_scale_, policy.voxel_scale + 1));
            if (uniform_scale > policy.voxel_scale) {
                policy.voxel_scale = uniform_scale;
                policy.uniformity_upscale_applied = true;
            }
        }
    }

    policy.op_stride = 1;
    if (payload.has("compute_budget_scale")) {
        double budget = 1.0;
        if (parse_double_variant(payload["compute_budget_scale"], budget)) {
            budget = std::clamp(budget, 0.05, 1.0);
            policy.op_stride = std::max(1, static_cast<int32_t>(std::round(1.0 / budget)));
        }
    } else if (policy.zoom_throttle_applied) {
        const double budget = std::max(0.2, 1.0 - 0.7 * zoom_factor);
        policy.op_stride = std::max(1, static_cast<int32_t>(std::round(1.0 / budget)));
    }
    policy.voxel_scale = std::clamp(policy.voxel_scale, min_voxel_scale_, max_voxel_scale_);
    return policy;
}

} // namespace local_agents::simulation
