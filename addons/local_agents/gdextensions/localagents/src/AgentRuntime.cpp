#include "AgentRuntime.hpp"

#include "ModelDownloadManager.hpp"
#include "RuntimeStringUtils.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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

using namespace godot;
using local_agents::runtime::to_utf8;

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
