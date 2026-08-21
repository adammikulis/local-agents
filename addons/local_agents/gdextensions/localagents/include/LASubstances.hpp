#ifndef LOCAL_AGENTS_LA_SUBSTANCES_HPP
#define LOCAL_AGENTS_LA_SUBSTANCES_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// THE SSOT FOR MATTER. One entry per substance, carrying its own measured properties; every phase
// boundary, enthalpy and density below is derived from that entry, never stored on a cell.
// LAPhysical stays the one declaration of what is not a property of a substance.
class LASubstances : public RefCounted {
	GDCLASS(LASubstances, RefCounted);

public:
	// Phase, DERIVED from energy and mass -- never stored.
	enum Phase {
		SOLID = 0,
		LIQUID = 1,
		GAS = 2,
		ATOMS = 3,
		PLASMA = 4,
		SUPERCRITICAL = 5,
	};

	static Dictionary table();

	static double fresh_litter_per_carbon(const String &p_element);
	static double organic_energy_j_mol(const String &p_element);
	static Vector3 organic_oxidation_parts();

	static double latent_sublimation_j_kg(const String &p_id);
	static bool has_eos(const String &p_id);
	static double density(const String &p_id, double p_t_c, double p_p_pa);
	static double full_mol_m3(const String &p_id);

	static double enthalpy_at(const String &p_id, double p_t_c, double p_p_pa, double p_molality_mol_kg);
	static Dictionary enthalpy_to_state(const String &p_id, double p_h_j_kg, double p_p_pa,
			double p_molality_mol_kg);

	static double boil_c_at(const String &p_id, double p_p_pa);
	static double melt_c_at(const String &p_id, double p_p_pa, double p_molality_mol_kg);
	static double liquidus_c_at(const String &p_id, double p_p_pa, double p_molality_mol_kg);
	static double fusion_pa_per_k(const String &p_id);
	static double saturation_p_at(const String &p_id, double p_t_c);
	static double sublimation_p_at(const String &p_id, double p_t_c);
	static double sublimation_c_at(const String &p_id, double p_p_pa);
	static bool sublimes_at(const String &p_id, double p_p_pa);
	static double latent_vaporisation_at(const String &p_id, double p_t_c);

	static Dictionary element_ionisation_ev();
	static Dictionary element_degen();
	static Dictionary element_entropy_j_molk();
	static double dissociated_fraction(const String &p_id, double p_t_k, double p_p_pa);
	static double ionised_fraction(const String &p_id, double p_t_k, double p_p_pa);
	static double ionisation_j_kg(const String &p_id);
	static double dissociation_j_kg(const String &p_id);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(LASubstances::Phase);

#endif // LOCAL_AGENTS_LA_SUBSTANCES_HPP
