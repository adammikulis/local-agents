#include "LocalAgentsScheduler.hpp"

using namespace godot;

namespace local_agents::simulation {

bool LocalAgentsScheduler::register_system(const StringName &system_name, const Dictionary &system_config) {
    if (system_name.is_empty()) {
        return false;
    }

    const String key = String(system_name);
    if (!system_configs_.has(key)) {
        registration_order_.append(key);
    }
    system_configs_[key] = system_config.duplicate(true);
    return true;
}

bool LocalAgentsScheduler::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    return true;
}

Dictionary LocalAgentsScheduler::step(double delta_seconds, int64_t step_index) {
    Dictionary frame;
    frame["ok"] = true;
    frame["step_index"] = step_index;
    frame["delta_seconds"] = delta_seconds;
    frame["scheduled_systems"] = registration_order_.size();
    frame["systems"] = registration_order_.duplicate(true);
    return frame;
}

void LocalAgentsScheduler::reset() {
    config_.clear();
    system_configs_.clear();
    registration_order_.clear();
}

Dictionary LocalAgentsScheduler::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("Scheduler");
    snapshot["system_count"] = system_configs_.size();
    snapshot["config"] = config_.duplicate(true);
    snapshot["registration_order"] = registration_order_.duplicate(true);
    snapshot["systems"] = system_configs_.duplicate(true);
    return snapshot;
}

} // namespace local_agents::simulation
