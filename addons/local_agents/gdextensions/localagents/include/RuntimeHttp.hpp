#pragma once
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
namespace local_agents::runtime {
struct HttpJsonResponse {
    bool ok = false;
    long status_code = 0;
    godot::String body;
    godot::String error;
};
HttpJsonResponse http_post_json(const godot::String &url, const godot::Dictionary &payload,
    const godot::PackedStringArray &headers, int timeout_seconds, const godot::Callable &progress = godot::Callable());
}
