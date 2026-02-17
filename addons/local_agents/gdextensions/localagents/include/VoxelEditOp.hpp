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
    godot::String shape = "sphere";
    double value = 0.0;
    double radius = 1.0;
    double cleave_normal_x = 0.0;
    double cleave_normal_y = 1.0;
    double cleave_normal_z = 0.0;
    double cleave_plane_offset = 0.0;
    int64_t noise_seed = 0;
    double noise_amplitude = 0.0;
    double noise_frequency = 0.0;
    int32_t noise_octaves = 0;
    double noise_lacunarity = 2.0;
    double noise_gain = 0.5;
    godot::String noise_mode = "none";
    godot::String projectile_material_tag = "dense_voxel";
};

} // namespace local_agents::simulation

#endif // VOXEL_EDIT_OP_HPP
