#ifndef VOXEL_EDIT_OP_HPP
#define VOXEL_EDIT_OP_HPP

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>

namespace local_agents::simulation {

enum class VoxelEditDomain {
    Environment,
    Voxel,
};

struct VoxelCoordI {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
};

struct VoxelChunkCoordI {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
};

struct VoxelEditOp {
    uint64_t sequence_id = 0;
    VoxelEditDomain domain = VoxelEditDomain::Voxel;
    godot::StringName stage_name;
    VoxelCoordI voxel;
    godot::String operation;
    double value = 0.0;
};

} // namespace local_agents::simulation

#endif // VOXEL_EDIT_OP_HPP
