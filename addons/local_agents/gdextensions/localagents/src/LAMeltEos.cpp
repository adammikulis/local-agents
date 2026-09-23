#include "LAMeltEos.hpp"

#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cmath>

using namespace godot;

namespace {

// Oxide partial molar volumes of silicate liquids, cm^3/mol at 1 bar, their dV/dT in cm^3/(mol K), and
// the temperature each volume is given at (Iacovino & Till 2019, Volcanica 2:1, Table 1: SiO2, Al2O3, MgO,
// CaO, Na2O from Lange 1997, CMP 130:1; FeO from Guo, Lange & Ai 2014, EPSL 388:283; dV/dT of SiO2 and
// Al2O3 from Lange & Carmichael 1987, GCA 51:2931).
constexpr double V_SIO2_CM3_MOL = 26.86;
constexpr double V_AL2O3_CM3_MOL = 37.42;
constexpr double V_FEO_CM3_MOL = 12.68;
constexpr double V_MGO_CM3_MOL = 12.02;
constexpr double V_CAO_CM3_MOL = 16.90;
constexpr double V_NA2O_CM3_MOL = 29.65;
constexpr double DVDT_SIO2_CM3_MOLK = 0.0;
constexpr double DVDT_AL2O3_CM3_MOLK = 2.62e-3;
constexpr double DVDT_FEO_CM3_MOLK = 3.69e-3;
constexpr double DVDT_MGO_CM3_MOLK = 3.27e-3;
constexpr double DVDT_CAO_CM3_MOLK = 3.74e-3;
constexpr double DVDT_NA2O_CM3_MOLK = 7.68e-3;
constexpr double OXIDE_V_REF_T_K = 1773.0;
constexpr double FEO_V_REF_T_K = 1723.0;

// Adiabatic bulk modulus and its pressure derivatives of the liquids at 1 bar (Thomas & Asimow 2013, JGR
// 118:5738): Mg2SiO4 third-order fit (Table 3), Fe2SiO4 third-order and MgSiO3 fourth-order (Table 4).
constexpr double FO_LIQUID_BULK_MODULUS_PA = 16.41e9;
constexpr double FO_LIQUID_BULK_MODULUS_DERIV = 7.37;
constexpr double FA_LIQUID_BULK_MODULUS_PA = 21.99e9;
constexpr double FA_LIQUID_BULK_MODULUS_DERIV = 7.28;
constexpr double EN_LIQUID_BULK_MODULUS_PA = 24.66e9;
constexpr double EN_LIQUID_BULK_MODULUS_DERIV = 10.07;
constexpr double EN_LIQUID_BULK_MODULUS_DERIV2_PER_PA = 2.35e-9;

// Molten NaCl at its melting point and the fall of its density with temperature, kg/m^3 and
// kg/(m^3 K) (Janz 1988, J. Phys. Chem. Ref. Data 17 Suppl. 2; CRC 97th ed. 4-128).
constexpr double HALITE_LIQUID_DENSITY_KG_M3 = 1556.0;
constexpr double HALITE_LIQUID_DENSITY_SLOPE_KG_M3K = 0.543;

// cm^3 to m^3, exact.
constexpr double CM3_TO_M3 = 1.0e-6;

double kelvin() {
	return la_physical("KELVIN_OFFSET");
}

struct Oxide {
	double n;
	double v;
	double dvdt;
	double t_ref_k;
};

// Liquid molar volume and its temperature slope at `p_t_k`, m^3 per mole of formula.
void oxide_volume(const Oxide *p_ox, int p_n, double p_t_k, double &r_v, double &r_dvdt) {
	r_v = 0.0;
	r_dvdt = 0.0;
	for (int i = 0; i < p_n; i++) {
		r_v += p_ox[i].n * (p_ox[i].v + p_ox[i].dvdt * (p_t_k - p_ox[i].t_ref_k)) * CM3_TO_M3;
		r_dvdt += p_ox[i].n * p_ox[i].dvdt * CM3_TO_M3;
	}
}

// Orthosilicate liquid volume per formula unit at the model's reference, m^3/mol.
double orthosilicate_v(double p_n_mgo, double p_n_feo) {
	const Oxide ox[] = { { 1.0, V_SIO2_CM3_MOL, DVDT_SIO2_CM3_MOLK, OXIDE_V_REF_T_K },
		{ p_n_mgo, V_MGO_CM3_MOL, DVDT_MGO_CM3_MOLK, OXIDE_V_REF_T_K },
		{ p_n_feo, V_FEO_CM3_MOL, DVDT_FEO_CM3_MOLK, FEO_V_REF_T_K } };
	double v = 0.0;
	double dvdt = 0.0;
	oxide_volume(ox, 3, OXIDE_V_REF_T_K, v, dvdt);
	return v;
}

} // namespace

Dictionary LAMeltEos::oxide_melt(const Dictionary &p_formula) {
	Dictionary out;
	const double n_si = double(p_formula.get("Si", 0.0));
	const double n_al = double(p_formula.get("Al", 0.0));
	const double n_fe = double(p_formula.get("Fe", 0.0));
	const double n_mg = double(p_formula.get("Mg", 0.0));
	const double n_ca = double(p_formula.get("Ca", 0.0));
	const double n_na = double(p_formula.get("Na", 0.0));
	const Array els = p_formula.keys();
	for (int i = 0; i < els.size(); i++) {
		const String el = els[i];
		ERR_FAIL_COND_V_MSG(el != "Si" && el != "Al" && el != "Fe" && el != "Mg" && el != "Ca" && el != "Na"
						&& el != "O",
				out, "LAMeltEos: the oxide model carries no liquid volume for " + el + ".");
	}
	// Iron as FeO: the balance fails on any ferric iron, which the model would need as Fe2O3.
	const double o_oxides = 2.0 * n_si + 1.5 * n_al + n_fe + n_mg + n_ca + 0.5 * n_na;
	ERR_FAIL_COND_V_MSG(std::abs(o_oxides - double(p_formula.get("O", 0.0))) > 1e-9, out,
			"LAMeltEos: the formula's oxygen does not balance its oxides.");
	const Oxide ox[] = { { n_si, V_SIO2_CM3_MOL, DVDT_SIO2_CM3_MOLK, OXIDE_V_REF_T_K },
		{ 0.5 * n_al, V_AL2O3_CM3_MOL, DVDT_AL2O3_CM3_MOLK, OXIDE_V_REF_T_K },
		{ n_fe, V_FEO_CM3_MOL, DVDT_FEO_CM3_MOLK, FEO_V_REF_T_K },
		{ n_mg, V_MGO_CM3_MOL, DVDT_MGO_CM3_MOLK, OXIDE_V_REF_T_K },
		{ n_ca, V_CAO_CM3_MOL, DVDT_CAO_CM3_MOLK, OXIDE_V_REF_T_K },
		{ 0.5 * n_na, V_NA2O_CM3_MOL, DVDT_NA2O_CM3_MOLK, OXIDE_V_REF_T_K } };
	double v = 0.0;
	double dvdt = 0.0;
	oxide_volume(ox, 6, OXIDE_V_REF_T_K, v, dvdt);
	ERR_FAIL_COND_V_MSG(!(v > 0.0), out, "LAMeltEos: the formula gives the liquid no volume.");
	out["density_melt"] = LAElementAbundances::molar_mass(p_formula) / v;
	out["density_melt_ref_t_c"] = OXIDE_V_REF_T_K - kelvin();
	out["expansion_melt_per_k"] = dvdt / v;
	return out;
}

// Ideal volume mixing at one pressure: compressibilities add by volume fraction phi (Reuss), and
// K' = K^2 sum phi (1 + K'_i) / K_i^2 - 1 follows from differentiating that sum.
Dictionary LAMeltEos::olivine_melt_compression(double p_mg) {
	const double v_fo = p_mg * orthosilicate_v(2.0, 0.0);
	const double v_fa = (1.0 - p_mg) * orthosilicate_v(0.0, 2.0);
	const double phi = v_fo / (v_fo + v_fa);
	const double k = 1.0 / (phi / FO_LIQUID_BULK_MODULUS_PA + (1.0 - phi) / FA_LIQUID_BULK_MODULUS_PA);
	const double s = phi * (1.0 + FO_LIQUID_BULK_MODULUS_DERIV) / (FO_LIQUID_BULK_MODULUS_PA * FO_LIQUID_BULK_MODULUS_PA)
			+ (1.0 - phi) * (1.0 + FA_LIQUID_BULK_MODULUS_DERIV) / (FA_LIQUID_BULK_MODULUS_PA * FA_LIQUID_BULK_MODULUS_PA);
	Dictionary out;
	out["bulk_modulus_melt_pa"] = k;
	out["bulk_modulus_melt_deriv"] = k * k * s - 1.0;
	return out;
}

Dictionary LAMeltEos::enstatite_melt_compression() {
	Dictionary out;
	out["bulk_modulus_melt_pa"] = EN_LIQUID_BULK_MODULUS_PA;
	out["bulk_modulus_melt_deriv"] = EN_LIQUID_BULK_MODULUS_DERIV;
	out["bulk_modulus_melt_deriv2"] = EN_LIQUID_BULK_MODULUS_DERIV2_PER_PA;
	return out;
}

Dictionary LAMeltEos::halite_melt(double p_melt_c) {
	Dictionary out;
	out["density_melt"] = HALITE_LIQUID_DENSITY_KG_M3;
	out["density_melt_ref_t_c"] = p_melt_c;
	out["expansion_melt_per_k"] = HALITE_LIQUID_DENSITY_SLOPE_KG_M3K / HALITE_LIQUID_DENSITY_KG_M3;
	return out;
}
