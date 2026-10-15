#include "RuntimeInferenceUtils.hpp"
#include "RuntimeStringUtils.hpp"
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;
namespace local_agents::runtime {
llama_sampler *create_sampler(const Dictionary &options, const llama_model *model) {
    const llama_vocab *vocab = model ? llama_model_get_vocab(model) : nullptr;
    if (!vocab) {
        return nullptr;
    }
    const int32_t n_vocab = llama_vocab_n_tokens(vocab);

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
        append_sampler(llama_sampler_init_penalties(
                n_vocab, repeat_last_n, repeat_penalty, frequency_penalty, presence_penalty));
    }

    int32_t mirostat_mode = options.get("mirostat", 0);
    if (mirostat_mode == 1) {
        int32_t mirostat_last_n = options.get("mirostat_m", 100);
        float tau = options.get("mirostat_tau", 5.0f);
        float eta = options.get("mirostat_eta", 0.1f);
        append_sampler(llama_sampler_init_mirostat(n_vocab, seed, tau, eta, mirostat_last_n));
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


}
