#ifndef LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_INTERNAL_HPP
#define LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_INTERNAL_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace local_agents::simulation::unified_pipeline {

inline godot::Dictionary make_dictionary() {
    return godot::Dictionary();
}

template <typename K, typename V, typename... Rest>
godot::Dictionary make_dictionary(const K &key, const V &value, const Rest &...rest) {
    godot::Dictionary dict = make_dictionary(rest...);
    dict[godot::Variant(key)] = godot::Variant(value);
    return dict;
}

godot::Array default_required_channels();

double clamped(const godot::Variant &value, double min_v, double max_v, double fallback);
double pressure_window_factor(double pressure, double min_pressure, double max_pressure, double optimal_pressure);

godot::Dictionary boundary_contract(const godot::Dictionary &stage_config, const godot::Dictionary &frame_inputs);
godot::Dictionary stage_total_template(const godot::String &stage_type);
void append_conservation(godot::Dictionary &totals, const godot::String &stage_type, const godot::Dictionary &stage_result);
void aggregate_overall_conservation(godot::Dictionary &diagnostics);

godot::Dictionary run_field_buffer_evolution(
    const godot::Dictionary &config,
    const godot::Array &mechanics_stages,
    const godot::Array &pressure_stages,
    const godot::Array &thermal_stages,
    const godot::Dictionary &frame_inputs,
    double delta_seconds);

} // namespace local_agents::simulation::unified_pipeline

#endif // LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_INTERNAL_HPP
