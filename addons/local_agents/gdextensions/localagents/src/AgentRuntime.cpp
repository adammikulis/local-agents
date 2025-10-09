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

Dictionary AgentRuntime::generate(const Dictionary &request) {
    std::scoped_lock lock(mutex_);

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

    int token_capacity = llama_tokenize(vocab, input.c_str(), static_cast<int32_t>(input.length()), nullptr, 0, add_bos, false);
    if (token_capacity <= 0) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - tokenization failed");
        return empty;
    }

    std::vector<llama_token> tokens(static_cast<size_t>(token_capacity));
    llama_tokenize(vocab, input.c_str(), static_cast<int32_t>(input.length()), tokens.data(), token_capacity, add_bos, false);

    llama_memory_clear(llama_get_memory(context_), true);

    llama_batch batch = llama_batch_get_one(tokens.data(), token_capacity);

    if (llama_decode(context_, batch) != 0) {
        UtilityFunctions::push_error("AgentRuntime::embed_text - llama_decode failed");
        return empty;
    }

    const float *embedding_ptr = nullptr;
    switch (llama_pooling_type(context_)) {
        case LLAMA_POOLING_TYPE_NONE:
            embedding_ptr = llama_get_embeddings(context_);
            if (!embedding_ptr) {
                embedding_ptr = llama_get_embeddings_ith(context_, token_capacity - 1);
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

    int token_capacity = llama_tokenize(vocab, prompt_text.c_str(), static_cast<int32_t>(prompt_text.length()), nullptr, 0, add_bos, false);
    if (token_capacity <= 0) {
        response["ok"] = false;
        response["error"] = "tokenization_failed";
        return response;
    }

    std::vector<llama_token> tokens_prompt(static_cast<size_t>(token_capacity));
    llama_tokenize(vocab, prompt_text.c_str(), static_cast<int32_t>(prompt_text.length()), tokens_prompt.data(), token_capacity, add_bos, false);

    llama_batch batch = llama_batch_get_one(tokens_prompt.data(), token_capacity);

    if (llama_decode(context_, batch)) {
        response["ok"] = false;
        response["error"] = "llama_decode_failed";
        return response;
    }

    int max_tokens = options.get("max_tokens", 256);

    std::ostringstream generated;
    for (int i = 0; i < max_tokens; ++i) {
        llama_token token = llama_sampler_sample(sampler_.get(), context_, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }
        generated << token_to_string(token);

        llama_batch cont = llama_batch_get_one(&token, 1);
        if (llama_decode(context_, cont)) {
            UtilityFunctions::push_warning("llama_decode failed during continuation");
            break;
        }
    }

    String text = String::utf8(generated.str().c_str()).strip_edges();
    response["ok"] = true;
    response["text"] = text;
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
    if (options.has("context_size")) {
        ctx_params.n_ctx = (int32_t)options["context_size"];
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
