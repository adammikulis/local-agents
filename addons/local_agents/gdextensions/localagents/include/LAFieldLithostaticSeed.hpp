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
	// THE SEEDED WORLD PUT INTO THE BALANCE THE STEPPER HOLDS. Marches flux.glsl's own face-pressure
	// relation cell by cell along the solved gravity: an open cell's amounts are scaled until its equation
	// of state states the marched pressure, a solid cell's lithic phases are squeezed by the substance
	// table at the pressure standing over them. Returns the pressure it marched, per cell.
	static PackedFloat32Array compress(Object *p_field, const PackedFloat32Array &p_gravity);
	// THE VERTICAL A COLUMN STANDS ALONG. Only the hydrostatic rung stands one; below it there is no
	// vertical at all, and none is zero.
	static PackedFloat32Array vertical(Object *p_field, const PackedFloat32Array &p_gravity);
	// FREE GAS DOES NOT SIT INSIDE STONE. The channels are filled before solidity is sampled, so every
	// solid cell is handed a full atmosphere's worth of gas: matter in cells that have no room for it.
	static void clear_gas_in_rock(Object *p_field);
	// AN ATMOSPHERE IS A SHELL ON A SURFACE, not a uniform fill of the box: gas falls off with altitude by
	// the barometric relation about the mean solid radius, every quantity of it measured off the matter.
	static void shape_atmosphere(Object *p_field, double p_temp_c, Object *p_measure,
			const PackedFloat32Array &p_gravity, const PackedFloat64Array &p_phi);
	// POURED WATER DISPLACES THE GAS: liquid holding an atmosphere's worth of gas in no free volume is a
	// pressure bomb, not a sea.
	static void displace_gas_from_water(Object *p_field);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
