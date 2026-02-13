#include "LocalAgentsQueryService.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

Dictionary LocalAgentsQueryService::build_debug_snapshot(
    const IFieldRegistry &field_registry,
    const IScheduler &scheduler,
    const IComputeManager &compute_manager,
    const ISimProfiler &sim_profiler
) const {
    Dictionary snapshot;
    snapshot[Variant("field_registry")] = field_registry.get_debug_snapshot();
    snapshot[Variant("scheduler")] = scheduler.get_debug_snapshot();
    snapshot[Variant("compute_manager")] = compute_manager.get_debug_snapshot();
    snapshot[Variant("sim_profiler")] = sim_profiler.get_debug_snapshot();
    return snapshot;
}

} // namespace local_agents::simulation
