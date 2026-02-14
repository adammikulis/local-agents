#ifndef LOCAL_AGENTS_ENVIRONMENT_STAGE_EXECUTOR_HPP
#define LOCAL_AGENTS_ENVIRONMENT_STAGE_EXECUTOR_HPP

#include "LocalAgentsSimulationInterfaces.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>

namespace local_agents::simulation {

class VoxelEditEngine;

godot::Dictionary execute_environment_stage_orchestration(
    const godot::StringName &stage_name,
    const godot::Dictionary &effective_payload,
    int64_t environment_stage_dispatch_count,
    const godot::Array &physics_contact_rows,
    IFieldRegistry *field_registry,
    IComputeManager *compute_manager,
    VoxelEditEngine *voxel_edit_engine,
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

#endif // LOCAL_AGENTS_ENVIRONMENT_STAGE_EXECUTOR_HPP
