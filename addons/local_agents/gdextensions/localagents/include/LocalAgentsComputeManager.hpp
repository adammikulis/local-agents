#ifndef LOCAL_AGENTS_COMPUTE_MANAGER_HPP
#define LOCAL_AGENTS_COMPUTE_MANAGER_HPP

#include "LocalAgentsSimulationInterfaces.hpp"
#include "sim/CoreSimulationPipeline.hpp"

namespace local_agents::simulation {

class LocalAgentsComputeManager final : public IComputeManager {
public:
    bool configure(const godot::Dictionary &config) override;
    godot::Dictionary execute_step(const godot::Dictionary &scheduled_frame) override;
    void reset() override;
    godot::Dictionary get_debug_snapshot() const override;

private:
    godot::Dictionary config_;
    int64_t executed_steps_ = 0;
    CoreSimulationPipeline pipeline_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_COMPUTE_MANAGER_HPP
