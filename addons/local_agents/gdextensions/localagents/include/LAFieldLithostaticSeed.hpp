#ifndef LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_LITHOSTATIC_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// The seed-time serial walks that shape the matter the composition laid down: rock compressed under its
// own weight, and gas put where gas can be.
class LAFieldLithostaticSeed : public RefCounted {
	GDCLASS(LAFieldLithostaticSeed, RefCounted);

public:
	// THE SEEDED WORLD PUT INTO THE BALANCE THE STEPPER HOLDS: each cell's pressure off state_derive.glsl's
	// equation of state at the seed's temperatures, every phase at its own (T, p), the column pressure.glsl
	// walks over the rock, a porous rock's grains sized at the load they stand under, and a locked cell's
	// fluid at its own equation of state in the room they leave. `p_g_rest` is the derive's own gravity.
	// Returns the pressure, the fluid's, the lattice's and the gas's room, per cell.
	// Given `p_pore_air`, each cell's share of its air in its dry pores, every regolith cell's porosity is
	// closed at the effective load its own state carries, and its pore water and pore air with it.
	static Dictionary compress(Object *p_field, const PackedFloat32Array &p_g_rest, const PackedFloat32Array &p_t_rock,
			const PackedFloat32Array &p_pore_air = PackedFloat32Array());
	// THE PORES AT THE LOAD THEY STAND UNDER: the air and the water laid into the room the regolith's porosity
	// leaves, and the world compressed with that porosity closed at its own load. Empty where no state holds.
	static Dictionary settle(Object *p_field, double p_temp_c, const PackedFloat32Array &p_g_rest,
			const PackedFloat64Array &p_phi, const PackedFloat32Array &p_t_rock);
	// THE VERTICAL A COLUMN STANDS ALONG. Only the hydrostatic rung stands one; below it there is no
	// vertical at all, and none is zero.
	static PackedFloat32Array vertical(Object *p_field, const PackedFloat32Array &p_gravity);
	// THE ATMOSPHERE IS THE BODY'S DECLARED INVENTORY, laid along the isothermal barometric law in the
	// solved potential, anchored at sea level, in the room the rock and the sea leave and the pores the
	// water table leaves dry, where the hydrostatic rung stands a vertical. Returns that law, {"phi_0",
	// "p_0", "rt_over_m"}; empty where none is laid.
	static Dictionary shape_atmosphere(Object *p_field, double p_temp_c,
			const PackedFloat32Array &p_g_rest, const PackedFloat64Array &p_phi);
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
