#include "LocalAgentsComputeManager.hpp"

#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

namespace {

const Variant KEY_PIPELINE = StringName("pipeline");
const Variant KEY_OK = StringName("ok");
const Variant KEY_EXECUTED_STEPS = StringName("executed_steps");
const Variant KEY_SCHEDULED_FRAME = StringName("scheduled_frame");
const Variant KEY_COMPONENT = StringName("component");
const Variant KEY_CONFIG = StringName("config");

} // namespace

bool LocalAgentsComputeManager::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    const Dictionary pipeline_config = config.get(KEY_PIPELINE, Variant(Dictionary()));
    pipeline_.configure(pipeline_config);
    return true;
}

Dictionary LocalAgentsComputeManager::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

    Dictionary result;
    result[KEY_OK] = true;
    result[KEY_EXECUTED_STEPS] = executed_steps_;
    result[KEY_SCHEDULED_FRAME] = scheduled_frame.duplicate(true);
    result[KEY_PIPELINE] = pipeline_.execute_step(scheduled_frame);
    return result;
}

void LocalAgentsComputeManager::reset() {
    config_.clear();
    executed_steps_ = 0;
    pipeline_.reset();
}

Dictionary LocalAgentsComputeManager::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot[KEY_COMPONENT] = String("ComputeManager");
    snapshot[KEY_CONFIG] = config_.duplicate(true);
    snapshot[KEY_EXECUTED_STEPS] = executed_steps_;
    snapshot[KEY_PIPELINE] = pipeline_.get_debug_snapshot();
    return snapshot;
}

} // namespace local_agents::simulation
