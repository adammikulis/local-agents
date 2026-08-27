#ifndef LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP
#define LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// THE ONE WALK FROM CHANNELS TO KILOGRAMS. A channel amount is mol/m^3, so a cell's mass is the sum over
// every matter channel of amount * molar mass * that cell's own volume.
class LAFieldCellMass3D : public RefCounted {
	GDCLASS(LAFieldCellMass3D, RefCounted);

public:
	// Kilograms per LASubstances id in one cell, and the moles of gas in it.
	static Dictionary masses_at(Object *p_field, int p_c, double p_cell_m3);
	static double gas_moles_at(Object *p_field, int p_c, double p_cell_m3);
	// [mirror array, molar mass kg/mol] for every channel the field carries as an amount of matter.
	static Array mirrors(Object *p_field);
	// The channel names mirrors() returned, in the same order, so a per-mirror total can be named.
	static PackedStringArray mirror_names(Object *p_field);
	// The same, restricted to the channels that are gas: a mixture's specific gas constant is R over the
	// mole-weighted molar mass of what is actually in the air.
	static Array gas_mirrors(Object *p_field);
	// Moles per m^3 summed into kilograms per m^3 for one cell. Times the cell's own volume is its mass.
	static double kg_m3_at(const Array &p_mirrors, int p_c);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP
