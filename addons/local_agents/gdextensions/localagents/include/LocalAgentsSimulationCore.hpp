#ifndef LOCAL_AGENTS_SIMULATION_CORE_HPP
#define LOCAL_AGENTS_SIMULATION_CORE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>
#include <memory>

namespace local_agents::simulation {
class IFieldRegistry;
class IScheduler;
class IComputeManager;
class IQueryService;
class ISimProfiler;
class VoxelEditEngine;
}

namespace godot {

class LocalAgentsSimulationCore : public RefCounted {
    GDCLASS(LocalAgentsSimulationCore, RefCounted);

public:
    LocalAgentsSimulationCore();
    ~LocalAgentsSimulationCore() override;

    bool register_field(const StringName &field_name, const Dictionary &field_config = Dictionary());
    Dictionary create_field_handle(const StringName &field_name);
    Dictionary resolve_field_handle(const StringName &handle_id) const;
    Dictionary list_field_handles_snapshot() const;
    bool register_system(const StringName &system_name, const Dictionary &system_config = Dictionary());

    bool configure(const Dictionary &simulation_config = Dictionary());
    bool configure_field_registry(const Dictionary &field_registry_config = Dictionary());
    bool configure_scheduler(const Dictionary &scheduler_config = Dictionary());
    bool configure_compute_manager(const Dictionary &compute_config = Dictionary());

    Dictionary step_simulation(double delta_seconds, int64_t step_index);
    Dictionary step_structure_lifecycle(int64_t step_index);
    Dictionary enqueue_environment_voxel_edit_op(const StringName &stage_name, const Dictionary &op_payload);
    Dictionary enqueue_voxel_edit_op(const StringName &stage_name, const Dictionary &op_payload);
    Dictionary apply_environment_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
    Dictionary apply_voxel_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
    Dictionary execute_environment_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
    Dictionary execute_voxel_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
    Dictionary ingest_physics_contacts(const Array &contact_rows);
    void clear_physics_contacts();
    Dictionary get_physics_contact_snapshot() const;
    Dictionary get_debug_snapshot() const;

    void reset();

protected:
    static void _bind_methods();

private:
    std::unique_ptr<local_agents::simulation::IFieldRegistry> field_registry_;
    std::unique_ptr<local_agents::simulation::IScheduler> scheduler_;
    std::unique_ptr<local_agents::simulation::IComputeManager> compute_manager_;
    std::unique_ptr<local_agents::simulation::IQueryService> query_service_;
    std::unique_ptr<local_agents::simulation::ISimProfiler> sim_profiler_;
    std::unique_ptr<local_agents::simulation::VoxelEditEngine> voxel_edit_engine_;
    int64_t environment_stage_dispatch_count_ = 0;
    int64_t voxel_stage_dispatch_count_ = 0;
    Dictionary environment_stage_counters_;
    Dictionary voxel_stage_counters_;
    Array physics_contact_rows_;
    int64_t physics_contact_capacity_ = 256;
    int64_t physics_contact_batches_ingested_ = 0;
    int64_t physics_contact_rows_ingested_total_ = 0;
    int64_t physics_contact_rows_dropped_total_ = 0;
    double physics_contact_total_impulse_ = 0.0;
    double physics_contact_max_impulse_ = 0.0;
    double physics_contact_total_relative_speed_ = 0.0;
    double impact_signal_gain_ = 1.0e-5;
    double impact_watch_signal_threshold_ = 2.2;
    double impact_active_signal_threshold_ = 4.0;
    double impact_radius_base_ = 1.0;
    double impact_radius_gain_ = 0.5;
    double impact_radius_max_ = 12.0;
    double fracture_value_softness_ = 2.4;
    double fracture_value_cap_ = 0.95;
};

} // namespace godot

#endif // LOCAL_AGENTS_SIMULATION_CORE_HPP
