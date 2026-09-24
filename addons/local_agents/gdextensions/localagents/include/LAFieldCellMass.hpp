#ifndef LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP
#define LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

class LAFieldMirrors;

// THE ONE WALK FROM CHANNELS TO KILOGRAMS. A channel amount is mol/m^3, so a cell's mass is the sum over
// every matter channel of amount * molar mass * that cell's own volume.
class LAFieldCellMass3D : public RefCounted {
	GDCLASS(LAFieldCellMass3D, RefCounted);

public:
	// Kilograms per LASubstances id in one cell, and the moles of gas in it.
	static Dictionary masses_at(Object *p_field, int p_c, double p_cell_m3);
	// The regolith walk's products onto the device: the permeable mask as floats, grain size and Athy
	// porosity, each only when the walk produced it.
	static void upload_regolith(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_field);
	static void upload_solid(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_field);
	// The regolith walk: the permeable mask, Athy porosity and grain size of the rock within the
	// circulation depth of its ground, and the pores opened in its grains. Writes _regolith, _grain,
	// _porosity and the lithic channels.
	static void regolith(Object *p_field);
	static double gas_moles_at(Object *p_field, int p_c, double p_cell_m3);
	// [mirror array, molar mass kg/mol] for every channel the field carries as an amount of matter.
	static Array mirrors(Object *p_field);
	// The channel names mirrors() returned, in the same order, so a per-mirror total can be named.
	static PackedStringArray mirror_names(Object *p_field);
	// THE ENTHALPY SEED, one pass over every cell: each ladder entry off its own curve at the cell's geotherm
	// temperature (p_t_rock, C) and the pressures and gas room LAFieldLithostaticSeed.compress solved
	// (p_balance: "fluid", "rock", "room"). Writes e_j_m3 and e_lith_j_m3; every joule is declared to the seal.
	static void seed_enthalpy(Object *p_field, const PackedFloat32Array &p_t_rock, const Dictionary &p_balance);
	// [channel name, molar mass kg/mol] for every mol_m3 channel the field's mirrors hold, in mirrors() order.
	static Array mass_channels(Object *p_field);
	// Moles per m^3 summed into kilograms per m^3 for one cell. Times the cell's own volume is its mass.
	static double kg_m3_at(LAFieldMirrors *p_mirrors, const Array &p_channels, int p_c);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_CELL_MASS_HPP
