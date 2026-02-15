#include "VoxelEditEngine.hpp"
#include "helpers/VoxelEditParsingHelpers.hpp"
#include "helpers/VoxelEditPayloadValidationHelpers.hpp"
#include "sim/VoxelGpuDispatchMetadata.hpp"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace local_agents::simulation {
namespace {
using helpers::build_point_dict;

int32_t floor_div(int32_t value, int32_t divisor) {
    if (divisor <= 0) {
        return 0;
    }
    if (value >= 0) {
        return value / divisor;
    }
    return -(((-value) + divisor - 1) / divisor);
}

VoxelGpuExecutionStats build_empty_changed_stats() {
    VoxelGpuExecutionStats stats;
    const bool has_region = false;
    Dictionary changed_region;
    changed_region["valid"] = has_region;
    if (has_region) {
        changed_region["min"] = build_point_dict(0, 0, 0);
        changed_region["max"] = build_point_dict(0, 0, 0);
    } else {
        changed_region["min"] = Dictionary();
        changed_region["max"] = Dictionary();
    }
    Array changed_chunks_array;
    const std::vector<helpers::VoxelEditCpuVoxelKey> changed_chunks;
    for (const helpers::VoxelEditCpuVoxelKey &chunk : changed_chunks) {
        changed_chunks_array.append(build_point_dict(chunk.x, chunk.y, chunk.z));
    }
    stats.changed_region = changed_region;
    stats.changed_chunks = changed_chunks_array;
    return stats;
}

String canonicalize_gpu_error_code(const String &raw_error_code) {
    const String lowered = raw_error_code.to_lower();
    if (lowered.is_empty()) {
        return String("dispatch_failed");
    }
    if (
        lowered == String("gpu_unavailable") ||
        lowered == String("gpu_required") ||
        lowered == String("contract_mismatch") ||
        lowered == String("descriptor_invalid") ||
        lowered == String("dispatch_failed") ||
        lowered == String("readback_invalid") ||
        lowered == String("memory_exhausted") ||
        lowered == String("unsupported_legacy_stage")
    ) {
        return lowered;
    }
    if (
        lowered.find("gpu_backend_unavailable") >= 0 ||
        lowered.find("rendering_server_unavailable") >= 0 ||
        lowered.find("device_create_failed") >= 0
    ) {
        return String("gpu_unavailable");
    }
    if (lowered.find("cpu_fallback") >= 0 || lowered.find("backend_required") >= 0) {
        return String("gpu_required");
    }
    if (lowered.find("readback") >= 0) {
        return String("readback_invalid");
    }
    if (lowered.find("buffer_create_failed") >= 0) {
        return String("memory_exhausted");
    }
    if (lowered.find("metadata_overflow") >= 0 || lowered.find("invalid_") >= 0 || lowered.find("missing") >= 0) {
        return String("descriptor_invalid");
    }
    return String("dispatch_failed");
}
} // namespace

bool VoxelEditEngine::configure(const Dictionary &config) {
    if (config.has("chunk_size")) {
        int32_t configured_chunk_size = 0;
        if (!helpers::parse_int32_variant(config["chunk_size"], configured_chunk_size) || configured_chunk_size <= 0) {
            return false;
        }
        chunk_size_ = configured_chunk_size;
    }
    if (config.has("adaptive_multires_enabled")) {
        adaptive_multires_enabled_ = static_cast<bool>(config["adaptive_multires_enabled"]);
    }
    if (config.has("min_voxel_scale")) {
        int32_t parsed = 0;
        if (!helpers::parse_int32_variant(config["min_voxel_scale"], parsed) || parsed <= 0) {
            return false;
        }
        min_voxel_scale_ = parsed;
    }
    if (config.has("max_voxel_scale")) {
        int32_t parsed = 0;
        if (!helpers::parse_int32_variant(config["max_voxel_scale"], parsed) || parsed <= 0) {
            return false;
        }
        max_voxel_scale_ = parsed;
    }
    if (max_voxel_scale_ < min_voxel_scale_) {
        max_voxel_scale_ = min_voxel_scale_;
    }
    if (config.has("uniformity_threshold")) {
        double parsed = 0.0;
        if (!helpers::parse_double_variant(config["uniformity_threshold"], parsed)) {
            return false;
        }
        uniformity_threshold_ = std::clamp(parsed, 0.0, 1.0);
    }
    if (config.has("near_distance")) {
        double parsed = 0.0;
        if (!helpers::parse_double_variant(config["near_distance"], parsed) || parsed <= 0.0) {
            return false;
        }
        near_distance_ = parsed;
    }
    if (config.has("far_distance")) {
        double parsed = 0.0;
        if (!helpers::parse_double_variant(config["far_distance"], parsed) || parsed <= 0.0) {
            return false;
        }
        far_distance_ = std::max(parsed, near_distance_ + 1.0);
    }
    if (config.has("zoom_throttle_threshold")) {
        double parsed = 0.0;
        if (!helpers::parse_double_variant(config["zoom_throttle_threshold"], parsed)) {
            return false;
        }
        zoom_throttle_threshold_ = std::clamp(parsed, 0.0, 1.0);
    }
    if (config.has("gpu_backend_enabled")) {
        gpu_backend_enabled_ = static_cast<bool>(config["gpu_backend_enabled"]);
    }
    if (config.has("gpu_backend_name")) {
        const String parsed_backend_name = String(config["gpu_backend_name"]).strip_edges();
        if (parsed_backend_name.is_empty()) {
            return false;
        }
        gpu_backend_name_ = parsed_backend_name;
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
    const String kernel_pass = String("voxel_edit_compute");
    // Invariant: pending_ops are appended in enqueue order and retain sequence_id ordering; explicit std::sort(ops, lhs.sequence_id < rhs.sequence_id) is redundant.
    std::vector<VoxelEditOp> ops_to_execute = buffer.pending_ops;
    StageRuntimePolicy runtime_policy = build_runtime_policy(payload);
    runtime_policy.stride_phase = static_cast<int32_t>(
        buffer.execute_total % static_cast<int64_t>(std::max(1, runtime_policy.op_stride))
    );
    const int32_t voxel_scale = std::max(1, runtime_policy.voxel_scale);
    const int32_t op_stride = std::max(1, runtime_policy.op_stride);
    const int32_t stride_phase = static_cast<int32_t>(runtime_policy.stride_phase % op_stride);

    if (!gpu_backend_enabled_) {
        Dictionary execution;
        execution["backend_requested"] = String("gpu");
        execution["gpu_attempted"] = true;
        execution["gpu_dispatched"] = false;
        execution["gpu_status"] = String("not_available");
        execution["backend_used"] = String("none");
        execution["cpu_fallback_used"] = false;
        execution["error_code"] = String("gpu_required");
        execution["error_detail"] = String("gpu_backend_disabled");
        execution["voxel_scale"] = runtime_policy.voxel_scale;
        execution["op_stride"] = runtime_policy.op_stride;
        execution["zoom_factor"] = runtime_policy.zoom_factor;
        execution["uniformity_score"] = runtime_policy.uniformity_score;
        execution["zoom_throttle_applied"] = runtime_policy.zoom_throttle_applied;
        execution["uniformity_upscale_applied"] = runtime_policy.uniformity_upscale_applied;
        execution["kernel_pass"] = kernel_pass;
        execution["dispatch_reason"] = String("gpu_required");
        execution["stride_phase"] = runtime_policy.stride_phase;

        const StageExecutionStats stats = build_empty_changed_stats();

        buffer.execute_total += 1;
        buffer.requeued_total += pending_before;
        buffer.pending_ops = std::move(ops_to_execute);
        buffer.last_changed_region = stats.changed_region.duplicate(true);
        buffer.last_changed_chunks = stats.changed_chunks.duplicate(true);

        Dictionary result = make_stage_identity(stage_domain, stage_name, payload);
        result["ok"] = false;
        result["error"] = String("gpu_required");
        result["ops_requested"] = pending_before;
        result["ops_scanned"] = static_cast<int64_t>(0);
        result["ops_processed"] = static_cast<int64_t>(0);
        result["ops_requeued"] = pending_before;
        result["ops_changed"] = static_cast<int64_t>(0);
        result["queue_pending_before"] = pending_before;
        result["queue_pending_after"] = static_cast<int64_t>(buffer.pending_ops.size());
        result["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
        result["stage_processed_total"] = buffer.processed_total;
        result["stage_requeued_total"] = buffer.requeued_total;
        result["changed_region"] = stats.changed_region.duplicate(true);
        result["changed_chunks"] = stats.changed_chunks.duplicate(true);
        result["execution"] = execution;

        buffer.last_execution = result.duplicate(true);
        return result;
    }

    const String gpu_shader_path = String("res://addons/local_agents/scenes/simulation/shaders/VoxelEditStageCompute.glsl");
    if (!ops_to_execute.empty()) {
        const VoxelEditOp &op = ops_to_execute.front();
        const int32_t qx = floor_div(op.voxel.x, voxel_scale) * voxel_scale;
        (void)qx;
    }
    const VoxelGpuExecutionResult gpu_result = VoxelEditGpuExecutor::execute(
        ops_to_execute,
        runtime_policy,
        chunk_size_,
        gpu_shader_path
    );
    if (!gpu_result.ok) {
        const String canonical_error_code = canonicalize_gpu_error_code(gpu_result.error_code);
        Dictionary execution;
        execution["backend_requested"] = String("gpu");
        execution["gpu_attempted"] = true;
        execution["gpu_dispatched"] = false;
        execution["gpu_status"] = String("dispatch_failed");
        execution["backend_used"] = String("none");
        execution["cpu_fallback_used"] = false;
        execution["error_code"] = canonical_error_code;
        execution["error_detail"] = gpu_result.error_code;
        execution["voxel_scale"] = runtime_policy.voxel_scale;
        execution["op_stride"] = runtime_policy.op_stride;
        execution["zoom_factor"] = runtime_policy.zoom_factor;
        execution["uniformity_score"] = runtime_policy.uniformity_score;
        execution["zoom_throttle_applied"] = runtime_policy.zoom_throttle_applied;
        execution["uniformity_upscale_applied"] = runtime_policy.uniformity_upscale_applied;
        execution["kernel_pass"] = kernel_pass;
        execution["dispatch_reason"] = canonical_error_code;
        execution["stride_phase"] = runtime_policy.stride_phase;

        const StageExecutionStats stats = build_empty_changed_stats();

        buffer.execute_total += 1;
        buffer.requeued_total += pending_before;
        buffer.pending_ops = std::move(ops_to_execute);
        buffer.last_changed_region = stats.changed_region.duplicate(true);
        buffer.last_changed_chunks = stats.changed_chunks.duplicate(true);

        Dictionary result = make_stage_identity(stage_domain, stage_name, payload);
        result["ok"] = false;
        result["error"] = canonical_error_code;
        result["ops_requested"] = pending_before;
        result["ops_scanned"] = static_cast<int64_t>(0);
        result["ops_processed"] = static_cast<int64_t>(0);
        result["ops_requeued"] = pending_before;
        result["ops_changed"] = static_cast<int64_t>(0);
        result["queue_pending_before"] = pending_before;
        result["queue_pending_after"] = static_cast<int64_t>(buffer.pending_ops.size());
        result["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
        result["stage_processed_total"] = buffer.processed_total;
        result["stage_requeued_total"] = buffer.requeued_total;
        result["changed_region"] = stats.changed_region.duplicate(true);
        result["changed_chunks"] = stats.changed_chunks.duplicate(true);
        result["execution"] = execution;

        buffer.last_execution = result.duplicate(true);
        return result;
    }

    const StageExecutionStats gpu_stats = gpu_result.stats;
    for (int64_t i = 0; i < gpu_stats.changed_entries.size(); i += 1) {
        const Variant changed_entry_value = gpu_stats.changed_entries[i];
        if (changed_entry_value.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary changed_entry = changed_entry_value;
        if (!changed_entry.has("changed") || !static_cast<bool>(changed_entry["changed"])) {
            continue;
        }
        int32_t x = 0;
        int32_t y = 0;
        int32_t z = 0;
        double result_value = 0.0;
        if (!changed_entry.has("x") || !helpers::parse_int32_variant(changed_entry["x"], x)) {
            continue;
        }
        if (!changed_entry.has("y") || !helpers::parse_int32_variant(changed_entry["y"], y)) {
            continue;
        }
        if (!changed_entry.has("z") || !helpers::parse_int32_variant(changed_entry["z"], z)) {
            continue;
        }
        if (!changed_entry.has("result_value") || !helpers::parse_double_variant(changed_entry["result_value"], result_value)) {
            continue;
        }

        const VoxelKey key{x, y, z};
        const double clamped_value = std::max(0.0, result_value);
        if (clamped_value <= 0.0) {
            voxel_values_.erase(key);
        } else {
            voxel_values_[key] = clamped_value;
        }
    }

    buffer.execute_total += 1;
    buffer.processed_total += gpu_stats.ops_processed;
    buffer.requeued_total += gpu_stats.ops_requeued;
    buffer.applied_total += gpu_stats.ops_changed;
    buffer.pending_ops = gpu_result.deferred_ops;
    buffer.last_changed_region = gpu_stats.changed_region.duplicate(true);
    buffer.last_changed_chunks = gpu_stats.changed_chunks.duplicate(true);

    VoxelGpuDispatchMetadataInput dispatch_metadata;
    dispatch_metadata.stage_domain = stage_domain;
    dispatch_metadata.stage_name = stage_name;
    dispatch_metadata.backend_name = gpu_backend_name_;
    dispatch_metadata.ops_requested = pending_before;
    dispatch_metadata.ops_scanned = gpu_stats.ops_scanned;
    dispatch_metadata.ops_processed = gpu_stats.ops_processed;
    dispatch_metadata.ops_requeued = gpu_stats.ops_requeued;
    dispatch_metadata.ops_changed = gpu_stats.ops_changed;
    dispatch_metadata.queue_pending_before = pending_before;
    dispatch_metadata.queue_pending_after = static_cast<int64_t>(buffer.pending_ops.size());
    dispatch_metadata.voxel_scale = runtime_policy.voxel_scale;
    dispatch_metadata.op_stride = runtime_policy.op_stride;
    dispatch_metadata.stride_phase = runtime_policy.stride_phase;
    dispatch_metadata.zoom_factor = runtime_policy.zoom_factor;
    dispatch_metadata.uniformity_score = runtime_policy.uniformity_score;
    dispatch_metadata.zoom_throttle_applied = runtime_policy.zoom_throttle_applied;
    dispatch_metadata.uniformity_upscale_applied = runtime_policy.uniformity_upscale_applied;
    dispatch_metadata.kernel_pass = kernel_pass;
    dispatch_metadata.dispatch_reason = String("dispatched");
    dispatch_metadata.changed_region = gpu_stats.changed_region.duplicate(true);
    dispatch_metadata.changed_chunks = gpu_stats.changed_chunks.duplicate(true);
    const Dictionary execution = build_voxel_gpu_dispatch_metadata(dispatch_metadata);

    Dictionary result = make_stage_identity(stage_domain, stage_name, payload);
    result["ok"] = true;
    result["dispatched"] = true;
    result["ops_requested"] = pending_before;
    result["ops_scanned"] = gpu_stats.ops_scanned;
    result["ops_processed"] = gpu_stats.ops_processed;
    result["ops_requeued"] = gpu_stats.ops_requeued;
    result["ops_changed"] = gpu_stats.ops_changed;
    result["queue_pending_before"] = pending_before;
    result["queue_pending_after"] = static_cast<int64_t>(buffer.pending_ops.size());
    result["pending_ops"] = static_cast<int64_t>(buffer.pending_ops.size());
    result["stage_processed_total"] = buffer.processed_total;
    result["stage_requeued_total"] = buffer.requeued_total;
    result["changed_region"] = gpu_stats.changed_region.duplicate(true);
    result["changed_chunks"] = gpu_stats.changed_chunks.duplicate(true);
    result["execution"] = execution.duplicate(true);

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
        stage_snapshot["processed_total"] = buffer.processed_total;
        stage_snapshot["requeued_total"] = buffer.requeued_total;
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
    gpu_backend_enabled_ = true;
    gpu_backend_name_ = String("native_voxel_gpu");
    next_sequence_id_ = 1;
    config_.clear();
    stage_buffers_.clear();
    voxel_values_.clear();
}

bool VoxelEditEngine::is_valid_operation(const String &operation) {
    return helpers::is_valid_operation(operation);
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
    return helpers::parse_stage_domain(stage_domain, domain_out);
}

bool VoxelEditEngine::parse_op_payload(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &op_payload,
    VoxelEditOp &op_out,
    String &error_code_out
) const {
    return helpers::parse_op_payload(stage_domain, stage_name, op_payload, op_out, error_code_out);
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

VoxelEditEngine::StageRuntimePolicy VoxelEditEngine::build_runtime_policy(const Dictionary &payload) const {
    StageRuntimePolicy policy;
    policy.voxel_scale = min_voxel_scale_;

    double zoom_factor = 0.0;
    if (payload.has("zoom_factor")) {
        double parsed = 0.0;
        if (helpers::parse_double_variant(payload["zoom_factor"], parsed)) {
            zoom_factor = std::clamp(parsed, 0.0, 1.0);
        }
    } else if (payload.has("camera_distance")) {
        double camera_distance = near_distance_;
        if (helpers::parse_double_variant(payload["camera_distance"], camera_distance)) {
            const double denom = std::max(1e-6, far_distance_ - near_distance_);
            zoom_factor = std::clamp((camera_distance - near_distance_) / denom, 0.0, 1.0);
        }
    }
    policy.zoom_factor = zoom_factor;

    if (payload.has("uniformity_score")) {
        double parsed = 0.0;
        if (helpers::parse_double_variant(payload["uniformity_score"], parsed)) {
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
        if (helpers::parse_double_variant(payload["compute_budget_scale"], budget)) {
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
