#include "LocalAgentsScheduler.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

namespace {
constexpr const char *KEY_OK = "ok";
constexpr const char *KEY_STEP_INDEX = "step_index";
constexpr const char *KEY_DELTA_SECONDS = "delta_seconds";
constexpr const char *KEY_SCHEDULED_SYSTEMS = "scheduled_systems";
constexpr const char *KEY_SYSTEMS = "systems";
constexpr const char *KEY_COMPONENT = "component";
constexpr const char *KEY_SYSTEM_COUNT = "system_count";
constexpr const char *KEY_CONFIG = "config";
constexpr const char *KEY_REGISTRATION_ORDER = "registration_order";
} // namespace

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
    frame[KEY_OK] = true;
    frame[KEY_STEP_INDEX] = step_index;
    frame[KEY_DELTA_SECONDS] = delta_seconds;
    frame[KEY_SCHEDULED_SYSTEMS] = registration_order_.size();
    frame[KEY_SYSTEMS] = registration_order_.duplicate(true);
    return frame;
}

void LocalAgentsScheduler::reset() {
    config_.clear();
    system_configs_.clear();
    registration_order_.clear();
}

Dictionary LocalAgentsScheduler::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot[KEY_COMPONENT] = String("Scheduler");
    snapshot[KEY_SYSTEM_COUNT] = system_configs_.size();
    snapshot[KEY_CONFIG] = config_.duplicate(true);
    snapshot[KEY_REGISTRATION_ORDER] = registration_order_.duplicate(true);
    snapshot[KEY_SYSTEMS] = system_configs_.duplicate(true);
    return snapshot;
}

} // namespace local_agents::simulation
