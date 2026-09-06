#ifndef LOCAL_AGENTS_LA_PLANET_TABLES_HPP
#define LOCAL_AGENTS_LA_PLANET_TABLES_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
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
	static Dictionary surface_fractions(Object *p_grid, Object *p_terrain, const Vector3 &p_centre, double p_sea_r);
	static PackedByteArray solid_of(const PackedFloat32Array &p_fraction);
	static PackedFloat32Array surface_depth(Object *p_grid, Object *p_terrain, const Vector3 &p_centre);
	static double sea_level_m(double p_r_m, double p_ocean_m3, const PackedFloat64Array &p_area_below, const PackedFloat64Array &p_elevation_m);
	// THE WATER TABLE, m above the sea: the one equipotential a connected aquifer stands at, solved so the
	// pore space it saturates over the sea holds p_groundwater_m3. Capped at the ground by its consumer.
	static double water_table_m(double p_r_m, double p_groundwater_m3, double p_sea_level_m,
			const PackedFloat64Array &p_area_below, const PackedFloat64Array &p_elevation_m);
	// The crust under a square footprint at one direction: highest over the settled level, deepest under
	// it, and the share of the reading under it. `p_surface` answers surface_radius(dir).
	static Dictionary footprint_ground(Object *p_surface, const Vector3 &p_dir, double p_body_r_m,
			double p_sea_r_m, double p_footprint_m);
	// Where to stand a box so it holds a shore, as a direction plus that footprint reading.
	static Dictionary coast_site(Object *p_surface, double p_body_r_m, double p_sea_r_m,
			double p_footprint_m);
	// WHERE A SLICE BOX STANDS AND HOW IT SITS THERE: the body-frame direction, the cell counts with the
	// box's long axis on its local vertical, and the crust reading under its footprint. A coast box asks
	// the terrain where the shore is; any other stands on the axis its offset already names. {"error"}
	// when the terrain cannot answer. `p_terrain` answers coast_site_dir and footprint_ground.
	static Dictionary site_box(Object *p_terrain, bool p_coast, const Vector3 &p_offset,
			const Vector3i &p_dims, double p_cell_m, int p_surface_axis);
	static double radius_for_mass(double p_mass_kg, double p_t_c);
	static double core_radius_m(double p_radius_m, double p_t_c);
	// Depth of the conductive lid, metres: where its geotherm meets the mantle adiabat.
	static double lid_thickness_m(double p_radius_m, double p_t_c);
	static Dictionary body_field(Object *p_grid, const Vector3 &p_centre, double p_radius_m, double p_t_c);
	static Dictionary upload_body_field(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_grid,
			const Vector3 &p_centre, double p_radius_m, double p_t_c);
	static PackedFloat32Array geotherm_k(double p_radius_m, double p_t_c);
	// W/m^2 the body's own radiogenic decay drives through its surface.
	static double surface_heat_flux_w_m2(double p_mass_kg, double p_radius_m);
	// Peridotite's solidus and liquidus at the potential-temperature reference pressure, C, and the
	// potential temperature whose melt fraction between them is the rheological transition, K.
	static PackedFloat64Array peridotite_melting_interval_c();
	static double mantle_potential_temp_k();
	static void seed(Object *p_field, double p_t_c, const PackedFloat32Array &p_t_rock);

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
