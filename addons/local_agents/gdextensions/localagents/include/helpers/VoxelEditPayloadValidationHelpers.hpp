#ifndef VOXEL_EDIT_PAYLOAD_VALIDATION_HELPERS_HPP
#define VOXEL_EDIT_PAYLOAD_VALIDATION_HELPERS_HPP

#include "VoxelEditOp.hpp"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace local_agents::simulation::helpers {

bool is_valid_operation(const godot::String &operation);
bool parse_stage_domain(const godot::String &stage_domain, VoxelEditDomain &domain_out);
bool parse_op_payload(
    const godot::String &stage_domain,
    const godot::StringName &stage_name,
    const godot::Dictionary &op_payload,
    VoxelEditOp &op_out,
    godot::String &error_code_out
);

} // namespace local_agents::simulation::helpers

#endif // VOXEL_EDIT_PAYLOAD_VALIDATION_HELPERS_HPP
