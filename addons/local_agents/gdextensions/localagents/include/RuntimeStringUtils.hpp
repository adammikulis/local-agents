#ifndef LOCAL_AGENTS_RUNTIME_STRING_UTILS_HPP
#define LOCAL_AGENTS_RUNTIME_STRING_UTILS_HPP

#include <godot_cpp/variant/string.hpp>

#include <string>

namespace local_agents::runtime {

inline std::string to_utf8(const godot::String &value) {
    return std::string(value.utf8().get_data());
}

inline godot::String from_utf8(const std::string &value) {
    return godot::String::utf8(value.c_str());
}

} // namespace local_agents::runtime

#endif // LOCAL_AGENTS_RUNTIME_STRING_UTILS_HPP
