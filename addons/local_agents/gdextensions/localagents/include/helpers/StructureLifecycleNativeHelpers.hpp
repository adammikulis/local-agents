#ifndef LOCAL_AGENTS_STRUCTURE_LIFECYCLE_NATIVE_HELPERS_HPP
#define LOCAL_AGENTS_STRUCTURE_LIFECYCLE_NATIVE_HELPERS_HPP

#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>

namespace local_agents::simulation::helpers {

godot::Dictionary step_structure_lifecycle_native(
    int64_t step_index,
    const godot::Dictionary &lifecycle_payload
);

} // namespace local_agents::simulation::helpers

#endif // LOCAL_AGENTS_STRUCTURE_LIFECYCLE_NATIVE_HELPERS_HPP
