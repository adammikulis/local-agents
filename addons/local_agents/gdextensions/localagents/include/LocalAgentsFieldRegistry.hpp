#ifndef LOCAL_AGENTS_FIELD_REGISTRY_HPP
#define LOCAL_AGENTS_FIELD_REGISTRY_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace local_agents::simulation {

struct LocalAgentsSparseFieldDescriptor {
    bool enabled = false;
    int64_t chunk_size = 0;
    godot::String deterministic_ordering_key;
};

struct LocalAgentsFieldSchemaMetadata {
    godot::String field_name;
    godot::String units;
    bool has_min = false;
    bool has_max = false;
    double min_value = 0.0;
    double max_value = 0.0;
    int64_t components = 1;
    godot::String layout = godot::String("soa");
    godot::PackedStringArray role_tags;
    LocalAgentsSparseFieldDescriptor sparse;
};

class LocalAgentsFieldRegistry final : public IFieldRegistry {
public:
    bool register_field(const godot::StringName &field_name, const godot::Dictionary &field_config) override;
    godot::Dictionary create_field_handle(const godot::StringName &field_name) override;
    godot::Dictionary resolve_field_handle(const godot::StringName &handle_id) const override;
    godot::Dictionary list_field_handles_snapshot() const override;
    bool configure(const godot::Dictionary &config) override;
    void clear() override;
    godot::Dictionary get_debug_snapshot() const override;

private:
    bool normalize_field_entry(
        const godot::String &field_name,
        const godot::Dictionary &field_config,
        godot::Dictionary &normalized_field_config,
        godot::Dictionary &normalized_schema
    ) const;
    bool collect_config_rows(const godot::Dictionary &config, godot::Array &rows) const;
    void rebuild_normalized_schema_rows();
    void refresh_field_handle_mappings();

    godot::Dictionary config_;
    godot::Dictionary field_configs_;
    godot::Dictionary normalized_schema_by_field_;
    godot::Array normalized_schema_rows_;
    godot::Array registration_order_;
    godot::Dictionary handle_by_field_;
    godot::Dictionary field_by_handle_;
    godot::Dictionary normalized_schema_by_handle_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_FIELD_REGISTRY_HPP
