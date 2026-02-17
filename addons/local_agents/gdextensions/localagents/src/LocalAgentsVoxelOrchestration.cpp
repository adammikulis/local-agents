#include "LocalAgentsVoxelOrchestration.hpp"

#include "helpers/SimulationCoreDictionaryHelpers.hpp"

#include <algorithm>

#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace {

constexpr int64_t kMinCadenceFrames = 1;
constexpr int64_t kDefaultCadenceFrames = 1;
constexpr int64_t kMinRowsPerTick = 1;
constexpr int64_t kDefaultRowsPerTick = 256;

int64_t clamp_positive_i64(const Variant &value, int64_t fallback, int64_t minimum = 1) {
    if (value.get_type() == Variant::INT) {
        return std::max(minimum, static_cast<int64_t>(value));
    }
    if (value.get_type() == Variant::FLOAT) {
        return std::max(minimum, static_cast<int64_t>(static_cast<double>(value)));
    }
    return std::max(minimum, fallback);
}

String non_empty_stage_name(const Variant &value, const String &fallback) {
    String stage_name = fallback;
    if (value.get_type() == Variant::STRING) {
        stage_name = String(value);
    } else if (value.get_type() == Variant::STRING_NAME) {
        stage_name = String(static_cast<StringName>(value));
    }
    stage_name = stage_name.strip_edges().to_lower();
    if (stage_name.is_empty()) {
        return fallback;
    }
    return stage_name;
}

} // namespace

namespace local_agents::simulation {

LocalAgentsVoxelOrchestration::LocalAgentsVoxelOrchestration() = default;

Dictionary LocalAgentsVoxelOrchestration::fail_result(const String &error_code, const String &error_detail) const {
    Dictionary result;
    result["ok"] = false;
    result["error"] = error_code.to_lower();
    result["error_code"] = error_code;
    result["error_detail"] = error_detail;
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::configure(const Dictionary &config) {
    cadence_frames_ = kDefaultCadenceFrames;
    max_rows_per_tick_ = kDefaultRowsPerTick;
    stage_name_ = String("voxel_transform_step");

    if (!config.is_empty()) {
        cadence_frames_ = clamp_positive_i64(
            config.get("cadence_frames", config.get("pulse_cadence_frames", kDefaultCadenceFrames)),
            kDefaultCadenceFrames,
            kMinCadenceFrames);
        max_rows_per_tick_ = clamp_positive_i64(
            config.get("max_rows_per_tick", config.get("max_contact_rows_per_tick", kDefaultRowsPerTick)),
            kDefaultRowsPerTick,
            kMinRowsPerTick);
        stage_name_ = non_empty_stage_name(config.get("stage_name", String("voxel_transform_step")), String("voxel_transform_step"));
    }

    Dictionary result;
    result["ok"] = true;
    result["config"] = get_state().get("config", Dictionary());
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::queue_projectile_contact_rows(const Array &contact_rows, int64_t frame_index) {
    if (frame_index < 0) {
        return fail_result(String("INVALID_FRAME_INDEX"), String("frame_index must be >= 0"));
    }

    queue_received_batches_ += 1;
    const Array normalized_rows = helpers::normalize_contact_rows(contact_rows);
    int64_t accepted = 0;
    for (int64_t i = 0; i < normalized_rows.size(); i++) {
        const Variant row_variant = normalized_rows[i];
        if (row_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        immediate_contact_rows_.append(static_cast<Dictionary>(row_variant).duplicate(true));
        accepted += 1;
    }
    queue_received_rows_ += accepted;

    Dictionary result;
    result["ok"] = true;
    result["accepted_rows"] = accepted;
    result["dropped_rows"] = 0;
    result["pending_count"] = static_cast<int64_t>(0);
    result["in_flight_count"] = static_cast<int64_t>(0);
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::acknowledge_projectile_contact_rows(
    int64_t consumed_count,
    bool mutation_applied,
    int64_t frame_index
) {
    if (frame_index < 0) {
        return fail_result(String("INVALID_FRAME_INDEX"), String("frame_index must be >= 0"));
    }
    if (consumed_count < 0) {
        return fail_result(String("INVALID_CONSUMED_COUNT"), String("consumed_count must be >= 0"));
    }

    queue_acknowledged_rows_ += consumed_count;
    queue_consumed_rows_ += consumed_count;

    Dictionary result;
    result["ok"] = true;
    result["consumed_count"] = consumed_count;
    result["mutation_applied"] = mutation_applied;
    result["requeued_count"] = static_cast<int64_t>(0);
    result["deadline_exceeded_count"] = static_cast<int64_t>(0);
    result["deadline_exceeded_rows"] = Array();
    result["pending_count"] = static_cast<int64_t>(0);
    result["in_flight_count"] = static_cast<int64_t>(0);
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::execute_tick_decision(
    int64_t tick,
    double delta_seconds,
    int64_t frame_index,
    const Dictionary &frame_context
) {
    if (frame_index < 0) {
        return fail_result(String("INVALID_FRAME_INDEX"), String("frame_index must be >= 0"));
    }

    ticks_total_ += 1;
    last_tick_frame_index_ = frame_index;

    const bool has_contact_rows = !immediate_contact_rows_.is_empty();
    const bool cadence_ready =
        last_dispatch_frame_index_ < 0 ||
        (frame_index - last_dispatch_frame_index_) >= std::max<int64_t>(1, cadence_frames_);
    const bool should_dispatch = has_contact_rows || cadence_ready;

    String dispatch_reason;
    if (has_contact_rows) {
        dispatch_reason = String("immediate_contact_rows");
    } else if (should_dispatch) {
        dispatch_reason = String("cadence_pulse");
    } else {
        dispatch_reason = String("cadence_wait");
        ticks_skipped_cadence_ += 1;
    }

    if (should_dispatch) {
        ticks_dispatched_ += 1;
        last_dispatch_frame_index_ = frame_index;
        last_dispatch_tick_ = tick;
        last_dispatch_reason_ = dispatch_reason;
    }

    Dictionary frame_payload;
    const Variant payload_variant = frame_context.get("payload", Dictionary());
    if (payload_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary payload_dictionary = payload_variant;
        frame_payload = payload_dictionary.duplicate(true);
    } else {
        frame_payload = frame_context.duplicate(true);
    }
    frame_payload.erase("stage_name");
    frame_payload["tick"] = tick;
    frame_payload["delta"] = delta_seconds;

    Array dispatch_rows;
    if (should_dispatch && has_contact_rows) {
        dispatch_rows = immediate_contact_rows_.duplicate(true);
        if (max_rows_per_tick_ > 0 && dispatch_rows.size() > max_rows_per_tick_) {
            dispatch_rows.resize(max_rows_per_tick_);
        }
    }

    immediate_contact_rows_.clear();

    Dictionary deadline_report;
    deadline_report["ok"] = true;
    deadline_report["deadline_exceeded_count"] = static_cast<int64_t>(0);
    deadline_report["deadline_exceeded_rows"] = Array();

    Dictionary result;
    result["ok"] = true;
    result["tick"] = tick;
    result["delta_seconds"] = delta_seconds;
    result["frame_index"] = frame_index;
    result["should_dispatch"] = should_dispatch;
    result["frame_payload"] = frame_payload;
    result["dispatch_contact_rows"] = dispatch_rows;
    result["consumed_count"] = static_cast<int64_t>(dispatch_rows.size());
    result["pending_count"] = static_cast<int64_t>(0);
    result["in_flight_count"] = static_cast<int64_t>(0);
    result["queue_depth"] = static_cast<int64_t>(0);
    result["deadline_report"] = deadline_report;
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::get_state() const {
    Dictionary config;
    config["stage_name"] = stage_name_;
    config["cadence_frames"] = cadence_frames_;
    config["max_rows_per_tick"] = max_rows_per_tick_;
    config["max_queue_rows"] = static_cast<int64_t>(0);
    config["default_deadline_frames"] = static_cast<int64_t>(0);
    config["force_dispatch_on_queue"] = false;

    Dictionary state;
    state["config"] = config;
    state["pending_count"] = static_cast<int64_t>(0);
    state["in_flight_count"] = static_cast<int64_t>(0);
    state["queue_depth"] = static_cast<int64_t>(0);
    state["last_tick_frame_index"] = last_tick_frame_index_;
    state["last_dispatch_frame_index"] = last_dispatch_frame_index_;
    state["last_dispatch_tick"] = last_dispatch_tick_;
    state["last_dispatch_reason"] = last_dispatch_reason_;
    state["last_error_code"] = last_error_code_;
    return state;
}

Dictionary LocalAgentsVoxelOrchestration::get_metrics() const {
    Dictionary metrics;
    metrics["ticks_total"] = ticks_total_;
    metrics["ticks_dispatched"] = ticks_dispatched_;
    metrics["ticks_skipped_cadence"] = ticks_skipped_cadence_;
    metrics["ticks_forced_contact_flush"] = static_cast<int64_t>(0);
    metrics["queue_received_batches"] = queue_received_batches_;
    metrics["queue_received_rows"] = queue_received_rows_;
    metrics["queue_dropped_rows"] = static_cast<int64_t>(0);
    metrics["queue_acknowledged_rows"] = queue_acknowledged_rows_;
    metrics["queue_consumed_rows"] = queue_consumed_rows_;
    metrics["queue_requeued_rows"] = static_cast<int64_t>(0);
    metrics["deadline_exceeded_rows"] = static_cast<int64_t>(0);
    return metrics;
}

void LocalAgentsVoxelOrchestration::reset() {
    immediate_contact_rows_.clear();
    ticks_total_ = 0;
    ticks_dispatched_ = 0;
    ticks_skipped_cadence_ = 0;
    queue_received_batches_ = 0;
    queue_received_rows_ = 0;
    queue_acknowledged_rows_ = 0;
    queue_consumed_rows_ = 0;
    last_tick_frame_index_ = -1;
    last_dispatch_frame_index_ = -1;
    last_dispatch_tick_ = -1;
    last_dispatch_reason_ = String();
    last_error_code_ = String();
}

} // namespace local_agents::simulation
