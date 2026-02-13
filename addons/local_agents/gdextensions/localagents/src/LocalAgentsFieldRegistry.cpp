#include "LocalAgentsFieldRegistry.hpp"

using namespace godot;

namespace local_agents::simulation {

bool LocalAgentsFieldRegistry::register_field(const StringName &field_name, const Dictionary &field_config) {
    if (field_name.is_empty()) {
        return false;
    }

    const String key = String(field_name);
    if (!field_configs_.has(key)) {
        registration_order_.append(key);
    }
    field_configs_[key] = field_config.duplicate(true);
    return true;
}

bool LocalAgentsFieldRegistry::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    return true;
}

void LocalAgentsFieldRegistry::clear() {
    config_.clear();
    field_configs_.clear();
    registration_order_.clear();
}

Dictionary LocalAgentsFieldRegistry::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("FieldRegistry");
    snapshot["field_count"] = field_configs_.size();
    snapshot["config"] = config_.duplicate(true);
    snapshot["registration_order"] = registration_order_.duplicate(true);
    snapshot["fields"] = field_configs_.duplicate(true);
    return snapshot;
}

} // namespace local_agents::simulation
