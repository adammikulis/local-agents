#include "AgentRuntime.hpp"

#include "ModelDownloadManager.hpp"
#include "RuntimeStringUtils.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/json.hpp>

#include <llama.h>
#include <curl/curl.h>

#include <cmath>
#include <cstring>
#include <sstream>
#include <vector>
#include <chrono>
#include <atomic>
#include <fstream>
#include <limits>
#include <string_view>
#include <mutex>
#include <climits>
#include <filesystem>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <iomanip>
#include <cerrno>
#ifndef _WIN32
#include <sys/wait.h>
#endif

using namespace godot;
using local_agents::runtime::to_utf8;
using local_agents::runtime::from_utf8;

namespace {
String make_completion_id() {
    static std::atomic<uint64_t> counter{0};
    uint64_t value = counter.fetch_add(1, std::memory_order_relaxed) + 1;
    std::ostringstream oss;
    oss << "chatcmpl-" << value;
    return String::utf8(oss.str().c_str());
}

llama_sampler *create_sampler(const Dictionary &options, const llama_model *model) {
    llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
    chain_params.no_perf = true;

    llama_sampler *chain = llama_sampler_chain_init(chain_params);
    if (!chain) {
        return nullptr;
    }

    auto append_sampler = [chain](llama_sampler *sampler) {
        if (sampler) {
            llama_sampler_chain_add(chain, sampler);
        }
    };

    bool use_distribution = false;
    bool use_mirostat = false;

    if (options.has("top_k")) {
        int32_t top_k = (int32_t)options["top_k"];
        if (top_k > 0) {
            append_sampler(llama_sampler_init_top_k(top_k));
            use_distribution = true;
        }
    }

    if (options.has("top_p")) {
        float top_p = (float)options["top_p"];
        if (top_p > 0.0f) {
            append_sampler(llama_sampler_init_top_p(top_p, 1));
            use_distribution = true;
        }
    }

    if (options.has("min_p")) {
        float min_p = (float)options["min_p"];
        if (min_p > 0.0f) {
            append_sampler(llama_sampler_init_min_p(min_p, 1));
            use_distribution = true;
        }
    }

    if (options.has("typical_p")) {
        float typical_p = (float)options["typical_p"];
        if (typical_p > 0.0f && typical_p < 1.0f) {
            append_sampler(llama_sampler_init_typical(typical_p, 1));
            use_distribution = true;
        }
    }

    float temperature = 1.0f;
    if (options.has("temperature")) {
        temperature = (float)options["temperature"];
    }

    if (temperature <= 0.0f) {
        use_distribution = false;
    } else if (temperature != 1.0f) {
        append_sampler(llama_sampler_init_temp(temperature));
        use_distribution = true;
    } else {
        use_distribution = true;
    }

    uint32_t seed = LLAMA_DEFAULT_SEED;
    if (options.has("seed")) {
        int64_t raw_seed = (int64_t)options["seed"];
        if (raw_seed >= 0) {
            seed = static_cast<uint32_t>(raw_seed);
        }
    }

    float repeat_penalty = options.get("repeat_penalty", 1.0f);
    float frequency_penalty = options.get("frequency_penalty", 0.0f);
    float presence_penalty = options.get("presence_penalty", 0.0f);
    int32_t repeat_last_n = options.get("repeat_last_n", 0);
    if (repeat_penalty != 1.0f || frequency_penalty != 0.0f || presence_penalty != 0.0f || repeat_last_n != 0) {
        append_sampler(llama_sampler_init_penalties(repeat_last_n, repeat_penalty, frequency_penalty, presence_penalty));
    }

    int32_t mirostat_mode = options.get("mirostat", 0);
    if (mirostat_mode == 1 && model != nullptr) {
        const llama_vocab *model_vocab = llama_model_get_vocab(model);
        int32_t vocab_tokens = model_vocab ? llama_vocab_n_tokens(model_vocab) : 0;
        int32_t mirostat_last_n = options.get("mirostat_m", 100);
        float tau = options.get("mirostat_tau", 5.0f);
        float eta = options.get("mirostat_eta", 0.1f);
        append_sampler(llama_sampler_init_mirostat(vocab_tokens, seed, tau, eta, mirostat_last_n));
        use_mirostat = true;
    } else if (mirostat_mode == 2) {
        float tau = options.get("mirostat_tau", 5.0f);
        float eta = options.get("mirostat_eta", 0.1f);
        append_sampler(llama_sampler_init_mirostat_v2(seed, tau, eta));
        use_mirostat = true;
    }

    if (!use_mirostat) {
        if (use_distribution) {
            append_sampler(llama_sampler_init_dist(seed));
        } else {
            append_sampler(llama_sampler_init_greedy());
        }
    }

    if (llama_sampler_chain_n(chain) == 0) {
        append_sampler(llama_sampler_init_greedy());
    }

    return chain;
}

String normalize_project_path(const String &path) {
    if (path.is_empty()) {
        return path;
    }
    if (path.begins_with("res://") || path.begins_with("user://")) {
        ProjectSettings *settings = ProjectSettings::get_singleton();
        if (settings) {
            return settings->globalize_path(path);
        }
    }
    return path;
}

String detect_runtime_subdir() {
    OS *os = OS::get_singleton();
    if (!os) {
        return String();
    }
    String os_name = os->get_name();
    if (os_name == String("macOS")) {
        if (os->has_feature(StringName("arm64"))) {
            return String("macos_arm64");
        }
        return String("macos_x86_64");
    }
    if (os_name == String("Windows")) {
        return String("windows_x86_64");
    }
    if (os_name == String("Linux")) {
        if (os->has_feature(StringName("aarch64")) || os->has_feature(StringName("arm64"))) {
            return String("linux_aarch64");
        }
        if (os->has_feature(StringName("x86_64"))) {
            return String("linux_x86_64");
        }
        if (os->has_feature(StringName("armv7"))) {
            return String("linux_armv7l");
        }
    }
    if (os_name == String("Android")) {
        return String("android_arm64");
    }
    return String();
}

String default_runtime_dir() {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    if (!settings) {
        return String();
    }
    const String base = String("res://addons/local_agents/gdextensions/localagents/bin/runtimes");
    String subdir = detect_runtime_subdir();
    if (!subdir.is_empty()) {
        String candidate = base + String("/") + subdir;
        String candidate_abs = settings->globalize_path(candidate);
        std::filesystem::path candidate_path(to_utf8(candidate_abs));
        if (std::filesystem::exists(candidate_path)) {
            return candidate_abs;
        }
    }
    String base_abs = settings->globalize_path(base);
    std::filesystem::path base_path(to_utf8(base_abs));
    if (std::filesystem::exists(base_path)) {
        return base_abs;
    }
    return String();
}

std::filesystem::path to_path(const String &path) {
    String normalized = normalize_project_path(path);
    if (normalized.is_empty()) {
        return std::filesystem::path();
    }
    return std::filesystem::path(to_utf8(normalized));
}

String path_to_string(const std::filesystem::path &path) {
    if (path.empty()) {
        return String();
    }
    return String::utf8(path.string().c_str());
}

std::filesystem::path resolve_runtime_directory_path(const String &requested, const String &fallback_property) {
    String normalized = normalize_project_path(requested);
    if (!normalized.is_empty()) {
        std::filesystem::path requested_path(to_utf8(normalized));
        if (std::filesystem::exists(requested_path)) {
            return requested_path;
        }
    }
    String fallback_normalized = normalize_project_path(fallback_property);
    if (!fallback_normalized.is_empty()) {
        std::filesystem::path fallback_path(to_utf8(fallback_normalized));
        if (std::filesystem::exists(fallback_path)) {
            return fallback_path;
        }
    }
    String auto_runtime = default_runtime_dir();
    if (!auto_runtime.is_empty()) {
        return std::filesystem::path(to_utf8(auto_runtime));
    }
    return std::filesystem::path();
}

std::filesystem::path find_binary(const std::filesystem::path &runtime_dir, const std::vector<std::string> &names) {
    if (names.empty()) {
        return std::filesystem::path();
    }
    for (const std::string &name : names) {
        std::filesystem::path candidate = runtime_dir / name;
        if (std::filesystem::exists(candidate)) {
            return candidate;
        }
    }
    return std::filesystem::path();
}

void ensure_parent_directory(const std::filesystem::path &file_path) {
    std::filesystem::path parent = file_path.parent_path();
    if (parent.empty()) {
        return;
    }
    std::error_code ec;
    std::filesystem::create_directories(parent, ec);
}

bool tokenize_text(
    const llama_vocab *vocab,
    const std::string &text,
    bool add_bos,
    bool parse_special,
    std::vector<llama_token> &out_tokens
) {
    out_tokens.clear();
    if (!vocab) {
        return false;
    }

    // Recent llama.cpp versions can return a negative required size when the output
    // buffer is too small, including probing calls with a null buffer.
    int32_t capacity = std::max<int32_t>(32, static_cast<int32_t>(text.size()) + (add_bos ? 2 : 1));
    out_tokens.resize(static_cast<size_t>(capacity));

    for (int attempt = 0; attempt < 4; ++attempt) {
        int32_t token_count = llama_tokenize(
            vocab,
            text.c_str(),
            static_cast<int32_t>(text.length()),
            out_tokens.data(),
            capacity,
            add_bos,
            parse_special
        );

        if (token_count > 0) {
            out_tokens.resize(static_cast<size_t>(token_count));
            return true;
        }

        if (token_count < 0) {
            capacity = -token_count;
            if (capacity <= 0) {
                return false;
            }
            out_tokens.resize(static_cast<size_t>(capacity));
            continue;
        }

        return false;
    }

    return false;
}

bool apply_stop_sequences(std::string &text, const std::vector<std::string> &stops) {
    if (stops.empty()) {
        return false;
    }
    size_t earliest = std::string::npos;
    for (const std::string &stop : stops) {
        if (stop.empty()) {
            continue;
        }
        size_t pos = text.find(stop);
        if (pos != std::string::npos && (earliest == std::string::npos || pos < earliest)) {
            earliest = pos;
        }
    }
    if (earliest != std::string::npos) {
        text.resize(earliest);
        return true;
    }
    return false;
}

Variant parse_json_response(const String &text) {
    auto try_parse = [](const String &candidate) -> Variant {
        Ref<JSON> parser;
        parser.instantiate();
        if (parser.is_valid() && parser->parse(candidate) == OK) {
            return parser->get_data();
        }
        return Variant();
    };

    String trimmed = text.strip_edges();
    if (trimmed.begins_with("{") || trimmed.begins_with("[")) {
        Variant parsed = try_parse(trimmed);
        if (parsed.get_type() != Variant::NIL) {
            return parsed;
        }
    }

    // Try to recover JSON object from wrapped prose output.
    int open_index = text.find("{");
    int close_index = text.rfind("}");
    if (open_index >= 0 && close_index > open_index) {
        String clipped = text.substr(open_index, close_index - open_index + 1);
        Variant parsed = try_parse(clipped);
        if (parsed.get_type() != Variant::NIL) {
            return parsed;
        }
    }
    return Variant();
}

bool validate_json_schema_basic(const Variant &parsed, const Dictionary &schema, String &reason) {
    if (schema.is_empty()) {
        return true;
    }

    String required_type = schema.get("type", String());
    if (required_type == String("object") && parsed.get_type() != Variant::DICTIONARY) {
        reason = String("schema_type_object_required");
        return false;
    }
    if (required_type == String("array") && parsed.get_type() != Variant::ARRAY) {
        reason = String("schema_type_array_required");
        return false;
    }

    if (parsed.get_type() == Variant::DICTIONARY && schema.has("required")) {
        Dictionary dict = parsed;
        Array required = schema["required"];
        for (int i = 0; i < required.size(); ++i) {
            String key = required[i];
            if (!dict.has(key)) {
                reason = String("schema_missing_required_key:") + key;
                return false;
            }
        }
    }
    return true;
}

struct HttpJsonResponse {
    bool ok = false;
    long status_code = 0;
    String body;
    String error;
};

size_t curl_write_string(void *contents, size_t size, size_t nmemb, void *userdata) {
    if (!userdata) {
        return 0;
    }
    const size_t total = size * nmemb;
    std::string *buffer = static_cast<std::string *>(userdata);
    buffer->append(static_cast<const char *>(contents), total);
    return total;
}

HttpJsonResponse http_post_json(
    const String &url,
    const Dictionary &payload,
    const PackedStringArray &headers,
    int timeout_seconds
) {
    HttpJsonResponse result;
    result.body = String();
    result.error = String();

    CURL *curl = curl_easy_init();
    if (!curl) {
        result.error = String("curl_init_failed");
        return result;
    }

    struct curl_slist *header_list = nullptr;
    for (int i = 0; i < headers.size(); ++i) {
        std::string header = to_utf8(headers[i]);
        header_list = curl_slist_append(header_list, header.c_str());
    }
    if (!header_list) {
        header_list = curl_slist_append(header_list, "Content-Type: application/json");
    }

    std::string response_buffer;
    std::string payload_text = to_utf8(JSON::stringify(payload));
    std::string url_utf8 = to_utf8(url);

    curl_easy_setopt(curl, CURLOPT_URL, url_utf8.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload_text.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(payload_text.size()));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_string);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_buffer);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds > 0 ? timeout_seconds : 120);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);

    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        result.error = String::utf8(curl_easy_strerror(code));
    } else {
        result.ok = true;
    }

    long status_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status_code);
    result.status_code = status_code;
    result.body = String::utf8(response_buffer.c_str());

    curl_slist_free_all(header_list);
    curl_easy_cleanup(curl);
    return result;
}

String normalize_server_base_url(String base_url) {
    base_url = base_url.strip_edges();
    while (base_url.ends_with("/")) {
        base_url = base_url.substr(0, base_url.length() - 1);
    }
    return base_url;
}

bool is_llama_server_backend(const Dictionary &options) {
    if (!options.has("backend")) {
        return false;
    }
    String backend = String(options["backend"]).to_lower().strip_edges();
    return backend == String("llama_server") ||
           backend == String("llama-server") ||
           backend == String("llama.cpp_server") ||
           backend == String("llama.cpp-http") ||
           backend == String("llama_cpp_http") ||
           backend == String("llama_http");
}

void merge_dictionary(Dictionary &target, const Dictionary &source) {
    Array keys = source.keys();
    for (int i = 0; i < keys.size(); ++i) {
        Variant key = keys[i];
        target[key] = source[key];
    }
}

void append_message(Array &messages, const String &role, const Variant &content) {
    if (role.is_empty()) {
        return;
    }
    Dictionary message;
    message["role"] = role;
    message["content"] = content;
    messages.append(message);
}

String content_variant_to_text(const Variant &content) {
    if (content.get_type() == Variant::STRING) {
        return static_cast<String>(content);
    }
    if (content.get_type() != Variant::ARRAY) {
        return String();
    }
    Array blocks = content;
    String merged;
    for (int i = 0; i < blocks.size(); ++i) {
        Variant block_variant = blocks[i];
        if (block_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary block = block_variant;
        String block_type = block.get("type", String());
        if (block_type == String("text")) {
            String text = block.get("text", String());
            if (!merged.is_empty()) {
                merged += String("\n");
            }
            merged += text;
        }
    }
    return merged;
}

String extract_chat_completion_text(const Dictionary &response, Dictionary &first_choice, Variant &tool_call_payload) {
    if (!response.has("choices")) {
        return response.get("content", String());
    }

    Array choices = response["choices"];
    if (choices.is_empty()) {
        return String();
    }
    Variant first_choice_variant = choices[0];
    if (first_choice_variant.get_type() != Variant::DICTIONARY) {
        return String();
    }
    first_choice = first_choice_variant;

    if (first_choice.has("message")) {
        Variant message_variant = first_choice["message"];
        if (message_variant.get_type() == Variant::DICTIONARY) {
            Dictionary message = message_variant;
            if (message.has("tool_calls")) {
                tool_call_payload = message["tool_calls"];
            }
            if (message.has("content")) {
                return content_variant_to_text(message["content"]);
            }
        }
    }

    if (first_choice.has("text")) {
        return first_choice["text"];
    }

    return String();
}

#ifdef _WIN32
FILE *open_pipe_write(const std::string &command) {
    return _popen(command.c_str(), "w");
}

int close_pipe(FILE *pipe) {
    return _pclose(pipe);
}
#else
FILE *open_pipe_write(const std::string &command) {
    return popen(command.c_str(), "w");
}

int close_pipe(FILE *pipe) {
    return pclose(pipe);
}
#endif

int extract_exit_code(int status) {
#ifdef _WIN32
    return status;
#else
    if (status == -1) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return status;
#endif
}

} // namespace

AgentRuntime *AgentRuntime::singleton_ = nullptr;

AgentRuntime::AgentRuntime()
    : sampler_(nullptr, [](llama_sampler *sampler) {
          if (sampler) {
              llama_sampler_free(sampler);
          }
      }) {
    if (!singleton_) {
        singleton_ = this;
    }
    download_manager_ = std::make_unique<ModelDownloadManager>();
    system_prompt_ = String("You are Local Agents, an offline assistant running inside a Godot game. Be concise and helpful.");
}

AgentRuntime::~AgentRuntime() {
    if (singleton_ == this) {
        singleton_ = nullptr;
    }
    unload_model();
}

AgentRuntime *AgentRuntime::get_singleton() {
    return singleton_;
}

void AgentRuntime::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "model_path", "options"), &AgentRuntime::load_model);
    ClassDB::bind_method(D_METHOD("unload_model"), &AgentRuntime::unload_model);
    ClassDB::bind_method(D_METHOD("is_model_loaded"), &AgentRuntime::is_model_loaded);
    ClassDB::bind_method(D_METHOD("get_runtime_health"), &AgentRuntime::get_runtime_health);
    ClassDB::bind_method(D_METHOD("generate", "request"), &AgentRuntime::generate);
    ClassDB::bind_method(D_METHOD("synthesize_speech", "request"), &AgentRuntime::synthesize_speech);
    ClassDB::bind_method(D_METHOD("transcribe_audio", "request"), &AgentRuntime::transcribe_audio);
    ClassDB::bind_method(D_METHOD("embed_text", "text", "options"), &AgentRuntime::embed_text, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("download_model", "request"), &AgentRuntime::download_model);
    ClassDB::bind_method(D_METHOD("download_model_hf", "repo", "options"), &AgentRuntime::download_model_hf, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("get_model_cache_directory"), &AgentRuntime::get_model_cache_directory);

    ClassDB::bind_method(D_METHOD("set_default_model_path", "path"), &AgentRuntime::set_default_model_path);
    ClassDB::bind_method(D_METHOD("get_default_model_path"), &AgentRuntime::get_default_model_path);
    ClassDB::bind_method(D_METHOD("set_runtime_directory", "path"), &AgentRuntime::set_runtime_directory);
    ClassDB::bind_method(D_METHOD("get_runtime_directory"), &AgentRuntime::get_runtime_directory);
    ClassDB::bind_method(D_METHOD("set_system_prompt", "prompt"), &AgentRuntime::set_system_prompt);
    ClassDB::bind_method(D_METHOD("get_system_prompt"), &AgentRuntime::get_system_prompt);

    ADD_SIGNAL(MethodInfo("download_started",
        PropertyInfo(Variant::STRING, "label"),
        PropertyInfo(Variant::STRING, "path")));
    ADD_SIGNAL(MethodInfo("download_progress",
        PropertyInfo(Variant::STRING, "label"),
        PropertyInfo(Variant::FLOAT, "progress"),
        PropertyInfo(Variant::INT, "received_bytes"),
        PropertyInfo(Variant::INT, "total_bytes"),
        PropertyInfo(Variant::STRING, "path")));
    ADD_SIGNAL(MethodInfo("download_log",
        PropertyInfo(Variant::STRING, "line"),
        PropertyInfo(Variant::STRING, "path")));
    ADD_SIGNAL(MethodInfo("download_finished",
        PropertyInfo(Variant::BOOL, "ok"),
        PropertyInfo(Variant::STRING, "error"),
        PropertyInfo(Variant::STRING, "path")));

    ADD_PROPERTY(PropertyInfo(Variant::STRING, "default_model_path"), "set_default_model_path", "get_default_model_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "runtime_directory"), "set_runtime_directory", "get_runtime_directory");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "system_prompt"), "set_system_prompt", "get_system_prompt");
}

void AgentRuntime::_notification(int what) {
    if (what == NOTIFICATION_PREDELETE) {
        if (singleton_ == this) {
            singleton_ = nullptr;
        }
    }
}

bool AgentRuntime::load_model(const String &model_path, const Dictionary &options) {
    std::scoped_lock lock(mutex_);
    String resolved = model_path.is_empty() ? default_model_path_ : model_path;
    if (resolved.is_empty()) {
        UtilityFunctions::push_error("AgentRuntime::load_model - model path empty");
        return false;
    }
    if (!model_path.is_empty()) {
        default_model_path_ = resolved;
    }
    return load_model_locked(resolved, options, true);
}

void AgentRuntime::unload_model() {
    std::scoped_lock lock(mutex_);
    unload_model_locked();
}

bool AgentRuntime::is_model_loaded() const {
    std::scoped_lock lock(mutex_);
    return model_ != nullptr && context_ != nullptr;
}

Dictionary AgentRuntime::get_runtime_health() {
    Dictionary health;
    String runtime_property;
    String model_path;
    bool model_loaded = false;
    {
        std::scoped_lock lock(mutex_);
        runtime_property = runtime_directory_;
        model_path = default_model_path_;
        model_loaded = model_ != nullptr && context_ != nullptr;
    }

    std::filesystem::path runtime_dir = resolve_runtime_directory_path(String(), runtime_property);
    bool runtime_dir_exists = !runtime_dir.empty() && std::filesystem::exists(runtime_dir);
    std::filesystem::path model_path_fs = to_path(model_path);
    bool model_path_exists = !model_path_fs.empty() && std::filesystem::exists(model_path_fs);

    std::filesystem::path llama_cli = find_binary(runtime_dir, {"llama-cli", "llama-cli.exe"});
    std::filesystem::path llama_server = find_binary(runtime_dir, {"llama-server", "llama-server.exe"});
    std::filesystem::path piper = find_binary(runtime_dir, {"piper", "piper.exe"});
    std::filesystem::path whisper = find_binary(runtime_dir, {"whisper", "whisper-cli", "whisper.exe", "whisper-cli.exe"});

    PackedStringArray missing;
    if (llama_cli.empty()) {
        missing.append("llama-cli");
    }
    if (piper.empty()) {
        missing.append("piper");
    }
    if (whisper.empty()) {
        missing.append("whisper");
    }

    Dictionary binaries;
    binaries["llama_cli"] = path_to_string(llama_cli);
    binaries["llama_server"] = path_to_string(llama_server);
    binaries["piper"] = path_to_string(piper);
    binaries["whisper"] = path_to_string(whisper);

    health["ok"] = runtime_dir_exists && missing.is_empty();
    health["model_loaded"] = model_loaded;
    health["default_model_path"] = model_path;
    health["default_model_exists"] = model_path_exists;
    health["runtime_directory"] = runtime_property;
    health["resolved_runtime_directory"] = path_to_string(runtime_dir);
    health["runtime_directory_exists"] = runtime_dir_exists;
    health["binaries"] = binaries;
    health["missing_binaries"] = missing;
    return health;
}

Dictionary AgentRuntime::generate(const Dictionary &request) {
    std::scoped_lock lock(mutex_);

    Dictionary options = default_options_.duplicate();
    if (request.has("options")) {
        Dictionary overrides = request["options"];
        Array keys = overrides.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            options[key] = overrides[key];
        }
    }

    if (is_llama_server_backend(options)) {
        return run_llama_server_inference_locked(request, options);
    }

    if (!model_ || !context_) {
        if (default_model_path_.is_empty()) {
            Dictionary error;
            error["ok"] = false;
            error["error"] = "model_not_loaded";
            return error;
        }
        if (!load_model_locked(default_model_path_, default_options_, false)) {
            Dictionary error;
            error["ok"] = false;
            error["error"] = "model_not_loaded";
            return error;
        }
    }

    return run_inference_locked(request);
}

PackedFloat32Array AgentRuntime::embed_text(const String &text, const Dictionary &options) {
    std::scoped_lock lock(mutex_);

    PackedFloat32Array empty;
    if (text.is_empty()) {
        UtilityFunctions::push_warning("AgentRuntime::embed_text - empty text");
        return empty;
    }

    if (!model_ || !context_) {
        if (default_model_path_.is_empty()) {
            UtilityFunctions::push_error("AgentRuntime::embed_text - model not loaded");
            return empty;
        }
        Dictionary reload_options = default_options_.duplicate();
        reload_options["embedding"] = true;
        if (!load_model_locked(default_model_path_, reload_options, false)) {
            UtilityFunctions::push_error("AgentRuntime::embed_text - failed to reload model with embedding support");
            return empty;
        }
    }

    Dictionary resolved = default_options_.duplicate();
    if (!options.is_empty()) {
        Array keys = options.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            resolved[key] = options[key];
        }
    }

    bool add_bos = resolved.get("add_bos", true);
    bool normalize = resolved.get("normalize", true);

    std::string input = to_utf8(text);
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - vocab unavailable");
        return empty;
    }

    std::vector<llama_token> tokens;
    if (!tokenize_text(vocab, input, add_bos, false, tokens)) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - tokenization failed");
        return empty;
    }

    llama_memory_clear(llama_get_memory(context_), true);

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));

    if (llama_decode(context_, batch) != 0) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - llama_decode failed");
        return empty;
    }

    const float *embedding_ptr = nullptr;
    switch (llama_pooling_type(context_)) {
        case LLAMA_POOLING_TYPE_NONE:
            embedding_ptr = llama_get_embeddings(context_);
            if (!embedding_ptr) {
                embedding_ptr = llama_get_embeddings_ith(context_, static_cast<int32_t>(tokens.size()) - 1);
            }
            break;
        default:
            embedding_ptr = llama_get_embeddings_seq(context_, 0);
            break;
    }

    if (!embedding_ptr) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - no embedding data");
        return empty;
    }

    int dim = llama_model_n_embd(model_);
    PackedFloat32Array embedding;
    embedding.resize(dim);
    float *out = embedding.ptrw();
    std::memcpy(out, embedding_ptr, dim * sizeof(float));

    if (normalize) {
        double norm = 0.0;
        for (int i = 0; i < dim; ++i) {
            norm += static_cast<double>(out[i]) * static_cast<double>(out[i]);
        }
        norm = std::sqrt(std::max(norm, 1e-12));
        if (norm > 0.0) {
            for (int i = 0; i < dim; ++i) {
                out[i] = static_cast<float>(out[i] / norm);
            }
        }
    }

    return embedding;
}

Dictionary AgentRuntime::download_model(const Dictionary &request) {
    if (!download_manager_) {
        download_manager_ = std::make_unique<ModelDownloadManager>();
    }

    ModelDownloadManager::Callbacks callbacks;
    callbacks.started = [this](const String &label, const String &path) {
        emit_signal("download_started", label, path);
    };
    callbacks.progress = [this](const String &label, double progress, int64_t received, int64_t total, const String &path) {
        emit_signal("download_progress", label, progress, received, total, path);
    };
    callbacks.log = [this](const String &line, const String &path) {
        emit_signal("download_log", line, path);
    };
    callbacks.finished = [this](bool ok, const String &error, const String &path) {
        emit_signal("download_finished", ok, error, path);
    };

    String runtime_dir_copy;
    {
        std::scoped_lock lock(mutex_);
        runtime_dir_copy = runtime_directory_;
    }

    return download_manager_->download(request, callbacks, runtime_dir_copy);
}

String AgentRuntime::get_model_cache_directory() const {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    if (!settings) {
        return String();
    }
    String base_path = settings->globalize_path("user://local_agents/models");
    if (base_path.is_empty()) {
        return String();
    }
    std::filesystem::path dir_path(local_agents::runtime::to_utf8(base_path));
    std::error_code ec;
    std::filesystem::create_directories(dir_path, ec);
    return String::utf8(dir_path.string().c_str());
}

Dictionary AgentRuntime::download_model_hf(const String &repo, const Dictionary &options) {
    Dictionary request;
    request["hf_repo"] = repo;

    String hf_file;
    if (options.has("hf_file")) {
        hf_file = options["hf_file"];
    } else if (options.has("file")) {
        hf_file = options["file"];
    }

    if (hf_file.is_empty()) {
        Dictionary error;
        error["ok"] = false;
        error["error"] = String("missing_hf_file");
        return error;
    }
    request["hf_file"] = hf_file;

    if (options.has("hf_tag")) {
        request["hf_tag"] = options["hf_tag"];
    } else if (options.has("tag")) {
        request["hf_tag"] = options["tag"];
    }

    if (options.has("label")) {
        request["label"] = options["label"];
    } else {
        request["label"] = hf_file;
    }

    auto copy_option = [&](const char *key) {
        if (options.has(key)) {
            request[key] = options[key];
        }
    };

    copy_option("force");
    copy_option("skip_existing");
    copy_option("offline");
    copy_option("bearer_token");
    copy_option("hf_endpoint");
    copy_option("timeout_seconds");
    copy_option("no_mmproj");
    copy_option("headers");

    ProjectSettings *settings = ProjectSettings::get_singleton();
    auto globalize = [&](const String &path) -> String {
        if (!settings || path.is_empty()) {
            return path;
        }
        if (path.begins_with("user://") || path.begins_with("res://")) {
            return settings->globalize_path(path);
        }
        return path;
    };

    String output_path = options.get("output_path", String());
    if (!output_path.is_empty()) {
        output_path = globalize(output_path);
    }

    if (output_path.is_empty()) {
        String output_dir = options.get("output_dir", String());
        if (output_dir.is_empty()) {
            output_dir = get_model_cache_directory();
        } else {
            output_dir = globalize(output_dir);
        }

        if (output_dir.is_empty()) {
            Dictionary error;
            error["ok"] = false;
            error["error"] = String("missing_output_path");
            return error;
        }

        std::filesystem::path dir_path(local_agents::runtime::to_utf8(output_dir));
        String folder_override = options.get("folder", String());
        if (!folder_override.is_empty()) {
            dir_path /= local_agents::runtime::to_utf8(folder_override);
        } else {
            String folder = repo;
            folder = folder.replace("/", "_");
            folder = folder.replace(":", "_");
            dir_path /= local_agents::runtime::to_utf8(folder);
        }

        std::error_code ec;
        std::filesystem::create_directories(dir_path, ec);
        dir_path /= local_agents::runtime::to_utf8(hf_file);
        output_path = String::utf8(dir_path.string().c_str());
    }

    request["output_path"] = output_path;

    return download_model(request);
}

Dictionary AgentRuntime::synthesize_speech(const Dictionary &request) {
    Dictionary response;
    response["ok"] = false;

    String text = request.get("text", String());
    if (text.is_empty()) {
        response["error"] = String("missing_text");
        return response;
    }

    String voice_path = request.get("voice_path", String());
    if (voice_path.is_empty()) {
        response["error"] = String("missing_voice_path");
        return response;
    }

    String output_path = request.get("output_path", String());
    if (output_path.is_empty()) {
        std::filesystem::path temp_path = std::filesystem::temp_directory_path() / "local_agents_tts.wav";
        output_path = String::utf8(temp_path.string().c_str());
    }

    String runtime_override = request.get("runtime_directory", String());
    String voice_config = request.get("voice_config", String());

    String runtime_property;
    {
        std::scoped_lock lock(speech_mutex_);
        runtime_property = runtime_directory_;
    }

    std::filesystem::path runtime_dir_path = resolve_runtime_directory_path(runtime_override, runtime_property);
    if (runtime_dir_path.empty()) {
        response["error"] = String("runtime_directory_missing");
        return response;
    }

    std::filesystem::path piper_bin = find_binary(runtime_dir_path, {"piper", "piper.exe"});
    if (piper_bin.empty()) {
        response["error"] = String("piper_binary_missing");
        response["runtime_directory"] = path_to_string(runtime_dir_path);
        return response;
    }

    std::filesystem::path voice_model_path = to_path(voice_path);
    if (voice_model_path.empty() || !std::filesystem::exists(voice_model_path)) {
        response["error"] = String("voice_missing");
        response["voice_path"] = voice_path;
        return response;
    }

    std::optional<std::filesystem::path> voice_config_path;
    if (!voice_config.is_empty()) {
        std::filesystem::path config_candidate = to_path(voice_config);
        if (!config_candidate.empty() && std::filesystem::exists(config_candidate)) {
            voice_config_path = config_candidate;
        } else {
            response["voice_config_missing"] = voice_config;
        }
    }

    std::filesystem::path output_file_path = to_path(output_path);
    if (output_file_path.empty()) {
        output_file_path = std::filesystem::path(to_utf8(output_path));
    }
    ensure_parent_directory(output_file_path);

    std::filesystem::path espeak_dir = runtime_dir_path / "espeak-ng-data";
    if (!std::filesystem::exists(espeak_dir)) {
        std::filesystem::path alt = runtime_dir_path / "espeak-ng" / "data";
        if (std::filesystem::exists(alt)) {
            espeak_dir = alt;
        }
    }
    std::filesystem::path tashkeel_model = runtime_dir_path / "libtashkeel_model.ort";

    std::ostringstream command;
    command << '\"' << piper_bin.string() << '\"';
    command << " --model " << std::quoted(voice_model_path.string());
    command << " --output_file " << std::quoted(output_file_path.string());
    if (voice_config_path.has_value()) {
        command << " --config " << std::quoted(voice_config_path->string());
    }
    if (std::filesystem::exists(espeak_dir)) {
        command << " --espeak_data " << std::quoted(espeak_dir.string());
    }
    if (std::filesystem::exists(tashkeel_model)) {
        command << " --tashkeel_model " << std::quoted(tashkeel_model.string());
    }

    std::string command_line = command.str();
    FILE *pipe = open_pipe_write(command_line);
    if (!pipe) {
        response["error"] = String("piper_spawn_failed");
        response["command"] = String::utf8(command_line.c_str());
        return response;
    }

    std::string text_utf8 = to_utf8(text);
    int write_error = 0;
    if (std::fputs(text_utf8.c_str(), pipe) == EOF) {
        write_error = errno;
    }
    if (!write_error && (text_utf8.empty() || text_utf8.back() != '\n')) {
        if (std::fputc('\n', pipe) == EOF) {
            write_error = errno;
        }
    }

    int raw_status = close_pipe(pipe);
    int exit_code = extract_exit_code(raw_status);
    if (write_error != 0) {
        response["error"] = String("piper_write_failed");
        response["errno"] = write_error;
        response["exit_code"] = exit_code;
        response["command"] = String::utf8(command_line.c_str());
        return response;
    }
    if (exit_code != 0) {
        response["error"] = String("piper_exit");
        response["exit_code"] = exit_code;
        response["command"] = String::utf8(command_line.c_str());
        return response;
    }
    if (!std::filesystem::exists(output_file_path)) {
        response["error"] = String("piper_output_missing");
        response["output_path"] = path_to_string(output_file_path);
        return response;
    }

    response["ok"] = true;
    response["output_path"] = path_to_string(output_file_path);
    response["runtime_directory"] = path_to_string(runtime_dir_path);
    return response;
}

Dictionary AgentRuntime::transcribe_audio(const Dictionary &request) {
    Dictionary response;
    response["ok"] = false;

    String input_path = request.get("input_path", String());
    if (input_path.is_empty()) {
        response["error"] = String("missing_input_path");
        return response;
    }
    String model_path = request.get("model_path", String());
    if (model_path.is_empty()) {
        response["error"] = String("missing_model_path");
        return response;
    }

    String runtime_override = request.get("runtime_directory", String());
    String output_override = request.get("output_path", String());

    String runtime_property;
    {
        std::scoped_lock lock(speech_mutex_);
        runtime_property = runtime_directory_;
    }

    std::filesystem::path runtime_dir_path = resolve_runtime_directory_path(runtime_override, runtime_property);
    if (runtime_dir_path.empty()) {
        response["error"] = String("runtime_directory_missing");
        return response;
    }

    std::filesystem::path whisper_bin = find_binary(runtime_dir_path, {"whisper", "whisper-cli", "whisper.exe", "whisper-cli.exe"});
    if (whisper_bin.empty()) {
        response["error"] = String("whisper_binary_missing");
        response["runtime_directory"] = path_to_string(runtime_dir_path);
        return response;
    }

    std::filesystem::path input_file = to_path(input_path);
    if (input_file.empty() || !std::filesystem::exists(input_file)) {
        response["error"] = String("input_missing");
        response["input_path"] = input_path;
        return response;
    }

    std::filesystem::path model_file = to_path(model_path);
    if (model_file.empty() || !std::filesystem::exists(model_file)) {
        response["error"] = String("model_missing");
        response["model_path"] = model_path;
        return response;
    }

    std::filesystem::path desired_output = to_path(output_override);
    if (desired_output.empty()) {
        desired_output = input_file;
        desired_output += ".json";
    }
    ensure_parent_directory(desired_output);

    std::ostringstream command;
    command << '\"' << whisper_bin.string() << '\"';
    command << " --model " << std::quoted(model_file.string());
    command << " --file " << std::quoted(input_file.string());
    command << " --output-json";

    std::string command_line = command.str();
    int exit_code = extract_exit_code(std::system(command_line.c_str()));
    if (exit_code != 0) {
        response["error"] = String("whisper_exit");
        response["exit_code"] = exit_code;
        response["command"] = String::utf8(command_line.c_str());
        return response;
    }

    std::filesystem::path generated_output = input_file;
    generated_output += ".json";
    std::filesystem::path actual_output = desired_output;
    if (!std::filesystem::exists(actual_output)) {
        if (std::filesystem::exists(generated_output)) {
            if (generated_output != desired_output) {
                std::error_code ec;
                std::filesystem::copy_file(generated_output, desired_output, std::filesystem::copy_options::overwrite_existing, ec);
                actual_output = ec ? generated_output : desired_output;
            } else {
                actual_output = generated_output;
            }
        }
    }

    if (!std::filesystem::exists(actual_output)) {
        response["error"] = String("whisper_output_missing");
        response["output_path"] = path_to_string(desired_output);
        return response;
    }

    std::string json_content;
    std::ifstream json_stream(actual_output);
    if (json_stream.good()) {
        std::ostringstream buffer;
        buffer << json_stream.rdbuf();
        json_content = buffer.str();
    }

    if (!json_content.empty()) {
        String json_text = String::utf8(json_content.c_str());
        Variant parsed = JSON::parse_string(json_text);
        if (parsed.get_type() == Variant::DICTIONARY) {
            Dictionary dict = parsed;
            if (dict.has("text")) {
                response["text"] = dict["text"];
            }
        }
    }

    response["ok"] = true;
    response["output_path"] = path_to_string(actual_output);
    response["runtime_directory"] = path_to_string(runtime_dir_path);
    return response;
}

Dictionary AgentRuntime::run_inference_locked(const Dictionary &request) {
    Dictionary response;
    if (!model_ || !context_) {
        response["ok"] = false;
        response["error"] = "model_not_loaded";
        return response;
    }

    TypedArray<Dictionary> history = request.get("history", TypedArray<Dictionary>());
    String prompt = request.get("prompt", String());
    Dictionary options = default_options_.duplicate();
    if (request.has("options")) {
        Dictionary overrides = request["options"];
        Array keys = overrides.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            options[key] = overrides[key];
        }
    }

    std::vector<std::string> stop_sequences;
    if (options.has("stop")) {
        Variant stop_value = options["stop"];
        if (stop_value.get_type() == Variant::STRING) {
            std::string stop = to_utf8(static_cast<String>(stop_value));
            if (!stop.empty()) {
                stop_sequences.push_back(stop);
            }
        } else if (stop_value.get_type() == Variant::ARRAY) {
            Array stop_array = stop_value;
            for (int i = 0; i < stop_array.size(); ++i) {
                Variant item = stop_array[i];
                if (item.get_type() == Variant::STRING) {
                    std::string stop = to_utf8(static_cast<String>(item));
                    if (!stop.empty()) {
                        stop_sequences.push_back(stop);
                    }
                }
            }
        }
    }
    if (options.has("stop_sequences")) {
        Array stop_array = options["stop_sequences"];
        for (int i = 0; i < stop_array.size(); ++i) {
            Variant item = stop_array[i];
            if (item.get_type() == Variant::STRING) {
                std::string stop = to_utf8(static_cast<String>(item));
                if (!stop.empty()) {
                    stop_sequences.push_back(stop);
                }
            }
        }
    }

    bool require_json = false;
    if (options.has("response_format")) {
        Variant response_format_variant = options["response_format"];
        if (response_format_variant.get_type() == Variant::DICTIONARY) {
            Dictionary response_format = response_format_variant;
            String response_type = response_format.get("type", String());
            require_json = response_type == String("json_object");
        } else if (response_format_variant.get_type() == Variant::STRING) {
            String response_type = response_format_variant;
            require_json = response_type == String("json_object");
        }
    }
    Dictionary json_schema;
    if (options.has("json_schema")) {
        Variant schema_variant = options["json_schema"];
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            json_schema = schema_variant;
            require_json = true;
        }
    }

    sampler_.reset();
    if (!ensure_sampler_locked(options)) {
        response["ok"] = false;
        response["error"] = "sampler_init_failed";
        return response;
    }

    if (sampler_) {
        llama_sampler_reset(sampler_.get());
    }

    std::string prompt_text = build_prompt(history, prompt);

    const bool add_bos = true;
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        response["ok"] = false;
        response["error"] = "vocab_unavailable";
        return response;
    }

    std::vector<llama_token> tokens_prompt;
    if (!tokenize_text(vocab, prompt_text, add_bos, false, tokens_prompt)) {
        response["ok"] = false;
        response["error"] = "tokenization_failed";
        return response;
    }

    // Avoid cross-request KV contamination unless explicitly opted into prompt caching.
    bool reset_context = options.get("reset_context", true);
    bool cache_prompt = options.get("cache_prompt", false);
    if (reset_context && !cache_prompt) {
        llama_memory_clear(llama_get_memory(context_), true);
    }

    int32_t decode_batch_size = options.get("batch_size", 512);
    if (decode_batch_size <= 0) {
        decode_batch_size = 512;
    }
    for (size_t offset = 0; offset < tokens_prompt.size(); offset += static_cast<size_t>(decode_batch_size)) {
        int32_t chunk = static_cast<int32_t>(std::min<size_t>(
            static_cast<size_t>(decode_batch_size),
            tokens_prompt.size() - offset
        ));
        llama_batch batch = llama_batch_get_one(tokens_prompt.data() + offset, chunk);
        if (llama_decode(context_, batch)) {
            response["ok"] = false;
            response["error"] = "llama_decode_failed";
            return response;
        }
    }

    int max_tokens = options.get("max_tokens", 256);

    std::ostringstream generated;
    for (int i = 0; i < max_tokens; ++i) {
        llama_token token = llama_sampler_sample(sampler_.get(), context_, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }
        generated << token_to_string(token);
        std::string generated_snapshot = generated.str();
        if (apply_stop_sequences(generated_snapshot, stop_sequences)) {
            generated.str(std::string());
            generated.clear();
            generated << generated_snapshot;
            break;
        }

        llama_batch cont = llama_batch_get_one(&token, 1);
        if (llama_decode(context_, cont)) {
            UtilityFunctions::push_warning("llama_decode failed during continuation");
            break;
        }
    }

    String text = String::utf8(generated.str().c_str()).strip_edges();
    response["ok"] = true;
    response["text"] = text;
    if (require_json) {
        Variant parsed_json = parse_json_response(text);
        if (parsed_json.get_type() == Variant::NIL) {
            response["ok"] = false;
            response["error"] = "json_parse_failed";
            return response;
        }
        String schema_reason;
        if (!validate_json_schema_basic(parsed_json, json_schema, schema_reason)) {
            response["ok"] = false;
            response["error"] = "json_schema_validation_failed";
            response["schema_reason"] = schema_reason;
            response["json"] = parsed_json;
            return response;
        }
        response["json"] = parsed_json;
    }
    return response;
}

Dictionary AgentRuntime::run_llama_server_inference_locked(const Dictionary &request, const Dictionary &options) {
    Dictionary response;
    response["ok"] = false;
    response["provider"] = String("llama_server");

    String base_url = options.get("server_base_url", options.get("base_url", String("http://127.0.0.1:8080")));
    base_url = normalize_server_base_url(base_url);
    if (base_url.is_empty()) {
        response["error"] = String("missing_server_base_url");
        return response;
    }

    String chat_endpoint = options.get("server_chat_endpoint", String());
    if (chat_endpoint.is_empty()) {
        chat_endpoint = base_url.ends_with("/v1") ? String("/chat/completions") : String("/v1/chat/completions");
    }
    if (!chat_endpoint.begins_with("/")) {
        chat_endpoint = String("/") + chat_endpoint;
    }
    String url = base_url + chat_endpoint;

    Array messages;
    if (options.has("messages") && options["messages"].get_type() == Variant::ARRAY) {
        messages = options["messages"];
    } else {
        TypedArray<Dictionary> history = request.get("history", TypedArray<Dictionary>());
        bool has_system = false;
        for (int i = 0; i < history.size(); ++i) {
            Dictionary entry = history[i];
            String role = entry.get("role", String());
            Variant content = entry.get("content", Variant());
            if (content.get_type() == Variant::NIL) {
                content = String();
            }
            if (role == String("system")) {
                has_system = true;
            }
            append_message(messages, role, content);
        }

        if (!has_system && !system_prompt_.is_empty()) {
            Dictionary system_message;
            system_message["role"] = String("system");
            system_message["content"] = system_prompt_;
            messages.insert(0, system_message);
        }

        String prompt = request.get("prompt", String());
        if (!prompt.is_empty()) {
            append_message(messages, String("user"), prompt);
        }
    }

    if (messages.is_empty()) {
        response["error"] = String("missing_messages");
        return response;
    }

    Dictionary payload;
    payload["messages"] = messages;
    payload["model"] = options.get("server_model", options.get("model", String("local-agents")));

    auto copy_if_present = [&](const char *option_key, const char *payload_key) {
        if (options.has(option_key)) {
            payload[payload_key] = options[option_key];
        }
    };

    copy_if_present("max_tokens", "max_tokens");
    copy_if_present("temperature", "temperature");
    copy_if_present("top_p", "top_p");
    copy_if_present("top_k", "top_k");
    copy_if_present("min_p", "min_p");
    copy_if_present("typical_p", "typical_p");
    copy_if_present("repeat_penalty", "repeat_penalty");
    copy_if_present("repeat_last_n", "repeat_last_n");
    copy_if_present("frequency_penalty", "frequency_penalty");
    copy_if_present("presence_penalty", "presence_penalty");
    copy_if_present("mirostat", "mirostat");
    copy_if_present("mirostat_tau", "mirostat_tau");
    copy_if_present("mirostat_eta", "mirostat_eta");
    copy_if_present("seed", "seed");
    copy_if_present("stop", "stop");
    copy_if_present("n_predict", "n_predict");
    copy_if_present("cache_prompt", "cache_prompt");
    copy_if_present("id_slot", "id_slot");
    copy_if_present("tools", "tools");
    copy_if_present("tool_choice", "tool_choice");
    copy_if_present("parallel_tool_calls", "parallel_tool_calls");
    copy_if_present("parse_tool_calls", "parse_tool_calls");
    copy_if_present("response_format", "response_format");
    copy_if_present("json_schema", "json_schema");
    copy_if_present("reasoning_format", "reasoning_format");
    copy_if_present("thinking_forced_open", "thinking_forced_open");
    copy_if_present("chat_template_kwargs", "chat_template_kwargs");

    if (options.has("stop_sequences") && !payload.has("stop")) {
        payload["stop"] = options["stop_sequences"];
    }
    if (options.get("output_json", false) && !payload.has("response_format")) {
        Dictionary rf;
        rf["type"] = String("json_object");
        payload["response_format"] = rf;
    }
    if (options.has("json_schema") && !payload.has("response_format")) {
        Dictionary rf;
        rf["type"] = String("json_schema");
        rf["schema"] = options["json_schema"];
        payload["response_format"] = rf;
    }
    if (options.has("server_extra_body") && options["server_extra_body"].get_type() == Variant::DICTIONARY) {
        merge_dictionary(payload, options["server_extra_body"]);
    }

    int timeout_seconds = options.get("server_timeout_seconds", options.get("server_timeout_sec", 120));
    PackedStringArray headers;
    headers.append(String("Content-Type: application/json"));
    String api_key = options.get("server_api_key", options.get("api_key", String()));
    if (!api_key.is_empty()) {
        headers.append(String("Authorization: Bearer ") + api_key);
    }

    HttpJsonResponse http = http_post_json(url, payload, headers, timeout_seconds);
    response["endpoint"] = url;
    response["status_code"] = static_cast<int64_t>(http.status_code);

    if (!http.ok) {
        response["error"] = String("http_request_failed");
        response["detail"] = http.error;
        response["raw"] = http.body;
        return response;
    }
    if (http.status_code < 200 || http.status_code >= 300) {
        response["error"] = String("http_status_error");
        response["raw"] = http.body;
        return response;
    }

    Variant parsed = JSON::parse_string(http.body);
    if (parsed.get_type() != Variant::DICTIONARY) {
        response["error"] = String("invalid_json_response");
        response["raw"] = http.body;
        return response;
    }

    Dictionary parsed_dict = parsed;
    response["response"] = parsed_dict;

    Dictionary first_choice;
    Variant tool_calls;
    String text = extract_chat_completion_text(parsed_dict, first_choice, tool_calls).strip_edges();

    if (text.is_empty() && parsed_dict.has("output_text")) {
        text = parsed_dict["output_text"];
    }
    if (text.is_empty() && parsed_dict.has("error")) {
        Variant error_variant = parsed_dict["error"];
        if (error_variant.get_type() == Variant::DICTIONARY) {
            Dictionary error_dict = error_variant;
            response["error"] = error_dict.get("message", String("server_error"));
        } else {
            response["error"] = String("server_error");
        }
        response["raw"] = http.body;
        return response;
    }

    response["ok"] = true;
    response["text"] = text;
    if (parsed_dict.has("id")) {
        response["id"] = parsed_dict["id"];
    }
    if (tool_calls.get_type() != Variant::NIL) {
        response["tool_calls"] = tool_calls;
    }
    if (parsed_dict.has("usage")) {
        response["usage"] = parsed_dict["usage"];
    }

    if (payload.has("response_format")) {
        Variant rf_variant = payload["response_format"];
        String rf_type;
        if (rf_variant.get_type() == Variant::DICTIONARY) {
            Dictionary rf = rf_variant;
            rf_type = rf.get("type", String());
        } else if (rf_variant.get_type() == Variant::STRING) {
            rf_type = rf_variant;
        }
        if (rf_type == String("json_object") || rf_type == String("json_schema")) {
            Variant parsed_json = parse_json_response(text);
            if (parsed_json.get_type() != Variant::NIL) {
                response["json"] = parsed_json;
            }
        }
    }

    return response;
}

bool AgentRuntime::ensure_sampler_locked(const Dictionary &options) {
    llama_sampler *sampler = create_sampler(options, model_);
    if (!sampler) {
        UtilityFunctions::push_error("AgentRuntime::ensure_sampler - failed to create sampler");
        return false;
    }
    sampler_.reset(sampler);
    llama_sampler_reset(sampler_.get());
    return true;
}

std::string AgentRuntime::build_prompt(const TypedArray<Dictionary> &history, const String &user_prompt) const {
    std::ostringstream oss;
    oss << to_utf8(system_prompt_) << "\n";
    for (int i = 0; i < history.size(); ++i) {
        Dictionary entry = history[i];
        String role = entry.get("role", String());
        String content = entry.get("content", String());
        oss << role.utf8().get_data() << ": " << content.utf8().get_data() << "\n";
    }
    if (!user_prompt.is_empty()) {
        oss << "user: " << user_prompt.utf8().get_data() << "\n";
    }
    oss << "assistant:";
    return oss.str();
}

std::string AgentRuntime::token_to_string(llama_token token) const {
    std::string buffer;
    buffer.resize(4096);
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        return std::string();
    }
    int written = llama_token_to_piece(vocab, token, buffer.data(), buffer.size(), 0, false);
    if (written < 0) {
        return std::string();
    }
    buffer.resize(written);
    return buffer;
}

bool AgentRuntime::load_model_locked(const String &path, const Dictionary &options, bool store_defaults) {
    unload_model_locked();

    llama_backend_init();

    llama_model_params model_params = llama_model_default_params();
    if (options.has("n_gpu_layers")) {
        model_params.n_gpu_layers = (int32_t)options["n_gpu_layers"];
    }
    if (options.has("use_mmap")) {
        model_params.use_mmap = (bool)options["use_mmap"];
    }
    if (options.has("use_mlock")) {
        model_params.use_mlock = (bool)options["use_mlock"];
    }

    model_ = llama_model_load_from_file(path.utf8().get_data(), model_params);
    if (!model_) {
        UtilityFunctions::push_error("AgentRuntime::load_model - failed to load: " + path);
        return false;
    }

    llama_context_params ctx_params = llama_context_default_params();
    int32_t model_ctx_train = llama_model_n_ctx_train(model_);
    if (model_ctx_train > 0) {
        ctx_params.n_ctx = model_ctx_train;
    }
    if (options.has("context_size")) {
        ctx_params.n_ctx = (int32_t)options["context_size"];
    }
    if (ctx_params.n_ctx <= 0) {
        ctx_params.n_ctx = 4096;
    }
    if (options.has("batch_size")) {
        ctx_params.n_batch = (int32_t)options["batch_size"];
    } else {
        ctx_params.n_batch = ctx_params.n_ctx;
    }
    if (ctx_params.n_batch <= 0) {
        ctx_params.n_batch = 512;
    }
    if (ctx_params.n_batch > ctx_params.n_ctx) {
        ctx_params.n_batch = ctx_params.n_ctx;
    }
    if (options.has("pooling")) {
        ctx_params.pooling_type = static_cast<enum llama_pooling_type>((int)options["pooling"]);
    }

    if (options.has("embedding")) {
        ctx_params.embeddings = (bool)options["embedding"];
    } else if (options.has("embeddings")) {
        ctx_params.embeddings = (bool)options["embeddings"];
    } else {
        ctx_params.embeddings = true;
    }

    context_ = llama_init_from_model(model_, ctx_params);
    if (!context_) {
        UtilityFunctions::push_error("AgentRuntime::load_model - failed to create context");
        unload_model_locked();
        return false;
    }

    if (store_defaults) {
        default_options_.clear();
        Array keys = options.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            default_options_[key] = options[key];
        }
        if (!default_options_.has("embedding")) {
            default_options_["embedding"] = ctx_params.embeddings;
        }
        if (!default_options_.has("context_size")) {
            default_options_["context_size"] = ctx_params.n_ctx;
        }
        if (!default_options_.has("batch_size")) {
            default_options_["batch_size"] = ctx_params.n_batch;
        }
    }

    Dictionary sampler_opts = store_defaults ? default_options_ : options;
    sampler_.reset();
    ensure_sampler_locked(sampler_opts);
    return true;
}

void AgentRuntime::unload_model_locked() {
    if (context_) {
        llama_free(context_);
        context_ = nullptr;
    }
    if (model_) {
        llama_model_free(model_);
        model_ = nullptr;
    }
    sampler_.reset();
    llama_backend_free();
}

void AgentRuntime::set_default_model_path(const String &path) {
    std::scoped_lock lock(mutex_);
    default_model_path_ = path;
}

String AgentRuntime::get_default_model_path() const {
    std::scoped_lock lock(mutex_);
    return default_model_path_;
}

void AgentRuntime::set_runtime_directory(const String &path) {
    std::scoped_lock lock(mutex_);
    runtime_directory_ = path;
}

String AgentRuntime::get_runtime_directory() const {
    std::scoped_lock lock(mutex_);
    return runtime_directory_;
}

void AgentRuntime::set_system_prompt(const String &prompt) {
    std::scoped_lock lock(mutex_);
    system_prompt_ = prompt;
}

String AgentRuntime::get_system_prompt() const {
    std::scoped_lock lock(mutex_);
    return system_prompt_;
}
