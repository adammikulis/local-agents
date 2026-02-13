#ifndef LOCAL_AGENTS_SIMULATION_CORE_HPP
#define LOCAL_AGENTS_SIMULATION_CORE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
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
}

namespace godot {

class LocalAgentsSimulationCore : public RefCounted {
    GDCLASS(LocalAgentsSimulationCore, RefCounted);

public:
    LocalAgentsSimulationCore();
    ~LocalAgentsSimulationCore() override;

    bool register_field(const StringName &field_name, const Dictionary &field_config = Dictionary());
    bool register_system(const StringName &system_name, const Dictionary &system_config = Dictionary());

    bool configure(const Dictionary &simulation_config = Dictionary());
    bool configure_field_registry(const Dictionary &field_registry_config = Dictionary());
    bool configure_scheduler(const Dictionary &scheduler_config = Dictionary());
    bool configure_compute_manager(const Dictionary &compute_config = Dictionary());

    Dictionary step_simulation(double delta_seconds, int64_t step_index);
    Dictionary step_structure_lifecycle(int64_t step_index);
    Dictionary execute_environment_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
    Dictionary execute_voxel_stage(const StringName &stage_name, const Dictionary &payload = Dictionary());
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
    int64_t environment_stage_dispatch_count_ = 0;
    int64_t voxel_stage_dispatch_count_ = 0;
    Dictionary environment_stage_counters_;
    Dictionary voxel_stage_counters_;
};

} // namespace godot

#endif // LOCAL_AGENTS_SIMULATION_CORE_HPP
