#ifndef LOCAL_AGENTS_WORLD_SIMULATION_NATIVE_UTILS_HPP
#define LOCAL_AGENTS_WORLD_SIMULATION_NATIVE_UTILS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class LocalAgentsWorldSimulationNativeUtils : public RefCounted {
    GDCLASS(LocalAgentsWorldSimulationNativeUtils, RefCounted);

public:
    LocalAgentsWorldSimulationNativeUtils() = default;
    ~LocalAgentsWorldSimulationNativeUtils() override = default;

    Array build_mutation_glow_positions(const Dictionary &payload, double chunk_size) const;
    String sanitize_test_mode_id(const String &mode_id) const;
    String resolve_test_mode_from_user_args(const String &default_mode = String()) const;
    bool resolve_bool_flag_from_user_args(const String &flag_name, bool default_value) const;
    Dictionary runtime_profile_settings(const String &profile_id) const;
    String sanitize_runtime_demo_profile(const String &profile_id) const;

protected:
    static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_WORLD_SIMULATION_NATIVE_UTILS_HPP
