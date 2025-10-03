#include "AgentRuntime.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <llama.h>

#include <cmath>
#include <cstring>
#include <filesystem>
#include <sstream>
#include <vector>

using namespace godot;

namespace {
std::string to_utf8(const String &value) {
    return std::string(value.utf8().get_data());
}

llama_sampler *create_sampler(const Dictionary &options) {
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
        seed = static_cast<uint32_t>((int64_t)options["seed"]);
    }

    if (use_distribution) {
        append_sampler(llama_sampler_init_dist(seed));
    } else {
        append_sampler(llama_sampler_init_greedy());
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

    ClassDB::bind_method(D_METHOD("set_default_model_path", "path"), &AgentRuntime::set_default_model_path);
    ClassDB::bind_method(D_METHOD("get_default_model_path"), &AgentRuntime::get_default_model_path);
    ClassDB::bind_method(D_METHOD("set_runtime_directory", "path"), &AgentRuntime::set_runtime_directory);
    ClassDB::bind_method(D_METHOD("get_runtime_directory"), &AgentRuntime::get_runtime_directory);
    ClassDB::bind_method(D_METHOD("set_system_prompt", "prompt"), &AgentRuntime::set_system_prompt);
    ClassDB::bind_method(D_METHOD("get_system_prompt"), &AgentRuntime::get_system_prompt);

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

    int token_capacity = llama_tokenize(vocab, prompt_text.c_str(), (int32_t)prompt_text.length(), nullptr, 0, add_bos, false);
    if (token_capacity <= 0) {
        response["ok"] = false;
        response["error"] = "tokenization_failed";
        return response;
    }

    std::vector<llama_token> tokens_prompt(token_capacity);
    llama_tokenize(vocab, prompt_text.c_str(), (int32_t)prompt_text.length(), tokens_prompt.data(), token_capacity, add_bos, false);

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
    llama_sampler *sampler = create_sampler(options);
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
