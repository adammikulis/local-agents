#include "sim/VoxelGpuDispatchMetadata.hpp"

#include <godot_cpp/variant/variant.hpp>

#include <cstdint>

using namespace godot;

namespace local_agents::simulation {
namespace {

uint64_t fnv1a_mix_uint64(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}

uint64_t fnv1a_mix_string(uint64_t hash, const String &value) {
    CharString utf8 = value.utf8();
    const char *raw = utf8.get_data();
    if (raw == nullptr) {
        return hash;
    }
    for (int64_t i = 0; raw[i] != '\0'; i += 1) {
        hash = fnv1a_mix_uint64(hash, static_cast<uint8_t>(raw[i]));
    }
    return hash;
}

int32_t read_point_axis(const Dictionary &point, const StringName &axis) {
    if (!point.has(axis)) {
        return 0;
    }
    const Variant value = point.get(axis, Variant());
    if (value.get_type() == Variant::INT) {
        return static_cast<int32_t>(static_cast<int64_t>(value));
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int32_t>(static_cast<double>(value));
    }
    return 0;
}

uint64_t build_readback_signature(const VoxelGpuDispatchMetadataInput &input) {
    uint64_t hash = 1469598103934665603ULL;
    hash = fnv1a_mix_string(hash, input.stage_domain);
    hash = fnv1a_mix_string(hash, String(input.stage_name));
    hash = fnv1a_mix_string(hash, input.backend_name);
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.ops_requested));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.ops_scanned));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.ops_processed));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.ops_requeued));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.ops_changed));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.queue_pending_before));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.queue_pending_after));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.voxel_scale));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.op_stride));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.stride_phase));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.zoom_throttle_applied ? 1 : 0));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.uniformity_upscale_applied ? 1 : 0));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(input.changed_chunks.size()));

    const bool region_valid = static_cast<bool>(input.changed_region.get("valid", false));
    hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(region_valid ? 1 : 0));
    if (region_valid) {
        const Dictionary min_point = input.changed_region.get("min", Dictionary());
        const Dictionary max_point = input.changed_region.get("max", Dictionary());
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(min_point, StringName("x"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(min_point, StringName("y"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(min_point, StringName("z"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(max_point, StringName("x"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(max_point, StringName("y"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(max_point, StringName("z"))));
    }

    for (int64_t i = 0; i < input.changed_chunks.size(); i += 1) {
        const Variant chunk_variant = input.changed_chunks[i];
        if (chunk_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary chunk = chunk_variant;
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(chunk, StringName("x"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(chunk, StringName("y"))));
        hash = fnv1a_mix_uint64(hash, static_cast<uint64_t>(read_point_axis(chunk, StringName("z"))));
    }

    return hash;
}

} // namespace

Dictionary build_voxel_gpu_dispatch_metadata(const VoxelGpuDispatchMetadataInput &input) {
    const int64_t signature = static_cast<int64_t>(build_readback_signature(input));

    Dictionary readback;
    readback["status"] = String("ok");
    readback["deterministic_signature"] = signature;
    readback["changed_region"] = input.changed_region.duplicate(true);
    readback["changed_chunks"] = input.changed_chunks.duplicate(true);
    readback["changed_chunk_count"] = static_cast<int64_t>(input.changed_chunks.size());
    readback["ops_changed"] = input.ops_changed;
    readback["queue_pending_after"] = input.queue_pending_after;

    Dictionary execution;
    execution["backend_requested"] = String("gpu");
    execution["backend_used"] = String("gpu");
    execution["backend_name"] = input.backend_name;
    execution["stage_domain"] = input.stage_domain;
    execution["stage_name"] = String(input.stage_name);
    execution["gpu_required"] = true;
    execution["gpu_attempted"] = true;
    execution["gpu_dispatched"] = true;
    execution["gpu_status"] = String("dispatched");
    execution["cpu_fallback_used"] = false;
    execution["dispatched"] = true;
    execution["voxel_scale"] = input.voxel_scale;
    execution["op_stride"] = input.op_stride;
    execution["zoom_factor"] = input.zoom_factor;
    execution["uniformity_score"] = input.uniformity_score;
    execution["zoom_throttle_applied"] = input.zoom_throttle_applied;
    execution["uniformity_upscale_applied"] = input.uniformity_upscale_applied;
    execution["stride_phase"] = input.stride_phase;
    execution["readback"] = readback;
    return execution;
}

} // namespace local_agents::simulation
