#ifndef SIMULATION_FAILURE_EMISSION_PLANNER_HPP
#define SIMULATION_FAILURE_EMISSION_PLANNER_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace local_agents::simulation {

godot::Dictionary build_voxel_failure_emission_plan(
    const godot::Dictionary &pipeline_feedback,
    const godot::Array &contact_rows,
    double impact_signal_gain,
    double watch_signal_threshold,
    double active_signal_threshold,
    double fracture_radius_base,
    double fracture_radius_gain,
    double fracture_radius_max,
    double fracture_value_softness,
    double fracture_value_cap
);

} // namespace local_agents::simulation

#endif // SIMULATION_FAILURE_EMISSION_PLANNER_HPP
