#ifndef LOCAL_AGENTS_SIM_PROFILER_HPP
#define LOCAL_AGENTS_SIM_PROFILER_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

namespace local_agents::simulation {

class LocalAgentsSimProfiler final : public ISimProfiler {
public:
    void begin_step(int64_t step_index, double delta_seconds) override;
    void end_step(int64_t step_index, double delta_seconds, const godot::Dictionary &step_result) override;
    void reset() override;
    godot::Dictionary get_debug_snapshot() const override;

private:
    int64_t total_steps_ = 0;
    int64_t last_step_index_ = -1;
    double last_delta_seconds_ = 0.0;
    godot::Dictionary last_step_result_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_SIM_PROFILER_HPP
