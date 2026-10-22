#ifndef LOCAL_AGENTS_LA_SUBSTANCE_ROW_HPP
#define LOCAL_AGENTS_LA_SUBSTANCE_ROW_HPP

#include "LAPhaseEos.hpp"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <vector>

namespace godot {

// A measured scalar of a substance row: the value, and whether the table names it. `or_` is what
// Dictionary::get answered with its default.
struct LAOpt {
	double v = 0.0;
	bool has = false;
	double or_(double p_default) const { return has ? v : p_default; }
};

// ONE SUBSTANCE OF LASubstances::table() AS NUMBERS, built once for every row the table names. Everything
// a per-cell walk reads about a substance is here, so no walk looks a name up in a Dictionary.
struct LASubstanceRow {
	String id;
	bool iapws = false;
	LAOpt molar_mass, specific_heat, specific_heat_solid, specific_heat_gas;
	LAOpt melt_c, triple_t_c, triple_p_pa, boil_c, boil_ref_p_pa, critical_t_c, critical_p_pa;
	LAOpt latent_fusion_j_kg, latent_vaporisation_j_kg, latent_vaporisation_ref_t_c;
	LAOpt atomisation_j_mol, entropy_gas_j_molk;

	// What the formula and the element tables make of the row; constants of the row, so computed once.
	double clapeyron_b = 0.0;
	double r_specific = 0.0;
	double monatomic_c_j_kgk = 0.0;
	double ionisation_j_kg = 0.0;
	double dissociation_j_kg = 0.0;
	// Free-atom count and entropy sum, valid only where every element has a measured free-atom entropy.
	bool dissociates = false;
	double nu = 0.0;
	double s_atoms = 0.0;
	// Saha: one entry per element the table measures an ionisation energy and degeneracy for.
	struct Ion {
		double n;
		double chi_j;
		double ratio;
	};
	std::vector<Ion> ions;
	double atoms = 0.0;
	bool formula_empty = true;

	// The phase rules this row stands on, resolved on first use.
	mutable std::atomic<const LACondensedEos *> condensed_rule{ nullptr };
	mutable std::atomic<const LAFluidEos *> fluid_rule{ nullptr };
	mutable std::atomic<const LAAnchor *> anchor_rule{ nullptr };

	const LACondensedEos &condensed() const;
	const LAFluidEos &fluid() const;
	const LAAnchor &anchor() const;
};

// THE ROW LADDER, TYPED. LASubstances' String entry points read the same rows through these.
namespace la_substance {

// The row the table names, or an empty one with only its id where it names none.
const LASubstanceRow &row(const String &p_id);

double latent_vaporisation_at(const LASubstanceRow &p_r, double p_t_c);
double latent_sublimation_j_kg(const LASubstanceRow &p_r);
double boil_c_at(const LASubstanceRow &p_r, double p_p_pa);
double melt_c_at(const LASubstanceRow &p_r, double p_p_pa, double p_molality_mol_kg);
double liquidus_c_at(const LASubstanceRow &p_r, double p_p_pa, double p_molality_mol_kg);
double saturation_p_at(const LASubstanceRow &p_r, double p_t_c);
double sublimation_p_at(const LASubstanceRow &p_r, double p_t_c);
double sublimation_c_at(const LASubstanceRow &p_r, double p_p_pa);
bool sublimes_at(const LASubstanceRow &p_r, double p_p_pa);
double dissociated_fraction(const LASubstanceRow &p_r, double p_t_k, double p_p_pa);
double ionised_fraction(const LASubstanceRow &p_r, double p_t_k, double p_p_pa);
double enthalpy_at(const LASubstanceRow &p_r, double p_t_c, double p_p_pa, double p_molality_mol_kg);
Dictionary enthalpy_to_state(const LASubstanceRow &p_r, double p_h_j_kg, double p_p_pa, double p_molality_mol_kg);

} // namespace la_substance

} // namespace godot

#endif // LOCAL_AGENTS_LA_SUBSTANCE_ROW_HPP
