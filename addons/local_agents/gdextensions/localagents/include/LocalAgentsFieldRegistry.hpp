#ifndef LOCAL_AGENTS_FIELD_REGISTRY_HPP
#define LOCAL_AGENTS_FIELD_REGISTRY_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace local_agents::simulation {

class LocalAgentsFieldRegistry final : public IFieldRegistry {
public:
    bool register_field(const godot::StringName &field_name, const godot::Dictionary &field_config) override;
    bool configure(const godot::Dictionary &config) override;
    void clear() override;
    godot::Dictionary get_debug_snapshot() const override;

private:
    godot::Dictionary config_;
    godot::Dictionary field_configs_;
    godot::Array registration_order_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_FIELD_REGISTRY_HPP
