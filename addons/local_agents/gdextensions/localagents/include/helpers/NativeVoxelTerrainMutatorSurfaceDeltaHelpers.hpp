#ifndef NATIVE_VOXEL_TERRAIN_MUTATOR_SURFACE_DELTA_HELPERS_HPP
#define NATIVE_VOXEL_TERRAIN_MUTATOR_SURFACE_DELTA_HELPERS_HPP

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace local_agents::mutator::helpers {

godot::Dictionary apply_column_surface_delta(
    godot::Object *simulation_controller,
    godot::Dictionary &env_snapshot,
    const godot::Array &changed_tiles,
    const godot::Dictionary &height_overrides,
    bool raise_surface,
    const godot::Dictionary &column_metadata_overrides,
    bool include_snapshots
);

} // namespace local_agents::mutator::helpers

#endif // NATIVE_VOXEL_TERRAIN_MUTATOR_SURFACE_DELTA_HELPERS_HPP
