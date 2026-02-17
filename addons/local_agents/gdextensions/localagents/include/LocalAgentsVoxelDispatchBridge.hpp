#ifndef LOCAL_AGENTS_VOXEL_DISPATCH_BRIDGE_HPP
#define LOCAL_AGENTS_VOXEL_DISPATCH_BRIDGE_HPP

#include "LocalAgentsNativeVoxelTerrainMutator.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class LocalAgentsVoxelDispatchBridge : public RefCounted {
    GDCLASS(LocalAgentsVoxelDispatchBridge, RefCounted);

public:
    LocalAgentsVoxelDispatchBridge() = default;
    ~LocalAgentsVoxelDispatchBridge() override = default;

    Dictionary process_native_voxel_rate(double delta, const Dictionary &context);

protected:
    static void _bind_methods();

private:
    Ref<LocalAgentsNativeVoxelTerrainMutator> mutator_;
};

} // namespace godot

#endif // LOCAL_AGENTS_VOXEL_DISPATCH_BRIDGE_HPP
