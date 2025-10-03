#include "AgentNode.hpp"
#include "AgentRuntime.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <filesystem>
#include <sstream>
#include <cstdlib>

using namespace godot;

namespace {
String resolve_runtime_path(const String &runtime_dir, const String &name) {
    if (runtime_dir.is_empty()) {
        return name;
    }
    std::filesystem::path base(runtime_dir.utf8().get_data());
    base /= name.utf8().get_data();
    return String(base.string().c_str());
}
}

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
    if (runtime && !runtime_directory_.is_empty()) {
        runtime->set_runtime_directory(runtime_directory_);
    }

    String voice_path = options.get("voice_path", String());
    if (voice_path.is_empty() && !voice_.is_empty()) {
        voice_path = resolve_runtime_path(runtime_directory_, String("voices/") + voice_);
    }

    if (voice_path.is_empty()) {
        UtilityFunctions::push_warning("Piper voice not configured");
        return false;
    }

    String piper_bin = resolve_runtime_path(runtime_directory_, String("piper"));
#ifdef _WIN32
    piper_bin += ".exe";
#endif

    String output_path = options.get("output_path", String());
    if (output_path.is_empty()) {
        std::filesystem::path temp = std::filesystem::temp_directory_path() / "local_agents_tts.wav";
        output_path = String(temp.string().c_str());
    }

    std::ostringstream cmd;
    cmd << '"' << piper_bin.utf8().get_data() << '"'
        << " --model \"" << voice_path.utf8().get_data() << "\""
        << " --output_file \"" << output_path.utf8().get_data() << "\"";

    if (options.has("voice_config")) {
        String cfg = options["voice_config"];
        if (!cfg.is_empty()) {
            cmd << " --config \"" << cfg.utf8().get_data() << "\"";
        }
    }

    cmd << " <<< '" << text.utf8().get_data() << "'";

    int code = std::system(cmd.str().c_str());
    if (code != 0) {
        UtilityFunctions::push_error("Piper invocation failed");
        return false;
    }

    Dictionary payload;
    payload["output_path"] = output_path;
    emit_signal("action_requested", String("audio_generated"), payload);
    return true;
}

String AgentNode::listen(const Dictionary &options) {
    String input_path = options.get("input_path", String());
    if (input_path.is_empty()) {
        UtilityFunctions::push_warning("listen() requires input_path");
        return String();
    }

    String model_path = options.get("model_path", String());
    if (model_path.is_empty()) {
        UtilityFunctions::push_warning("listen() requires whisper model path");
        return String();
    }

    String whisper_bin = resolve_runtime_path(runtime_directory_, String("whisper"));
#ifdef _WIN32
    whisper_bin += ".exe";
#endif

    std::ostringstream cmd;
    cmd << '"' << whisper_bin.utf8().get_data() << '"'
        << " --model \"" << model_path.utf8().get_data() << "\""
        << " --file \"" << input_path.utf8().get_data() << "\""
        << " --output-json";

    int code = std::system(cmd.str().c_str());
    if (code != 0) {
        UtilityFunctions::push_error("Whisper invocation failed");
        return String();
    }

    String output_path = input_path + ".json";
    Ref<FileAccess> file = FileAccess::open(output_path, FileAccess::READ);
    if (!file.is_valid()) {
        UtilityFunctions::push_error("Failed to read whisper output");
        return String();
    }
    String json_text = file->get_as_text();
    file->close();

    Variant parsed = JSON::parse_string(json_text);
    if (parsed.get_type() == Variant::DICTIONARY) {
        Dictionary dict = parsed;
        if (dict.has("text")) {
            String transcript = dict["text"];
            add_message("user", transcript);
            emit_signal("message_emitted", String("user"), transcript);
            return transcript;
        }
    }

    UtilityFunctions::push_warning("Whisper output missing text");
    return String();
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
