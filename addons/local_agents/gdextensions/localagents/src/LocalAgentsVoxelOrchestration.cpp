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
constexpr int64_t kDefaultQueueCapacity = 2048;
constexpr int64_t kDefaultDeadlineFrames = 8;
constexpr int64_t kDeadlineSummaryCap = 32;
constexpr const char *kDeadlineExceededCode = "PROJECTILE_MUTATION_DEADLINE_EXCEEDED";

int64_t clamp_positive_i64(const Variant &value, int64_t fallback, int64_t minimum = 1) {
    if (value.get_type() == Variant::INT) {
        return std::max(minimum, static_cast<int64_t>(value));
    }
    if (value.get_type() == Variant::FLOAT) {
        return std::max(minimum, static_cast<int64_t>(static_cast<double>(value)));
    }
    return std::max(minimum, fallback);
}

bool to_bool(const Variant &value, bool fallback) {
    if (value.get_type() == Variant::BOOL) {
        return static_cast<bool>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value) != 0;
    }
    return fallback;
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

Dictionary summarize_deadline_row(const local_agents::simulation::LocalAgentsVoxelOrchestration::QueuedContactRow &row) {
    Dictionary summary;
    summary["frame"] = row.source_frame;
    summary["deadline_frame"] = row.deadline_frame;
    summary["enqueued_frame"] = row.enqueued_frame;
    if (row.row.has("projectile_id")) {
        summary["projectile_id"] = row.row.get("projectile_id", Variant());
    }
    if (row.row.has("body_id")) {
        summary["body_id"] = row.row.get("body_id", Variant());
    }
    return summary;
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

int64_t LocalAgentsVoxelOrchestration::read_row_deadline_frame(const Dictionary &row, int64_t frame_index) const {
    if (row.has("deadline_frame")) {
        const Variant deadline_variant = row.get("deadline_frame", Variant());
        if (deadline_variant.get_type() == Variant::INT) {
            return static_cast<int64_t>(deadline_variant);
        }
        if (deadline_variant.get_type() == Variant::FLOAT) {
            return static_cast<int64_t>(static_cast<double>(deadline_variant));
        }
    }
    return frame_index + std::max<int64_t>(1, default_deadline_frames_);
}

Dictionary LocalAgentsVoxelOrchestration::configure(const Dictionary &config) {
    cadence_frames_ = kDefaultCadenceFrames;
    max_rows_per_tick_ = kDefaultRowsPerTick;
    max_queue_rows_ = kDefaultQueueCapacity;
    default_deadline_frames_ = kDefaultDeadlineFrames;
    force_dispatch_on_queue_ = true;
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
        max_queue_rows_ = clamp_positive_i64(
            config.get("max_queue_rows", config.get("queue_capacity", kDefaultQueueCapacity)),
            kDefaultQueueCapacity,
            kMinRowsPerTick);
        default_deadline_frames_ = clamp_positive_i64(
            config.get("default_deadline_frames", config.get("mutation_deadline_frames", kDefaultDeadlineFrames)),
            kDefaultDeadlineFrames,
            kMinCadenceFrames);
        force_dispatch_on_queue_ = to_bool(config.get("force_dispatch_on_queue", true), true);
        stage_name_ = non_empty_stage_name(config.get("stage_name", String("voxel_transform_step")), String("voxel_transform_step"));
    }

    Dictionary result;
    result["ok"] = true;
    result["config"] = get_state().get("config", Dictionary());
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::flush_deadline_exceeded_rows(int64_t frame_index) {
    Dictionary report;
    Array exceeded_summaries;
    int64_t exceeded_count = 0;

    std::deque<QueuedContactRow> pending_next;
    while (!pending_rows_.empty()) {
        const QueuedContactRow row = pending_rows_.front();
        pending_rows_.pop_front();
        if (frame_index > row.deadline_frame) {
            exceeded_count += 1;
            if (exceeded_summaries.size() < kDeadlineSummaryCap) {
                exceeded_summaries.append(summarize_deadline_row(row));
            }
            continue;
        }
        pending_next.push_back(row);
    }
    pending_rows_ = std::move(pending_next);

    std::deque<QueuedContactRow> in_flight_next;
    while (!in_flight_rows_.empty()) {
        const QueuedContactRow row = in_flight_rows_.front();
        in_flight_rows_.pop_front();
        if (frame_index > row.deadline_frame) {
            exceeded_count += 1;
            if (exceeded_summaries.size() < kDeadlineSummaryCap) {
                exceeded_summaries.append(summarize_deadline_row(row));
            }
            continue;
        }
        in_flight_next.push_back(row);
    }
    in_flight_rows_ = std::move(in_flight_next);

    if (exceeded_count > 0) {
        deadline_exceeded_rows_ += exceeded_count;
        last_error_code_ = String(kDeadlineExceededCode);
    }

    report["ok"] = exceeded_count == 0;
    report["deadline_exceeded_count"] = exceeded_count;
    report["deadline_exceeded_rows"] = exceeded_summaries;
    if (exceeded_count > 0) {
        report["error"] = String("projectile_mutation_deadline_exceeded");
        report["error_code"] = String(kDeadlineExceededCode);
    }
    return report;
}

Dictionary LocalAgentsVoxelOrchestration::queue_projectile_contact_rows(const Array &contact_rows, int64_t frame_index) {
    if (frame_index < 0) {
        return fail_result(String("INVALID_FRAME_INDEX"), String("frame_index must be >= 0"));
    }

    queue_received_batches_ += 1;
    const Array normalized_rows = helpers::normalize_contact_rows(contact_rows);
    int64_t accepted = 0;
    int64_t dropped = 0;

    for (int64_t i = 0; i < normalized_rows.size(); i++) {
        const Variant normalized_variant = normalized_rows[i];
        if (normalized_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        if (static_cast<int64_t>(pending_rows_.size() + in_flight_rows_.size()) >= max_queue_rows_) {
            dropped += 1;
            queue_dropped_rows_ += 1;
            continue;
        }

        const Dictionary normalized_row = normalized_variant;
        QueuedContactRow queued;
        queued.row = normalized_row;
        queued.enqueued_frame = frame_index;
        queued.source_frame = static_cast<int64_t>(normalized_row.get("frame", frame_index));
        queued.deadline_frame = std::max(frame_index, read_row_deadline_frame(normalized_row, frame_index));
        pending_rows_.push_back(queued);
        accepted += 1;
        queue_received_rows_ += 1;
    }

    Dictionary result;
    result["ok"] = true;
    result["accepted_rows"] = accepted;
    result["dropped_rows"] = dropped;
    result["pending_count"] = static_cast<int64_t>(pending_rows_.size());
    result["in_flight_count"] = static_cast<int64_t>(in_flight_rows_.size());
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
    if (consumed_count == 0) {
        Dictionary noop;
        noop["ok"] = true;
        noop["pending_count"] = static_cast<int64_t>(pending_rows_.size());
        noop["in_flight_count"] = static_cast<int64_t>(in_flight_rows_.size());
        return noop;
    }
    if (in_flight_rows_.empty()) {
        return fail_result(String("ORCHESTRATION_ACK_WITHOUT_IN_FLIGHT"), String("no in-flight contact rows to acknowledge"));
    }
    if (consumed_count > static_cast<int64_t>(in_flight_rows_.size())) {
        return fail_result(String("ORCHESTRATION_ACK_CONSUMED_COUNT_INVALID"), String("consumed_count exceeds in-flight queue depth"));
    }

    queue_acknowledged_rows_ += consumed_count;

    std::deque<QueuedContactRow> consumed_rows;
    for (int64_t i = 0; i < consumed_count; i++) {
        consumed_rows.push_back(in_flight_rows_.front());
        in_flight_rows_.pop_front();
    }

    int64_t requeued_count = 0;
    int64_t deadline_exceeded_count = 0;
    Array deadline_exceeded_rows;

    if (mutation_applied) {
        queue_consumed_rows_ += consumed_count;
    } else {
        std::deque<QueuedContactRow> to_requeue;
        while (!consumed_rows.empty()) {
            const QueuedContactRow row = consumed_rows.front();
            consumed_rows.pop_front();
            if (frame_index > row.deadline_frame) {
                deadline_exceeded_count += 1;
                if (deadline_exceeded_rows.size() < kDeadlineSummaryCap) {
                    deadline_exceeded_rows.append(summarize_deadline_row(row));
                }
                continue;
            }
            to_requeue.push_back(row);
        }
        while (!to_requeue.empty()) {
            pending_rows_.push_front(to_requeue.back());
            to_requeue.pop_back();
            requeued_count += 1;
        }
        queue_requeued_rows_ += requeued_count;
        queue_consumed_rows_ += (consumed_count - requeued_count);
    }

    if (deadline_exceeded_count > 0) {
        deadline_exceeded_rows_ += deadline_exceeded_count;
        last_error_code_ = String(kDeadlineExceededCode);
    }

    Dictionary result;
    result["ok"] = deadline_exceeded_count == 0;
    result["consumed_count"] = consumed_count;
    result["mutation_applied"] = mutation_applied;
    result["requeued_count"] = requeued_count;
    result["deadline_exceeded_count"] = deadline_exceeded_count;
    result["deadline_exceeded_rows"] = deadline_exceeded_rows;
    result["pending_count"] = static_cast<int64_t>(pending_rows_.size());
    result["in_flight_count"] = static_cast<int64_t>(in_flight_rows_.size());
    if (deadline_exceeded_count > 0) {
        result["error"] = String("projectile_mutation_deadline_exceeded");
        result["error_code"] = String(kDeadlineExceededCode);
    }
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

    const Dictionary deadline_report = flush_deadline_exceeded_rows(frame_index);
    const bool has_deadline_failure = !bool(deadline_report.get("ok", true));

    const bool has_queue_rows = !pending_rows_.empty() || !in_flight_rows_.empty();
    const bool cadence_ready =
        last_dispatch_frame_index_ < 0 ||
        (frame_index - last_dispatch_frame_index_) >= std::max<int64_t>(1, cadence_frames_);
    const bool queue_forces_dispatch = force_dispatch_on_queue_ && has_queue_rows;
    const bool should_dispatch = cadence_ready || queue_forces_dispatch;

    String dispatch_reason;
    if (!should_dispatch) {
        dispatch_reason = String("cadence_wait");
        ticks_skipped_cadence_ += 1;
    } else if (queue_forces_dispatch && !cadence_ready) {
        dispatch_reason = String("queue_contact_flush");
        ticks_forced_contact_flush_ += 1;
    } else if (has_queue_rows) {
        dispatch_reason = String("cadence_and_queue");
    } else {
        dispatch_reason = String("cadence_pulse");
    }

    if (should_dispatch) {
        if (in_flight_rows_.empty() && !pending_rows_.empty()) {
            const int64_t move_count = std::min<int64_t>(max_rows_per_tick_, static_cast<int64_t>(pending_rows_.size()));
            for (int64_t i = 0; i < move_count; i++) {
                in_flight_rows_.push_back(pending_rows_.front());
                pending_rows_.pop_front();
            }
        }
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
        frame_payload.erase("stage_name");
    }
    frame_payload["tick"] = tick;
    frame_payload["delta"] = delta_seconds;

    const String resolved_stage_name = non_empty_stage_name(frame_context.get("stage_name", stage_name_), stage_name_);

    Array dispatch_rows;
    dispatch_rows.resize(static_cast<int64_t>(in_flight_rows_.size()));
    for (int64_t i = 0; i < static_cast<int64_t>(in_flight_rows_.size()); i++) {
        dispatch_rows[i] = in_flight_rows_[i].row.duplicate(true);
    }

    Dictionary result;
    result["ok"] = !has_deadline_failure;
    result["tick"] = tick;
    result["delta_seconds"] = delta_seconds;
    result["frame_index"] = frame_index;
    result["should_dispatch"] = should_dispatch;
    result["cadence_ready"] = cadence_ready;
    result["queue_forces_dispatch"] = queue_forces_dispatch;
    result["dispatch_reason"] = dispatch_reason;
    result["stage_name"] = resolved_stage_name;
    result["frame_payload"] = frame_payload;
    result["dispatch_contact_rows"] = dispatch_rows;
    result["consumed_count"] = static_cast<int64_t>(dispatch_rows.size());
    result["pending_count"] = static_cast<int64_t>(pending_rows_.size());
    result["in_flight_count"] = static_cast<int64_t>(in_flight_rows_.size());
    result["queue_depth"] = static_cast<int64_t>(pending_rows_.size() + in_flight_rows_.size());
    result["deadline_report"] = deadline_report;
    if (has_deadline_failure) {
        result["error"] = deadline_report.get("error", String("projectile_mutation_deadline_exceeded"));
        result["error_code"] = deadline_report.get("error_code", String(kDeadlineExceededCode));
    }
    return result;
}

Dictionary LocalAgentsVoxelOrchestration::get_state() const {
    Dictionary config;
    config["stage_name"] = stage_name_;
    config["cadence_frames"] = cadence_frames_;
    config["max_rows_per_tick"] = max_rows_per_tick_;
    config["max_queue_rows"] = max_queue_rows_;
    config["default_deadline_frames"] = default_deadline_frames_;
    config["force_dispatch_on_queue"] = force_dispatch_on_queue_;

    Dictionary state;
    state["config"] = config;
    state["pending_count"] = static_cast<int64_t>(pending_rows_.size());
    state["in_flight_count"] = static_cast<int64_t>(in_flight_rows_.size());
    state["queue_depth"] = static_cast<int64_t>(pending_rows_.size() + in_flight_rows_.size());
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
    metrics["ticks_forced_contact_flush"] = ticks_forced_contact_flush_;
    metrics["queue_received_batches"] = queue_received_batches_;
    metrics["queue_received_rows"] = queue_received_rows_;
    metrics["queue_dropped_rows"] = queue_dropped_rows_;
    metrics["queue_acknowledged_rows"] = queue_acknowledged_rows_;
    metrics["queue_consumed_rows"] = queue_consumed_rows_;
    metrics["queue_requeued_rows"] = queue_requeued_rows_;
    metrics["deadline_exceeded_rows"] = deadline_exceeded_rows_;
    return metrics;
}

void LocalAgentsVoxelOrchestration::reset() {
    pending_rows_.clear();
    in_flight_rows_.clear();
    ticks_total_ = 0;
    ticks_dispatched_ = 0;
    ticks_skipped_cadence_ = 0;
    ticks_forced_contact_flush_ = 0;
    queue_received_batches_ = 0;
    queue_received_rows_ = 0;
    queue_dropped_rows_ = 0;
    queue_acknowledged_rows_ = 0;
    queue_consumed_rows_ = 0;
    queue_requeued_rows_ = 0;
    deadline_exceeded_rows_ = 0;
    last_tick_frame_index_ = -1;
    last_dispatch_frame_index_ = -1;
    last_dispatch_tick_ = -1;
    last_dispatch_reason_ = String();
    last_error_code_ = String();
}

} // namespace local_agents::simulation
