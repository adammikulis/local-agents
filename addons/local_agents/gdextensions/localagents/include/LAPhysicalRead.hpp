#ifndef LOCAL_AGENTS_LA_PHYSICAL_READ_HPP
#define LOCAL_AGENTS_LA_PHYSICAL_READ_HPP

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cmath>
#include <cstring>
#include <string>
#include <unordered_map>

namespace godot {

// PhysicalConstants.gd is the one declaration of every physical constant; this reads it, never copies it.
// NaN and a named error on a miss, so an absent constant cannot pass as a plausible value.
inline Dictionary la_physical_map() {
	static Dictionary constants;
	if (constants.is_empty()) {
		const Ref<Script> pc = ResourceLoader::get_singleton()->load(
				"res://addons/local_agents/sim/material/PhysicalConstants.gd");
		ERR_FAIL_COND_V_MSG(pc.is_null(), constants, "LAPhysical: PhysicalConstants.gd failed to load.");
		constants = pc->get_script_constant_map();
	}
	return constants;
}

// Each thread keeps the values it has read: a constant never changes, and the lookup is the cost. A call
// site names its constant by a literal, so the address finds it first and the name confirms it.
inline double la_physical(const char *p_name) {
	struct Seen {
		std::string name;
		double value;
	};
	thread_local std::unordered_map<const char *, Seen> by_address;
	const auto near_hit = by_address.find(p_name);
	if (near_hit != by_address.end() && std::strcmp(near_hit->second.name.c_str(), p_name) == 0) {
		return near_hit->second.value;
	}
	thread_local std::unordered_map<std::string, double> read;
	const auto hit = read.find(p_name);
	if (hit != read.end()) {
		by_address[p_name] = Seen{ p_name, hit->second };
		return hit->second;
	}
	const Dictionary constants = la_physical_map();
	ERR_FAIL_COND_V_MSG(!constants.has(p_name), NAN,
			String("LAPhysical carries no ") + p_name + ".");
	const double v = double(constants[p_name]);
	read.emplace(p_name, v);
	by_address[p_name] = Seen{ p_name, v };
	return v;
}

// A declared table of numbers, in doubles. Empty and named on a miss.
inline PackedFloat64Array la_physical_array(const char *p_name) {
	PackedFloat64Array out;
	const Dictionary constants = la_physical_map();
	ERR_FAIL_COND_V_MSG(!constants.has(p_name), out, String("LAPhysical carries no ") + p_name + ".");
	const Array a = constants[p_name];
	out.resize(a.size());
	for (int i = 0; i < a.size(); i++) {
		out.set(i, double(a[i]));
	}
	return out;
}

} // namespace godot

#endif // LOCAL_AGENTS_LA_PHYSICAL_READ_HPP
