#ifndef LOCAL_AGENTS_VOXEL_ORCHESTRATION_HPP
#define LOCAL_AGENTS_VOXEL_ORCHESTRATION_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <deque>

namespace local_agents::simulation {

class LocalAgentsVoxelOrchestration {
public:
    LocalAgentsVoxelOrchestration();

    godot::Dictionary configure(const godot::Dictionary &config);
    godot::Dictionary queue_projectile_contact_rows(const godot::Array &contact_rows, int64_t frame_index);
    godot::Dictionary acknowledge_projectile_contact_rows(
        int64_t consumed_count,
        bool mutation_applied,
        int64_t frame_index
    );
    godot::Dictionary execute_tick_decision(
        int64_t tick,
        double delta_seconds,
        int64_t frame_index,
        const godot::Dictionary &frame_context
    );

    godot::Dictionary get_state() const;
    godot::Dictionary get_metrics() const;
    void reset();

private:
public:
    struct QueuedContactRow {
        godot::Dictionary row;
        int64_t enqueued_frame = 0;
        int64_t source_frame = 0;
        int64_t deadline_frame = 0;
    };

private:
    godot::Dictionary fail_result(const godot::String &error_code, const godot::String &error_detail) const;
    int64_t read_row_deadline_frame(const godot::Dictionary &row, int64_t frame_index) const;
    godot::Dictionary flush_deadline_exceeded_rows(int64_t frame_index);

    int64_t cadence_frames_ = 1;
    int64_t max_rows_per_tick_ = 256;
    int64_t max_queue_rows_ = 2048;
    int64_t default_deadline_frames_ = 8;
    bool force_dispatch_on_queue_ = true;
    godot::String stage_name_ = godot::String("voxel_transform_step");

    std::deque<QueuedContactRow> pending_rows_;
    std::deque<QueuedContactRow> in_flight_rows_;

    int64_t ticks_total_ = 0;
    int64_t ticks_dispatched_ = 0;
    int64_t ticks_skipped_cadence_ = 0;
    int64_t ticks_forced_contact_flush_ = 0;
    int64_t queue_received_batches_ = 0;
    int64_t queue_received_rows_ = 0;
    int64_t queue_dropped_rows_ = 0;
    int64_t queue_acknowledged_rows_ = 0;
    int64_t queue_consumed_rows_ = 0;
    int64_t queue_requeued_rows_ = 0;
    int64_t deadline_exceeded_rows_ = 0;

    int64_t last_tick_frame_index_ = -1;
    int64_t last_dispatch_frame_index_ = -1;
    int64_t last_dispatch_tick_ = -1;
    godot::String last_dispatch_reason_;
    godot::String last_error_code_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_VOXEL_ORCHESTRATION_HPP
