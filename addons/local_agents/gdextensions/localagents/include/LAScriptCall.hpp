#ifndef LOCAL_AGENTS_LA_SCRIPT_CALL_HPP
#define LOCAL_AGENTS_LA_SCRIPT_CALL_HPP

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

// The static GDScript entry points native code still consults. One declaration: two copies of this meant
// two answers to "how does C++ reach a GDScript static", and a miss in either was silent.
inline Variant la_call_gd(const char *p_path, const StringName &p_method, const Array &p_args) {
	const Ref<Script> s = ResourceLoader::get_singleton()->load(p_path);
	ERR_FAIL_COND_V_MSG(s.is_null(), Variant(), String("la_call_gd: failed to load ") + p_path);
	return s->callv(p_method, p_args);
}

// A GDScript `const` off the same script. NaN-free: an absent name is an error, never a plausible value.
inline Variant la_gd_const(const char *p_path, const StringName &p_name) {
	const Ref<Script> s = ResourceLoader::get_singleton()->load(p_path);
	ERR_FAIL_COND_V_MSG(s.is_null(), Variant(), String("la_gd_const: failed to load ") + p_path);
	const Dictionary consts = s->get_script_constant_map();
	ERR_FAIL_COND_V_MSG(!consts.has(p_name), Variant(),
			String(p_path) + " declares no " + String(p_name) + ".");
	return consts[p_name];
}

} // namespace godot

#endif // LOCAL_AGENTS_LA_SCRIPT_CALL_HPP
