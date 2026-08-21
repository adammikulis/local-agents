#ifndef LOCAL_AGENTS_LA_PLANET_TABLES_HPP
#define LOCAL_AGENTS_LA_PLANET_TABLES_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Elemental composition of the planet's reservoirs, kg of element per kg of reservoir.
// McDonough 2003, Treatise on Geochemistry 2.15 (Tables 1-4); silicate Earth cross-checked against
// McDonough & Sun 1995, Chem. Geol. 120:223, Table 5. Ported from GDScript per HANDOFF item 5;
// PhysicalConstants.gd stays the SSOT for every constant this reads.
class LAElementAbundances : public RefCounted {
	GDCLASS(LAElementAbundances, RefCounted);

public:
	static double core_mass_fraction();
	static Dictionary bulk_earth();
	static Dictionary silicate_earth();
	static Dictionary core();
	static PackedStringArray shell_formula_elements();
	static PackedStringArray core_formula_elements();
	static double atomic_mass(const String &p_el);
	static double molar_mass(const Dictionary &p_formula);
	static Dictionary mass_fractions(const Dictionary &p_formula);
	static Dictionary shell_traces();
	static Dictionary core_traces();

protected:
	static void _bind_methods();
};

// The seeded planet's mineralogy, DERIVED from LAElementAbundances: a CIPW-style normative solve turns
// the silicate-Earth element budget into mineral proportions, and the core model into the metal alloy.
class LAPlanetComposition : public RefCounted {
	GDCLASS(LAPlanetComposition, RefCounted);

public:
	static PackedStringArray shell_channels();
	static double mg_number();
	static double an_fraction();
	static double apatite_f_fraction();
	static Dictionary olivine_formula();
	static Dictionary pyroxene_formula();
	static Dictionary plagioclase_formula();
	static Dictionary apatite_formula();
	static Dictionary metal_formula();
	static Dictionary shell_minerals();
	static double shell_density(double p_t_c, double p_p_pa);
	static double core_radius_frac(double p_t_c, double p_p_pa);
	static void seed(Object *p_field, double p_t_c);

protected:
	static void _bind_methods();
};

// Radiogenic heat and daughter accumulation of the U/Th/K traces, quoted at present-day abundances.
class LARadiogenicDecay : public RefCounted {
	GDCLASS(LARadiogenicDecay, RefCounted);

public:
	static double epoch_years();
	static Dictionary nuclides(const Dictionary &p_traces);
	static double heat_w_kg_of(const Dictionary &p_traces, double p_years);
	static Dictionary daughters_mol_per_kg(const Dictionary &p_traces, double p_years);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_PLANET_TABLES_HPP
