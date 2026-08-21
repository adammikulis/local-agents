#ifndef LOCAL_AGENTS_LA_PHYSICAL_READ_HPP
#define LOCAL_AGENTS_LA_PHYSICAL_READ_HPP

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cmath>

namespace godot {

// PhysicalConstants.gd is the one declaration of every physical constant; this reads it, never copies it.
// NaN and a named error on a miss, so an absent constant cannot pass as a plausible value.
inline double la_physical(const char *p_name) {
	static Dictionary constants;
	if (constants.is_empty()) {
		const Ref<Script> pc = ResourceLoader::get_singleton()->load(
				"res://addons/local_agents/sim/material/PhysicalConstants.gd");
		ERR_FAIL_COND_V_MSG(pc.is_null(), NAN, "LAPhysical: PhysicalConstants.gd failed to load.");
		constants = pc->get_script_constant_map();
	}
	ERR_FAIL_COND_V_MSG(!constants.has(p_name), NAN,
			String("LAPhysical carries no ") + p_name + ".");
	return double(constants[p_name]);
}

} // namespace godot

#endif // LOCAL_AGENTS_LA_PHYSICAL_READ_HPP
