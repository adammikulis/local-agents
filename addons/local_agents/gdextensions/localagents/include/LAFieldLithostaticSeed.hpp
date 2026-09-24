#ifndef LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// The seed-time serial walks that shape the matter the composition laid down: rock compressed under its
// own weight, and gas put where gas can be.
class LAFieldLithostaticSeed : public RefCounted {
	GDCLASS(LAFieldLithostaticSeed, RefCounted);

public:
	// THE SEEDED WORLD PUT INTO THE BALANCE THE STEPPER HOLDS: each cell's pressure off state_derive.glsl's
	// equation of state at the seed's temperatures, every phase at its own (T, p), and the column
	// pressure.glsl walks over the rock. Fluid its rock cannot confine is moved up the column. Returns the
	// pressure, the fluid's, the lattice's and the gas's room, per cell.
	static Dictionary compress(Object *p_field, const PackedFloat32Array &p_gravity, const PackedFloat32Array &p_t_rock);
	// THE VERTICAL A COLUMN STANDS ALONG. Only the hydrostatic rung stands one; below it there is no
	// vertical at all, and none is zero.
	static PackedFloat32Array vertical(Object *p_field, const PackedFloat32Array &p_gravity);
	// THE ATMOSPHERE IS THE BODY'S DECLARED INVENTORY, laid along the isothermal barometric law in the
	// solved potential, anchored at sea level, in the room the rock and the sea leave.
	static void shape_atmosphere(Object *p_field, double p_temp_c,
			const PackedFloat32Array &p_gravity, const PackedFloat64Array &p_phi);
	// The seeded atmosphere's mole fraction per gas channel, its R T / M, and the height at which its
	// barometric profile stops being a fluid at all.
	static Dictionary seeded_air_mole_fractions();
	static double seeded_air_rt_over_m(double p_temp_c);
	static double air_extent_m(const String &p_body_key, double p_radius_m, double p_temp_c,
			double p_cell_edge_m);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
