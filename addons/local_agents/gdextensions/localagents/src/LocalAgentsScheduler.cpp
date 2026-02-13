#include "LocalAgentsScheduler.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

namespace {
const Variant KEY_OK = StringName("ok");
const Variant KEY_STEP_INDEX = StringName("step_index");
const Variant KEY_DELTA_SECONDS = StringName("delta_seconds");
const Variant KEY_SCHEDULED_SYSTEMS = StringName("scheduled_systems");
const Variant KEY_SYSTEMS = StringName("systems");
const Variant KEY_COMPONENT = StringName("component");
const Variant KEY_SYSTEM_COUNT = StringName("system_count");
const Variant KEY_CONFIG = StringName("config");
const Variant KEY_REGISTRATION_ORDER = StringName("registration_order");
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
