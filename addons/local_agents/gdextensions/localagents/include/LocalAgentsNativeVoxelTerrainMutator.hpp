#ifndef LOCAL_AGENTS_NATIVE_VOXEL_TERRAIN_MUTATOR_HPP
#define LOCAL_AGENTS_NATIVE_VOXEL_TERRAIN_MUTATOR_HPP

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>

namespace godot {

class LocalAgentsNativeVoxelTerrainMutator : public RefCounted {
    GDCLASS(LocalAgentsNativeVoxelTerrainMutator, RefCounted);

public:
    LocalAgentsNativeVoxelTerrainMutator() = default;
    ~LocalAgentsNativeVoxelTerrainMutator() override = default;

    Dictionary apply_native_voxel_stage_delta(Object *simulation_controller, int64_t tick, const Dictionary &payload);
    Dictionary apply_native_voxel_ops_payload(Object *simulation_controller, int64_t tick, const Dictionary &payload);
    Dictionary stamp_default_target_wall(Object *simulation_controller, int64_t tick, const Transform3D &camera_transform, const Variant &target_wall_profile = Variant());

protected:
    static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_NATIVE_VOXEL_TERRAIN_MUTATOR_HPP
