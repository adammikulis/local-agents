#include "AgentRuntime.hpp"
#include "RuntimeInferenceUtils.hpp"
#include "RuntimeStringUtils.hpp"
#include "RuntimeChatPrompt.hpp"
#include "RuntimeStreamText.hpp"
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <sstream>
#include <stdexcept>

using namespace godot;
using namespace local_agents::runtime;

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

    std::vector<ChatMessage> messages;
    for (int i = 0; i < history.size(); ++i) {
        Dictionary entry = history[i];
        messages.push_back({to_utf8(entry.get("role", String())), to_utf8(entry.get("content", String()))});
    }
    std::string prompt_text;
    std::string prompt_error;
    if (!format_chat_prompt(llama_model_chat_template(model_, nullptr), std::move(messages),
                            to_utf8(get_system_prompt()), to_utf8(prompt), prompt_text, prompt_error)) {
        response["ok"] = false;
        response["error"] = from_utf8(prompt_error);
        return response;
    }

    const bool add_bos = true;
    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (!vocab) {
        response["ok"] = false;
        response["error"] = "vocab_unavailable";
        return response;
    }

    std::vector<llama_token> tokens_prompt;
    if (!tokenize_text(vocab, prompt_text, add_bos, true, tokens_prompt)) {
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

    Callable progress = request.get("stream_callback", Callable());
    std::string previous_preview;
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

        if (progress.is_valid()) {
            std::string preview = stream_preview(generated_snapshot, stop_sequences);
            if (preview != previous_preview) {
                progress.call_deferred(String::utf8(preview.c_str()));
                previous_preview = preview;
            }
        }
        llama_batch cont = llama_batch_get_one(&token, 1);
        if (llama_decode(context_, cont)) {
            response["ok"] = false;
            response["error"] = "llama_decode_failed";
            return response;
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
    if (options.has("load_mode")) {
        String mode = options["load_mode"];
        try {
            model_params.load_mode = llama_load_mode_from_str(mode.utf8().get_data());
        } catch (const std::invalid_argument &) {
            UtilityFunctions::push_error("AgentRuntime::load_model - unknown load_mode: " + mode);
            return false;
        }
    }

    llama_model *loaded_model = llama_model_load_from_file(path.utf8().get_data(), model_params);
    {
        std::scoped_lock lock(residency_mutex_);
        model_ = loaded_model;
    }
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

    llama_context *loaded_context = llama_init_from_model(model_, ctx_params);
    {
        std::scoped_lock lock(residency_mutex_);
        context_ = loaded_context;
        if (loaded_context) loaded_model_path_ = path;
    }
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
    llama_model *model;
    llama_context *context;
    {
        std::scoped_lock lock(residency_mutex_);
        model = model_;
        context = context_;
        model_ = nullptr;
        context_ = nullptr;
        loaded_model_path_ = String();
    }
    sampler_.reset();
    if (context) llama_free(context);
    if (model) llama_model_free(model);
    llama_backend_free();
}
