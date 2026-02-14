#include "LocalAgentsComputeManager.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

namespace {

constexpr const char *KEY_PIPELINE = "pipeline";
constexpr const char *KEY_OK = "ok";
constexpr const char *KEY_EXECUTED_STEPS = "executed_steps";
constexpr const char *KEY_SCHEDULED_FRAME = "scheduled_frame";
constexpr const char *KEY_COMPONENT = "component";
constexpr const char *KEY_CONFIG = "config";
constexpr const char *KEY_FIELD_HANDLE_MODE = "field_handle_mode";
constexpr const char *KEY_FIELD_HANDLE_COUNT = "field_handle_count";
constexpr const char *KEY_FIELD_HANDLE_MARKER = "field_handle_marker";

} // namespace

bool LocalAgentsComputeManager::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    const Dictionary pipeline_config = config.get(KEY_PIPELINE, Variant(Dictionary()));
    pipeline_.configure(pipeline_config);
    return true;
}

Dictionary LocalAgentsComputeManager::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

    const Dictionary pipeline_result = pipeline_.execute_step(scheduled_frame);

    Dictionary result;
    result[KEY_OK] = true;
    result[KEY_EXECUTED_STEPS] = executed_steps_;
    result[KEY_SCHEDULED_FRAME] = scheduled_frame.duplicate(true);
    result[KEY_PIPELINE] = pipeline_result;
    result[KEY_FIELD_HANDLE_MODE] = pipeline_result.get(KEY_FIELD_HANDLE_MODE, String("scalar"));
    result[KEY_FIELD_HANDLE_COUNT] = static_cast<int64_t>(pipeline_result.get(KEY_FIELD_HANDLE_COUNT, static_cast<int64_t>(0)));
    if (pipeline_result.has(KEY_FIELD_HANDLE_MARKER)) {
        result[KEY_FIELD_HANDLE_MARKER] = pipeline_result.get(KEY_FIELD_HANDLE_MARKER, String());
    }
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
