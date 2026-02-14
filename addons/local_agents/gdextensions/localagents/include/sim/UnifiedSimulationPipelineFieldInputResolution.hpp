#ifndef LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_HPP
#define LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace local_agents::simulation {

double as_scalar(const Variant &value);
String as_status_string(const Variant &value, const String &fallback);
bool as_bool(const Variant &value);

Dictionary resolve_stage_field_inputs(
    const Dictionary &frame_inputs,
    const Array &field_handles,
    bool field_handles_provided,
    Dictionary &stage_input_diagnostics,
    const godot::Dictionary &field_handle_cache);

bool is_pressure_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name);
void scrub_pressure_scalar_snapshot_inputs(
    Dictionary &pressure_stage_field_inputs,
    const Dictionary &stage_field_input_diagnostics);

bool is_mechanics_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name);
void scrub_mechanics_scalar_snapshot_inputs(
    Dictionary &mechanics_stage_field_inputs,
    const Dictionary &stage_field_input_diagnostics);

bool is_thermal_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name);
void scrub_thermal_scalar_snapshot_inputs(
    Dictionary &thermal_stage_field_inputs,
    const Dictionary &stage_field_input_diagnostics);

bool is_reaction_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name);
void scrub_reaction_scalar_snapshot_inputs(
    Dictionary &reaction_stage_field_inputs,
    const Dictionary &stage_field_input_diagnostics);

bool is_destruction_hot_frame_input_snapshot(
    const Dictionary &stage_field_input_diagnostics,
    const String &field_name);
void scrub_destruction_scalar_snapshot_inputs(
    Dictionary &destruction_stage_field_inputs,
    const Dictionary &stage_field_input_diagnostics);

bool pressure_stage_compatibility_fallback_enabled(const Dictionary &stage_config);

Dictionary summarize_physics_server_feedback(
    const Array &destruction_results,
    const Dictionary &field_evolution);

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_HPP
