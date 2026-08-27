#ifndef LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// The seed-time serial walks that shape the matter the composition laid down: rock compressed under its
// own weight, and gas put where gas can be.
class LAFieldLithostaticSeed : public RefCounted {
	GDCLASS(LAFieldLithostaticSeed, RefCounted);

public:
	// Rock at depth is COMPRESSED. Integrates the hydrostatic profile of the mass just laid down -
	// g(r) = G M(<r) / r^2 over radial bins, p inward from the surface - and squeezes each lithic phase by
	// the substance table's own equation of state. Returns the fill added.
	static double compress(Object *p_field);
	// FREE GAS DOES NOT SIT INSIDE STONE. The channels are filled before solidity is sampled, so every
	// solid cell is handed a full atmosphere's worth of gas: matter in cells that have no room for it.
	static void clear_gas_in_rock(Object *p_field);
	// AN ATMOSPHERE IS A SHELL ON A SURFACE, not a uniform fill of the box: gas falls off with altitude by
	// the barometric relation about the mean solid radius, every quantity of it measured off the matter.
	static void shape_atmosphere(Object *p_field, double p_temp_c, Object *p_measure);
	// POURED WATER DISPLACES THE GAS: liquid holding an atmosphere's worth of gas in no free volume is a
	// pressure bomb, not a sea.
	static void displace_gas_from_water(Object *p_field);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
