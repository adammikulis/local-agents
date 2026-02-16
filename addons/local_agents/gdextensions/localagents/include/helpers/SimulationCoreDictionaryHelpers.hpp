#ifndef SIMULATION_CORE_DICTIONARY_HELPERS_HPP
#define SIMULATION_CORE_DICTIONARY_HELPERS_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace local_agents::simulation::helpers {

bool extract_reference_from_dictionary(const godot::Dictionary &payload, godot::String &out_ref);
godot::Dictionary normalize_contact_row(const godot::Variant &raw_row);
godot::Array normalize_contact_rows(const godot::Array &contact_rows);
godot::Dictionary aggregate_contact_rows(const godot::Array &normalized_contact_rows);
godot::Dictionary normalize_and_aggregate_contact_rows(const godot::Array &contact_rows);
godot::Dictionary build_canonical_voxel_dispatch_contract(const godot::Dictionary &dispatch_payload);
godot::Array collect_input_field_handles(
    const godot::Dictionary &frame_inputs,
    local_agents::simulation::IFieldRegistry *registry,
    bool &did_inject_handles
);
godot::Dictionary maybe_inject_field_handles_into_environment_inputs(
    const godot::Dictionary &environment_payload,
    local_agents::simulation::IFieldRegistry *registry
);

} // namespace local_agents::simulation::helpers

#endif // SIMULATION_CORE_DICTIONARY_HELPERS_HPP
