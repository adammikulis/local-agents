#pragma once

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <llama.h>
#include <string>
#include <vector>

namespace local_agents::runtime {
llama_sampler *create_sampler(const godot::Dictionary &options, const llama_model *model);
bool tokenize_text(const llama_vocab *vocab, const std::string &text, bool add_bos,
                   bool parse_special, std::vector<llama_token> &out_tokens);
bool apply_stop_sequences(std::string &text, const std::vector<std::string> &stops);
godot::Variant parse_json_response(const godot::String &text);
bool validate_json_schema_basic(const godot::Variant &parsed, const godot::Dictionary &schema,
                                godot::String &reason);
}
