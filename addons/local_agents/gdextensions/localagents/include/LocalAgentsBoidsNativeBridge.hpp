#ifndef LOCAL_AGENTS_BOIDS_NATIVE_BRIDGE_HPP
#define LOCAL_AGENTS_BOIDS_NATIVE_BRIDGE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class LocalAgentsBoidsNativeBridge : public RefCounted {
    GDCLASS(LocalAgentsBoidsNativeBridge, RefCounted);

public:
    LocalAgentsBoidsNativeBridge() = default;
    ~LocalAgentsBoidsNativeBridge() override = default;

    Dictionary can_execute_boids_step(int64_t agent_count, const Dictionary &request = Dictionary()) const;
    Dictionary run_native_boids_step(const Dictionary &payload);
    Dictionary validate_boids_gpu_contract(const Dictionary &request) const;
    Dictionary make_boids_error_contract(int64_t agent_count, const String &error_code, const String &error_detail, int64_t workgroup_size, int64_t required_workgroups, int64_t max_workgroups_per_dispatch) const;

protected:
    static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_BOIDS_NATIVE_BRIDGE_HPP
