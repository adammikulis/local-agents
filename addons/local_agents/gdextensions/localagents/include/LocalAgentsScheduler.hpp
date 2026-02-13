#ifndef LOCAL_AGENTS_SCHEDULER_HPP
#define LOCAL_AGENTS_SCHEDULER_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

#include <godot_cpp/variant/array.hpp>

namespace local_agents::simulation {

class LocalAgentsScheduler final : public IScheduler {
public:
    bool register_system(const godot::StringName &system_name, const godot::Dictionary &system_config) override;
    bool configure(const godot::Dictionary &config) override;
    godot::Dictionary step(double delta_seconds, int64_t step_index) override;
    void reset() override;
    godot::Dictionary get_debug_snapshot() const override;

private:
    godot::Dictionary config_;
    godot::Dictionary system_configs_;
    godot::Array registration_order_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_SCHEDULER_HPP
