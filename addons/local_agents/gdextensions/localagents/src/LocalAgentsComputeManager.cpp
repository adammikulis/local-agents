#include "LocalAgentsComputeManager.hpp"

using namespace godot;

namespace local_agents::simulation {

bool LocalAgentsComputeManager::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    const Dictionary pipeline_config = config.get("pipeline", Dictionary());
    pipeline_.configure(pipeline_config);
    return true;
}

Dictionary LocalAgentsComputeManager::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

    Dictionary result;
    result["ok"] = true;
    result["executed_steps"] = executed_steps_;
    result["scheduled_frame"] = scheduled_frame.duplicate(true);
    result["pipeline"] = pipeline_.execute_step(scheduled_frame);
    return result;
}

void LocalAgentsComputeManager::reset() {
    config_.clear();
    executed_steps_ = 0;
    pipeline_.reset();
}

Dictionary LocalAgentsComputeManager::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("ComputeManager");
    snapshot["config"] = config_.duplicate(true);
    snapshot["executed_steps"] = executed_steps_;
    snapshot["pipeline"] = pipeline_.get_debug_snapshot();
    return snapshot;
}

} // namespace local_agents::simulation
