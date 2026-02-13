#ifndef LOCAL_AGENTS_QUERY_SERVICE_HPP
#define LOCAL_AGENTS_QUERY_SERVICE_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

namespace local_agents::simulation {

class LocalAgentsQueryService final : public IQueryService {
public:
    godot::Dictionary build_debug_snapshot(
        const IFieldRegistry &field_registry,
        const IScheduler &scheduler,
        const IComputeManager &compute_manager,
        const ISimProfiler &sim_profiler
    ) const override;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_QUERY_SERVICE_HPP
