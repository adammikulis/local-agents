#include "LocalAgentsSimProfiler.hpp"

using namespace godot;

namespace local_agents::simulation {

void LocalAgentsSimProfiler::begin_step(int64_t step_index, double delta_seconds) {
    last_step_index_ = step_index;
    last_delta_seconds_ = delta_seconds;
}

void LocalAgentsSimProfiler::end_step(int64_t step_index, double delta_seconds, const Dictionary &step_result) {
    total_steps_ += 1;
    last_step_index_ = step_index;
    last_delta_seconds_ = delta_seconds;
    last_step_result_ = step_result.duplicate(true);
}

void LocalAgentsSimProfiler::reset() {
    total_steps_ = 0;
    last_step_index_ = -1;
    last_delta_seconds_ = 0.0;
    last_step_result_.clear();
}

Dictionary LocalAgentsSimProfiler::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("SimProfiler");
    snapshot["total_steps"] = total_steps_;
    snapshot["last_step_index"] = last_step_index_;
    snapshot["last_delta_seconds"] = last_delta_seconds_;
    snapshot["last_step_result"] = last_step_result_.duplicate(true);
    return snapshot;
}

} // namespace local_agents::simulation
