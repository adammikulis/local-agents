#ifndef LOCAL_AGENTS_LA_FIELD_FILL_HPP
#define LOCAL_AGENTS_LA_FIELD_FILL_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// A FIELD WHOSE MATTER IS DECLARED, not walked off a terrain: one gas mixture in every cell of a field that
// holds no rock, at the amounts the derive's own equation of state states the declared pressure at.
class LAFieldFill : public RefCounted {
	GDCLASS(LAFieldFill, RefCounted);

public:
	static bool valid_spec(const Variant &p_fill);
	static String cache_key(const String &p_base, const Dictionary &p_fill, double p_temp_c);
	// mol/m^3 of the mixture whose one-fluid Peng-Robinson pressure, `LAPhaseEosFn::mixture_pressure`, is
	// `p_pressure_pa` at `p_temp_c`. NAN, with the reason pushed, where no fluid root stands there.
	static double gas_molar_density(const Dictionary &p_mole_fractions, double p_temp_c, double p_pressure_pa);
	// Every gas channel at its mole fraction of that density, in every cell, and every cell's `_t_rock` at
	// `p_temp_c`. False, with the reason pushed, where the field holds rock or the mixture names a channel
	// that is not a gas or does not sum to one.
	static bool lay_gas(Object *p_field, const Dictionary &p_mole_fractions, double p_temp_c, double p_pressure_pa);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_FILL_HPP
