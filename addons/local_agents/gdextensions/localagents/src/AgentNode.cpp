#include "AgentNode.hpp"
#include "AgentRuntime.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

AgentNode::AgentNode() = default;
AgentNode::~AgentNode() = default;

void AgentNode::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "model_path", "options"), &AgentNode::load_model);
    ClassDB::bind_method(D_METHOD("unload_model"), &AgentNode::unload_model);
    ClassDB::bind_method(D_METHOD("add_message", "role", "content"), &AgentNode::add_message);
    ClassDB::bind_method(D_METHOD("get_history"), &AgentNode::get_history);
    ClassDB::bind_method(D_METHOD("clear_history"), &AgentNode::clear_history);
    ClassDB::bind_method(D_METHOD("think", "prompt", "extra_options"), &AgentNode::think);
    ClassDB::bind_method(D_METHOD("say", "text", "options"), &AgentNode::say);
    ClassDB::bind_method(D_METHOD("listen", "options"), &AgentNode::listen);
    ClassDB::bind_method(D_METHOD("enqueue_action", "name", "params"), &AgentNode::enqueue_action);

    ClassDB::bind_method(D_METHOD("set_tick_enabled", "enabled"), &AgentNode::set_tick_enabled);
    ClassDB::bind_method(D_METHOD("is_tick_enabled"), &AgentNode::is_tick_enabled);
    ClassDB::bind_method(D_METHOD("set_tick_interval", "seconds"), &AgentNode::set_tick_interval);
    ClassDB::bind_method(D_METHOD("get_tick_interval"), &AgentNode::get_tick_interval);
    ClassDB::bind_method(D_METHOD("set_max_actions_per_tick", "actions"), &AgentNode::set_max_actions_per_tick);
    ClassDB::bind_method(D_METHOD("get_max_actions_per_tick"), &AgentNode::get_max_actions_per_tick);
    ClassDB::bind_method(D_METHOD("set_db_path", "path"), &AgentNode::set_db_path);
    ClassDB::bind_method(D_METHOD("get_db_path"), &AgentNode::get_db_path);
    ClassDB::bind_method(D_METHOD("set_voice", "voice"), &AgentNode::set_voice);
    ClassDB::bind_method(D_METHOD("get_voice"), &AgentNode::get_voice);
    ClassDB::bind_method(D_METHOD("set_default_model_path", "path"), &AgentNode::set_default_model_path);
    ClassDB::bind_method(D_METHOD("get_default_model_path"), &AgentNode::get_default_model_path);
    ClassDB::bind_method(D_METHOD("set_runtime_directory", "path"), &AgentNode::set_runtime_directory);
    ClassDB::bind_method(D_METHOD("get_runtime_directory"), &AgentNode::get_runtime_directory);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "tick_enabled"), "set_tick_enabled", "is_tick_enabled");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tick_interval"), "set_tick_interval", "get_tick_interval");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "max_actions_per_tick"), "set_max_actions_per_tick", "get_max_actions_per_tick");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "db_path"), "set_db_path", "get_db_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "voice"), "set_voice", "get_voice");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "default_model_path"), "set_default_model_path", "get_default_model_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "runtime_directory"), "set_runtime_directory", "get_runtime_directory");

    ADD_SIGNAL(MethodInfo("message_emitted", PropertyInfo(Variant::STRING, "role"), PropertyInfo(Variant::STRING, "content")));
    ADD_SIGNAL(MethodInfo("action_requested", PropertyInfo(Variant::STRING, "action"), PropertyInfo(Variant::DICTIONARY, "params")));
}

void AgentNode::_process(double delta) {
    if (!tick_enabled_) {
        return;
    }
    tick_accumulator_ += delta;
    if (tick_accumulator_ < tick_interval_ || tick_interval_ <= 0.0) {
        return;
    }
    tick_accumulator_ = 0.0;
    if (!Engine::get_singleton()->is_editor_hint()) {
        emit_signal("action_requested", String("tick"), Dictionary());
    }
}

bool AgentNode::load_model(const String &model_path, const Dictionary &options) {
    AgentRuntime *runtime = AgentRuntime::get_singleton();
    if (!runtime) {
        UtilityFunctions::push_error("AgentRuntime singleton not available");
        return false;
    }
    if (!runtime_directory_.is_empty()) {
        runtime->set_runtime_directory(runtime_directory_);
    }
    if (!default_model_path_.is_empty()) {
        runtime->set_default_model_path(default_model_path_);
    }
    return runtime->load_model(model_path, options);
}

void AgentNode::unload_model() {
    AgentRuntime *runtime = AgentRuntime::get_singleton();
    if (runtime) {
        runtime->unload_model();
    }
}

void AgentNode::add_message(const String &role, const String &content) {
    history_.push_back({role, content});
}

TypedArray<Dictionary> AgentNode::get_history() const {
    TypedArray<Dictionary> result;
    result.resize(history_.size());
    for (size_t i = 0; i < history_.size(); ++i) {
        Dictionary entry;
        entry["role"] = history_[i].role;
        entry["content"] = history_[i].content;
        result[i] = entry;
    }
    return result;
}

void AgentNode::clear_history() {
    history_.clear();
}

Dictionary AgentNode::think(const String &prompt, const Dictionary &extra_options) {
    AgentRuntime *runtime = AgentRuntime::get_singleton();
    Dictionary response;
    if (!runtime) {
        response["ok"] = false;
        response["error"] = "runtime_unavailable";
        return response;
    }

    if (!default_model_path_.is_empty()) {
        runtime->set_default_model_path(default_model_path_);
    }
    if (!runtime_directory_.is_empty()) {
        runtime->set_runtime_directory(runtime_directory_);
    }

    add_message("user", prompt);

    Dictionary request;
    request["prompt"] = prompt;
    request["history"] = get_history();
    request["options"] = extra_options;

    Dictionary raw = runtime->generate(request);
    if ((bool)raw.get("ok", false)) {
        String text = raw.get("text", String());
        if (!text.is_empty()) {
            add_message("assistant", text);
            emit_signal("message_emitted", String("assistant"), text);
        }
    }
    return raw;
}

bool AgentNode::say(const String &text, const Dictionary &options) {
    AgentRuntime *runtime = AgentRuntime::get_singleton();
    if (!runtime) {
        UtilityFunctions::push_error("AgentRuntime singleton unavailable");
        return false;
    }
    Dictionary request = options.duplicate(true);
    request["text"] = text;
    if (!voice_.is_empty() && !request.has("voice_id")) {
        request["voice_id"] = voice_;
    }
    if (!runtime_directory_.is_empty() && !request.has("runtime_directory")) {
        request["runtime_directory"] = runtime_directory_;
    }
    Dictionary result = runtime->synthesize_speech(request);
    if (!result.get("ok", false)) {
        String error = result.get("error", String("piper_failed"));
        UtilityFunctions::push_error(String("Piper invocation failed: ") + error);
        return false;
    }
    Dictionary payload;
    payload["output_path"] = result.get("output_path", String());
    emit_signal("action_requested", String("audio_generated"), payload);
    return true;
}

String AgentNode::listen(const Dictionary &options) {
    AgentRuntime *runtime = AgentRuntime::get_singleton();
    if (!runtime) {
        UtilityFunctions::push_error("AgentRuntime singleton unavailable");
        return String();
    }
    Dictionary request = options.duplicate(true);
    if (!runtime_directory_.is_empty() && !request.has("runtime_directory")) {
        request["runtime_directory"] = runtime_directory_;
    }
    Dictionary result = runtime->transcribe_audio(request);
    if (!result.get("ok", false)) {
        String error = result.get("error", String("whisper_failed"));
        UtilityFunctions::push_error(String("Whisper invocation failed: ") + error);
        return String();
    }
    String transcript = result.get("text", String());
    if (!transcript.is_empty()) {
        add_message("user", transcript);
        emit_signal("message_emitted", String("user"), transcript);
    } else {
        UtilityFunctions::push_warning("Whisper output missing text");
    }
    return transcript;
}

void AgentNode::enqueue_action(const String &name, const Dictionary &params) {
    Dictionary payload = params.duplicate();
    payload["name"] = name;
    emit_signal("action_requested", name, payload);
}

void AgentNode::set_tick_enabled(bool enabled) {
    tick_enabled_ = enabled;
}

bool AgentNode::is_tick_enabled() const {
    return tick_enabled_;
}

void AgentNode::set_tick_interval(double seconds) {
    tick_interval_ = seconds;
}

double AgentNode::get_tick_interval() const {
    return tick_interval_;
}

void AgentNode::set_max_actions_per_tick(int actions) {
    max_actions_per_tick_ = actions;
}

int AgentNode::get_max_actions_per_tick() const {
    return max_actions_per_tick_;
}

void AgentNode::set_db_path(const String &path) {
    db_path_ = path;
}

String AgentNode::get_db_path() const {
    return db_path_;
}

void AgentNode::set_voice(const String &voice_id) {
    voice_ = voice_id;
}

String AgentNode::get_voice() const {
    return voice_;
}

void AgentNode::set_default_model_path(const String &path) {
    default_model_path_ = path;
    if (AgentRuntime::get_singleton()) {
        AgentRuntime::get_singleton()->set_default_model_path(path);
    }
}

String AgentNode::get_default_model_path() const {
    return default_model_path_;
}

void AgentNode::set_runtime_directory(const String &path) {
    runtime_directory_ = path;
    if (AgentRuntime::get_singleton()) {
        AgentRuntime::get_singleton()->set_runtime_directory(path);
    }
}

String AgentNode::get_runtime_directory() const {
    return runtime_directory_;
}
