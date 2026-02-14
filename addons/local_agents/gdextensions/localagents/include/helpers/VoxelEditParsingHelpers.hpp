#ifndef VOXEL_EDIT_PARSING_HELPERS_HPP
#define VOXEL_EDIT_PARSING_HELPERS_HPP

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>

namespace local_agents::simulation::helpers {

bool parse_int32_variant(const godot::Variant &value, int32_t &out);
bool parse_double_variant(const godot::Variant &value, double &out);
bool parse_fracture_shape(const godot::String &shape, godot::String &out_shape);
bool parse_vector3_variant(const godot::Variant &value, double &out_x, double &out_y, double &out_z);
godot::Dictionary build_point_dict(int32_t x, int32_t y, int32_t z);

} // namespace local_agents::simulation::helpers

#endif // VOXEL_EDIT_PARSING_HELPERS_HPP
