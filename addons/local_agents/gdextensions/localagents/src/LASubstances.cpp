#include "LASubstances.hpp"

#include "LAMeltEos.hpp"
#include "LAPhaseEos.hpp"
#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"
#include "LASubstanceOptics.hpp"
#include "LAWaterCurves.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
constexpr double kPi = 3.14159265358979323846;

double pc(const char *p_name) {
	return la_physical(p_name);
}

// K_T from an adiabatic K_S measured at `p_t_c`: K_S = K_T (1 + alpha gamma T), gamma = alpha K_S / (rho c_p).
double isothermal_modulus(double p_ks, double p_alpha, double p_rho, double p_cp, double p_t_c) {
	return p_ks / (1.0 + p_alpha * p_alpha * p_ks * (p_t_c + pc("KELVIN_OFFSET")) / (p_rho * p_cp));
}

// --- The differentiated planet's mineral data ------------------------------------------------------------
// Liquid iron at its melting point 1811 K (Assael et al. 2006, J. Phys. Chem. Ref. Data 35:285).
constexpr double IRON_LIQUID_DENSITY_KG_M3 = 7030.0;
constexpr double IRON_LIQUID_EXPANSION_PER_K = 1.22e-4;
// delta-Fe at the melting point (Abdullaev et al. 2020, JPCS 1675:012087).
constexpr double IRON_SOLID_DENSITY_AT_MELT_KG_M3 = 7265.0;
constexpr double IRON_MELT_C = 1538.0;
constexpr double IRON_SOLID_EXPANSION_PER_K = 3.54e-5;    // alpha-Fe at 25 C, CRC 97th ed., linear x3
constexpr double IRON_SOLID_BULK_MODULUS_S_PA = 1.662e11; // adiabatic, 25 C, Guinan & Beshers 1968, JPCS 29:541
constexpr double IRON_SOLID_DENSITY_25C_KG_M3 = 7874.0;   // alpha-Fe, CRC 97th ed.
constexpr double IRON_SOLID_BULK_MODULUS_DERIV = 5.16;    // bcc Fe, Holland & Powell 2011, JMG 29:333 (ds62 iron)
constexpr double IRON_LIQUID_BULK_MODULUS_S_PA = 1.097e11; // adiabatic, liquid Fe at 1 bar, Anderson & Ahrens 1994, JGR 99:4273
constexpr double IRON_LIQUID_BULK_MODULUS_DERIV = 4.66;   // K'_S0, Anderson & Ahrens 1994, JGR 99:4273
constexpr double IRON_LIQUID_SPECIFIC_HEAT_J_KGK = 824.0; // Desai 1986, J. Phys. Chem. Ref. Data 15:967
constexpr double IRON_SOLID_SPECIFIC_HEAT_J_KGK = 449.0;  // alpha-Fe at 25 C, CRC 97th ed.
constexpr double IRON_VAPOUR_CP_J_MOLK = 25.7;             // Fe(g) at 298.15 K, CRC 97th ed. 5-4
constexpr double IRON_LATENT_FUSION_J_KG = 2.473e5;       // Desai 1986, dHfus 13.81 kJ/mol
constexpr double IRON_BOIL_C = 2861.0;                    // CRC 97th ed.
constexpr double IRON_LATENT_VAPORISATION_J_KG = 6.09e6;  // CRC, dHvap 340 kJ/mol
constexpr double IRON_CRITICAL_T_C = 8977.0;               // 9250 K, Beutl, Pottlacher & Jager 1994, Int. J. Thermophys. 15:1323
constexpr double IRON_CRITICAL_P_PA = 8.75e8;             // 8750 bar, Beutl, Pottlacher & Jager 1994, Int. J. Thermophys. 15:1323
constexpr double IRON_CONDUCTIVITY_W_MK = 80.4;           // Fe at 300 K, CRC 97th ed.

constexpr double OLIVINE_DENSITY_KG_M3 = 3355.0;   // San Carlos Fo90, Abramson et al. 1997, JGR 102:12253
constexpr double FORSTERITE_CP_J_MOLK = 117.9;       // Robie & Hemingway 1995
constexpr double FAYALITE_CP_J_MOLK = 132.9;         // Robie & Hemingway 1995
constexpr double FORSTERITE_MELT_C = 1890.0;         // 2163 K, Bowen & Andersen 1914; Richet et al. 1993
constexpr double FORSTERITE_FUSION_J_MOL = 1.42e5;   // Richet et al. 1993, GRL 20:1675
constexpr double OLIVINE_CONDUCTIVITY_W_MK = 4.7;    // Fo90, Horai 1971, JGR 76:1278

constexpr double ENSTATITE_DENSITY_KG_M3 = 3204.0;   // Smyth & McCormick 1995, AGU Handbook
constexpr double ENSTATITE_CP_J_MOLK = 82.1;         // Krupka et al. 1985, Am. Min. 70:249
constexpr double ENSTATITE_MOLAR_MASS_KG_MOL = 0.1003875; // MgSiO3 endmember
constexpr double ENSTATITE_MELT_C = 1557.0;          // incongruent point, Bowen & Andersen 1914
// Richet & Bottinga 1986, at protoenstatite's congruent point (Thieblot et al. 1999, Am Min 84:848).
constexpr double ENSTATITE_FUSION_J_MOL = 7.30e4;
constexpr double ENSTATITE_CONDUCTIVITY_W_MK = 4.5;  // Horai 1971

constexpr double ANORTHITE_DENSITY_KG_M3 = 2760.0;   // Smyth & McCormick 1995
constexpr double ALBITE_DENSITY_KG_M3 = 2620.0;
constexpr double ANORTHITE_CP_J_MOLK = 211.4;        // Robie & Hemingway 1995
constexpr double ALBITE_CP_J_MOLK = 205.1;
constexpr double ANORTHITE_MELT_C = 1553.0;          // Bowen 1913 plagioclase loop endmembers
constexpr double ALBITE_MELT_C = 1118.0;
constexpr double ANORTHITE_FUSION_J_MOL = 1.33e5;    // Richet & Bottinga 1984
constexpr double ALBITE_FUSION_J_MOL = 6.45e4;
constexpr double ANORTHITE_CONDUCTIVITY_W_MK = 1.88; // Horai 1971
constexpr double ALBITE_CONDUCTIVITY_W_MK = 2.08;

constexpr double HALITE_DENSITY_KG_M3 = 2163.0;      // CRC 97th ed.
constexpr double HALITE_MELT_C = 800.7;              // CRC 97th ed.
constexpr double HALITE_FUSION_J_MOL = 2.816e4;      // CRC 97th ed.
constexpr double HALITE_CP_J_MOLK = 50.5;            // CRC 97th ed., 298 K
constexpr double CALCITE_BULK_MODULUS_PA = 7.33e10;  // Redfern & Angel 1999, Contrib Mineral Petrol 134:102
constexpr double CALCITE_BULK_MODULUS_DERIV = 4.06;  // Holland & Powell 2011, JMG 29:333 (ds62 cc)
// Fluorapatite to 61 GPa, V0 fixed: Rucks et al. 2023, Am Min 108:1683.
constexpr double APATITE_BULK_MODULUS_PA = 9.70e10;
constexpr double APATITE_BULK_MODULUS_DERIV = 3.3;
// Mean volume expansivity of F-OH apatites, 22-928 C (Hovis et al. 2014, Am. Mineral. 99:2171).
constexpr double APATITE_EXPANSION_PER_K = 4.10e-5;
constexpr double ORGANIC_BULK_MODULUS_PA = 5.0e9;    // kerogen, Yu et al. 2018, Fuel 224:412
// A polymeric solid: the Tait form V = V0[1 - C ln(1 + p/B)] with the universal C = 0.0894 for
// polymer PVT (Zoller & Walsh 1995) gives dK/dp = 1/C - 1.
constexpr double ORGANIC_BULK_MODULUS_DERIV = 10.19;
constexpr double HALITE_CONDUCTIVITY_W_MK = 6.5;     // single crystal, Urquhart & Bauer 2015

// Isothermal K0, K0' and alpha0 at 298 K, Holland & Powell 2011, JMG 29:333 (ds62 fo, fa, en, an, ab, hlt).
constexpr double FORSTERITE_BULK_MODULUS_PA = 1.285e11;
constexpr double FORSTERITE_BULK_MODULUS_DERIV = 3.84;
constexpr double FORSTERITE_EXPANSION_PER_K = 2.85e-5;
constexpr double FAYALITE_BULK_MODULUS_PA = 1.256e11;
constexpr double FAYALITE_BULK_MODULUS_DERIV = 4.68;
constexpr double FAYALITE_EXPANSION_PER_K = 2.82e-5;
constexpr double ENSTATITE_BULK_MODULUS_PA = 1.059e11;
constexpr double ENSTATITE_BULK_MODULUS_DERIV = 8.65;
constexpr double ENSTATITE_EXPANSION_PER_K = 2.27e-5;
constexpr double ANORTHITE_BULK_MODULUS_PA = 8.60e10;
constexpr double ANORTHITE_BULK_MODULUS_DERIV = 4.09;
constexpr double ANORTHITE_EXPANSION_PER_K = 1.41e-5;
constexpr double ALBITE_BULK_MODULUS_PA = 5.41e10;
constexpr double ALBITE_BULK_MODULUS_DERIV = 5.91;
constexpr double ALBITE_EXPANSION_PER_K = 2.36e-5;
constexpr double HALITE_BULK_MODULUS_PA = 2.38e10;
constexpr double HALITE_BULK_MODULUS_DERIV = 5.0;
constexpr double HALITE_EXPANSION_PER_K = 1.147e-4;

constexpr double APATITE_DENSITY_KG_M3 = 3190.0;     // fluorapatite, Handbook of Mineralogy
constexpr double APATITE_CP_J_MOLK = 370.0;          // 298 K, Dachs, Harlov & Benisek 2010
constexpr double APATITE_CONDUCTIVITY_W_MK = 1.38;   // Horai 1971

// Pressure derivative of the bulk modulus for the phases whose K0 lives in LAPhysical.
// Water: the modified-Tait exponent n = dK/dp (Cole 1948, Underwater Explosions, Princeton).
// Ice Ih: dK_T/dp over 0-100 MPa at 260 K from IAPWS-06 kappa_T (Feistel & Wagner 2006, JPCRD 35:1021).
constexpr double WATER_BULK_MODULUS_DERIV = 7.15;
constexpr double ICE_BULK_MODULUS_DERIV = 5.2;
constexpr double QUARTZ_BULK_MODULUS_DERIV = 5.99;   // alpha-quartz, Angel et al. 1997, J Appl Cryst 30:461
constexpr double ROCK_BULK_MODULUS_DERIV = 4.1;      // wollastonite, Holland & Powell 2011, JMG 29:333 (ds62 wo)

// HIGHER heating value per kg of each element in a solid fuel -- Channiwala & Parikh 2002, Fuel
// 81:1051-1063, "A unified correlation for estimating HHV of solid, liquid and gaseous fuels", eq. 1.
constexpr double HHV_PER_KG_C_J = 0.3491e8;
constexpr double HHV_PER_KG_H_J = 1.1783e8;
constexpr double HHV_PER_KG_O_J = -0.1034e8;
constexpr double HHV_PER_KG_N_J = -0.0151e8;

// Standard molar entropy of the GAS, J/mol/K (CODATA / NIST-JANAF, 298.15 K, 1 bar). A property of the
// substance, so it lives here rather than in LAPhysical.
constexpr double ENTROPY_H2O_GAS_J_MOLK = 188.835;
constexpr double ENTROPY_O2_GAS_J_MOLK = 205.152;
constexpr double ENTROPY_CO2_GAS_J_MOLK = 213.785;

// Standard formation enthalpy of water VAPOUR, J/mol (CODATA Key Values, 298.15 K).
constexpr double FORMATION_ENTHALPY_H2O_GAS_J_MOL = -241826.0;

// Nitric oxide, the form a discharge and a flame leave nitrogen in: standard formation enthalpy J/mol and
// standard molar entropy of the GAS J/(mol K) (NIST-JANAF 4th ed., Chase 1998; CRC 97th ed., 298.15 K).
constexpr double FORMATION_ENTHALPY_NO_J_MOL = 91290.0;
constexpr double ENTROPY_NO_GAS_J_MOLK = 210.76;

// Standard entropy of solid wood/paper organics per element MASS FRACTION, J/(kg K) (Eboh, Ahlstrom &
// Richards 2016, Energy Sci. Eng. 4(3):217-231, eq. 26, converted from kJ/(K kg) per wt%).
constexpr double WOOD_ENTROPY_C_J_KGK = 1620.0;
constexpr double WOOD_ENTROPY_H_J_KGK = 1160.0;
constexpr double WOOD_ENTROPY_O_J_KGK = 810.0;

// Moles of CH2O units in a cubic metre of dry wood -- the volume one mole of any organic element occupies
// comes from this packing, so the three organic density rows below derive from it.
double organic_mol_per_m3() {
	return pc("DRY_WOOD_DENSITY_KG_M3") / pc("MOLAR_MASS_CH2O_UNIT_KG_MOL");
}

struct ElementCount {
	const char *el;
	double n;
};

Dictionary formula_of(const ElementCount *p_rows, int p_n) {
	Dictionary f;
	for (int i = 0; i < p_n; i++) {
		f[String(p_rows[i].el)] = p_rows[i].n;
	}
	return f;
}

// One entry: the fields every phase carries, plus what this one measures beyond them.
Dictionary entry(const Dictionary &p_formula, double p_density, double p_cp_j_kgk, double p_lambda_w_mk,
		const Dictionary &p_extra) {
	Dictionary d;
	d["formula"] = p_formula;
	d["molar_mass"] = LAElementAbundances::molar_mass(p_formula);
	d["density"] = p_density;
	d["specific_heat_solid"] = p_cp_j_kgk;
	d["conductivity"] = p_lambda_w_mk;
	return d.merged(p_extra, true);
}

// The eight atmospheric gases carry one property set; only the constants they name differ. A nullptr
// leaves the property off the row, and `element_reference` books a formation enthalpy of zero by
// definition of the element's standard state.
struct GasRow {
	const char *id;
	const ElementCount *formula;
	int formula_n;
	const char *molar_mass;
	const char *atomisation;
	const char *entropy_gas;
	double entropy_gas_local;
	const char *formation_enthalpy;
	bool element_reference;
	const char *specific_heat;
	const char *specific_heat_gas;
	const char *melt_c;
	const char *boil_c;
	const char *boil_ref_p_pa;
	const char *triple_t_c;
	const char *triple_p_pa;
	const char *critical_t_c;
	const char *critical_p_pa;
	const char *acentric;
	const char *latent_fusion;
	const char *latent_vaporisation;
	const char *latent_vaporisation_ref_t_c;
	const char *conductivity;
	const char *density_solid;
	const char *density_solid_ref_t_c;
	const char *density_melt;
	const char *density_melt_ref_t_c;
	const char *expansion_melt;
	const char *bulk_modulus_melt;
	const char *bulk_modulus_melt_deriv;
	const char *melt_form;
	const char *melt_prefix;
};

const ElementCount F_N2[] = { { "N", 2.0 } };
const ElementCount F_O2[] = { { "O", 2.0 } };
const ElementCount F_CO2[] = { { "C", 1.0 }, { "O", 2.0 } };
const ElementCount F_H2[] = { { "H", 2.0 } };
const ElementCount F_CO[] = { { "C", 1.0 }, { "O", 1.0 } };
const ElementCount F_SO2[] = { { "S", 1.0 }, { "O", 2.0 } };
const ElementCount F_H2S[] = { { "H", 2.0 }, { "S", 1.0 } };
const ElementCount F_CH4[] = { { "C", 1.0 }, { "H", 4.0 } };

const GasRow GASES[] = {
	{ "n2", F_N2, 1, "MOLAR_MASS_N2_KG_MOL", "ATOMISATION_N2_J_MOL", "ENTROPY_N2_GAS_J_MOLK", 0.0,
		nullptr, true, "N2_LIQUID_SPECIFIC_HEAT_J_KGK", "N2_GAS_SPECIFIC_HEAT_J_KGK",
		"N2_TRIPLE_T_C", "N2_BOIL_C", "STANDARD_PRESSURE_PA", "N2_TRIPLE_T_C", "N2_TRIPLE_P_PA",
		"N2_CRITICAL_T_C", "N2_CRITICAL_P_PA", "N2_ACENTRIC_FACTOR", "LATENT_HEAT_FUSION_N2_J_KG",
		"LATENT_HEAT_VAPORISATION_N2_J_KG", "N2_BOIL_C", "THERMAL_CONDUCT_N2_GAS_W_MK",
		nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, "reduced_simon", "N2" },
	{ "o2", F_O2, 1, "MOLAR_MASS_O2_KG_MOL", "ATOMISATION_O2_J_MOL", nullptr, ENTROPY_O2_GAS_J_MOLK,
		nullptr, true, "O2_LIQUID_SPECIFIC_HEAT_J_KGK", "O2_GAS_SPECIFIC_HEAT_J_KGK",
		"O2_TRIPLE_T_C", "O2_BOIL_C", "STANDARD_PRESSURE_PA", "O2_TRIPLE_T_C", "O2_TRIPLE_P_PA",
		"O2_CRITICAL_T_C", "O2_CRITICAL_P_PA", "O2_ACENTRIC_FACTOR", "LATENT_HEAT_FUSION_O2_J_KG",
		"LATENT_HEAT_VAPORISATION_O2_J_KG", "O2_BOIL_C", "THERMAL_CONDUCT_O2_GAS_W_MK",
		nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, "simon", "O2" },
	// No 1-atm boiling point (triple P > 1 atm): the vapour curve's second anchor is 0 C saturation.
	{ "co2", F_CO2, 2, "MOLAR_MASS_CO2_KG_MOL", "ATOMISATION_CO2_J_MOL", nullptr, ENTROPY_CO2_GAS_J_MOLK,
		"FORMATION_ENTHALPY_CO2_J_MOL", false, "CO2_LIQUID_SPECIFIC_HEAT_J_KGK",
		"CO2_GAS_SPECIFIC_HEAT_J_KGK", "CO2_TRIPLE_T_C", "CO2_SAT_REF_T_C", "CO2_SAT_REF_P_PA",
		"CO2_TRIPLE_T_C", "CO2_TRIPLE_P_PA", "CO2_CRITICAL_T_C", "CO2_CRITICAL_P_PA", "CO2_ACENTRIC_FACTOR",
		"LATENT_HEAT_FUSION_CO2_J_KG", "CO2_LATENT_VAPORISATION_J_KG", "CO2_TRIPLE_T_C",
		"THERMAL_CONDUCT_CO2_GAS_W_MK", "DRY_ICE_DENSITY_KG_M3", "CO2_TRIPLE_T_C", "CO2_LIQUID_DENSITY_KG_M3",
		"CO2_TRIPLE_T_C", "CO2_LIQUID_EXPANSION_PER_K", "CO2_LIQUID_BULK_MODULUS_PA", "CO2_LIQUID_BULK_MODULUS_DERIV",
		"reduced_poly", "CO2" },
	{ "h2", F_H2, 1, "MOLAR_MASS_H2_KG_MOL", "ATOMISATION_H2_J_MOL", "ENTROPY_H2_GAS_J_MOLK", 0.0,
		nullptr, true, "H2_LIQUID_SPECIFIC_HEAT_J_KGK", "H2_GAS_SPECIFIC_HEAT_J_KGK",
		nullptr, "H2_BOIL_C", "STANDARD_PRESSURE_PA", nullptr, nullptr,
		"H2_CRITICAL_T_C", "H2_CRITICAL_P_PA", "H2_ACENTRIC_FACTOR", nullptr,
		"LATENT_HEAT_VAPORISATION_H2_J_KG", "H2_BOIL_C", "THERMAL_CONDUCT_H2_GAS_W_MK",
		nullptr, nullptr },
	{ "co", F_CO, 2, "MOLAR_MASS_CO_KG_MOL", "ATOMISATION_CO_J_MOL", "ENTROPY_CO_GAS_J_MOLK", 0.0,
		"FORMATION_ENTHALPY_CO_J_MOL", false, "CO_LIQUID_SPECIFIC_HEAT_J_KGK",
		"CO_GAS_SPECIFIC_HEAT_J_KGK", "CO_TRIPLE_T_C", "CO_BOIL_C", "STANDARD_PRESSURE_PA",
		"CO_TRIPLE_T_C", "CO_TRIPLE_P_PA", "CO_CRITICAL_T_C", "CO_CRITICAL_P_PA", "CO_ACENTRIC_FACTOR",
		"LATENT_HEAT_FUSION_CO_J_KG", "LATENT_HEAT_VAPORISATION_CO_J_KG", "CO_BOIL_C",
		"THERMAL_CONDUCT_CO_GAS_W_MK",
		nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, "simon", "CO" },
	{ "so2", F_SO2, 2, "MOLAR_MASS_SO2_KG_MOL", "ATOMISATION_SO2_J_MOL", "ENTROPY_SO2_GAS_J_MOLK", 0.0,
		"FORMATION_ENTHALPY_SO2_J_MOL", false, "SO2_LIQUID_SPECIFIC_HEAT_J_KGK",
		"SO2_GAS_SPECIFIC_HEAT_J_KGK", nullptr, "SO2_BOIL_C", "STANDARD_PRESSURE_PA",
		nullptr, nullptr, "SO2_CRITICAL_T_C", "SO2_CRITICAL_P_PA", "SO2_ACENTRIC_FACTOR",
		nullptr, "LATENT_HEAT_VAPORISATION_SO2_J_KG", "SO2_BOIL_C",
		"THERMAL_CONDUCT_SO2_GAS_W_MK", nullptr, nullptr },
	{ "h2s", F_H2S, 2, "MOLAR_MASS_H2S_KG_MOL", "ATOMISATION_H2S_J_MOL", "ENTROPY_H2S_GAS_J_MOLK", 0.0,
		"FORMATION_ENTHALPY_H2S_J_MOL", false, "H2S_LIQUID_SPECIFIC_HEAT_J_KGK",
		"H2S_GAS_SPECIFIC_HEAT_J_KGK", nullptr, "H2S_BOIL_C", "STANDARD_PRESSURE_PA",
		nullptr, nullptr, "H2S_CRITICAL_T_C", "H2S_CRITICAL_P_PA", "H2S_ACENTRIC_FACTOR",
		nullptr, "LATENT_HEAT_VAPORISATION_H2S_J_KG", "H2S_BOIL_C",
		"THERMAL_CONDUCT_H2S_GAS_W_MK", nullptr, nullptr },
	{ "ch4", F_CH4, 2, "MOLAR_MASS_CH4_KG_MOL", "ATOMISATION_CH4_J_MOL", "ENTROPY_CH4_GAS_J_MOLK", 0.0,
		"FORMATION_ENTHALPY_CH4_J_MOL", false, "CH4_LIQUID_SPECIFIC_HEAT_J_KGK",
		"CH4_GAS_SPECIFIC_HEAT_J_KGK", "CH4_TRIPLE_T_C", "CH4_BOIL_C", "STANDARD_PRESSURE_PA",
		"CH4_TRIPLE_T_C", "CH4_TRIPLE_P_PA", "CH4_CRITICAL_T_C", "CH4_CRITICAL_P_PA", "CH4_ACENTRIC_FACTOR",
		"LATENT_HEAT_FUSION_CH4_J_KG", "LATENT_HEAT_VAPORISATION_CH4_J_KG", "CH4_BOIL_C",
		"THERMAL_CONDUCT_CH4_GAS_W_MK",
		nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, "simon", "CH4" },
};

// Viscosity against temperature. Water: the Vogel form on the measured reference, mu = mu_ref
// 10^(B/(T-C) - B/(T_ref-C)), fitted 0-370 C (Seeton 2006, Tribol. Lett. 22:67). Nitrogen, and so the
// air it dominates: Sutherland's law, mu = mu_ref (T_ref+S)/(T+S) (T/T_ref)^1.5 (Sutherland 1893,
// Phil. Mag. 36:507). Each reference is the temperature LAPhysical measures that viscosity at.
const double WATER_VISCOSITY_REF_T_C = 20.0;
const double WATER_VISCOSITY_VOGEL_B_K = 247.8;
const double WATER_VISCOSITY_VOGEL_C_K = 140.0;
const double N2_VISCOSITY_REF_T_C = 15.0;
const double N2_VISCOSITY_SUTHERLAND_K = 110.4;

Dictionary gas_entry(const GasRow &p_g) {
	Dictionary d;
	d["formula"] = formula_of(p_g.formula, p_g.formula_n);
	d["molar_mass"] = pc(p_g.molar_mass);
	d["atomisation_j_mol"] = pc(p_g.atomisation);
	d["entropy_gas_j_molk"] = p_g.entropy_gas ? pc(p_g.entropy_gas) : p_g.entropy_gas_local;
	if (p_g.element_reference) {
		d["formation_enthalpy_j_mol"] = 0.0;   // reference state of the element, by definition
	} else if (p_g.formation_enthalpy) {
		d["formation_enthalpy_j_mol"] = pc(p_g.formation_enthalpy);
	}
	d["density"] = pc(p_g.molar_mass) * pc("STP_MOLAR_DENSITY_MOL_M3");
	d["density_ref_t_c"] = 0.0;   // STP_MOLAR_DENSITY_MOL_M3 is taken at KELVIN_OFFSET, 0 C
	if (p_g.density_solid) {
		d["density_solid"] = pc(p_g.density_solid);
		d["density_solid_ref_t_c"] = pc(p_g.density_solid_ref_t_c);
	}
	if (p_g.density_melt) {
		d["density_melt"] = pc(p_g.density_melt);
		d["density_melt_ref_t_c"] = pc(p_g.density_melt_ref_t_c);
		d["expansion_melt_per_k"] = pc(p_g.expansion_melt);
		d["bulk_modulus_melt_pa"] = pc(p_g.bulk_modulus_melt);
		d["bulk_modulus_melt_deriv"] = pc(p_g.bulk_modulus_melt_deriv);
	}
	d["specific_heat"] = pc(p_g.specific_heat);
	d["specific_heat_gas"] = pc(p_g.specific_heat_gas);
	d["boil_c"] = pc(p_g.boil_c);
	d["boil_ref_p_pa"] = pc(p_g.boil_ref_p_pa);
	d["critical_t_c"] = pc(p_g.critical_t_c);
	d["critical_p_pa"] = pc(p_g.critical_p_pa);
	d["acentric_factor"] = pc(p_g.acentric);
	// LA_APPROX: no_solid_without_melting_line
	if (p_g.melt_c) {
		d["melt_c"] = pc(p_g.melt_c);
		d["triple_t_c"] = pc(p_g.triple_t_c);
		d["triple_p_pa"] = pc(p_g.triple_p_pa);
		d["melt_p_pa"] = pc(p_g.triple_p_pa);
		d["liquidus_c"] = pc(p_g.melt_c);
		d["latent_fusion_j_kg"] = pc(p_g.latent_fusion);
	}
	// LA_APPROX: melting_line_extrapolation
	if (p_g.melt_form) {
		const String pre = String(p_g.melt_prefix) + String("_MELT_");
		auto k = [&](const char *p_s) { return la_physical((pre + String(p_s)).utf8().get_data()); };
		const bool two = la_physical_map().has(pre + String("A2"));
		Array a;
		Array c;
		a.push_back(k("A1"));
		c.push_back(k("C1"));
		if (two) {
			a.push_back(k("A2"));
			c.push_back(k("C2"));
		}
		d["melt_line_form"] = String(p_g.melt_form);
		d["melt_line_t0_k"] = k("T0_K");
		d["melt_line_p0_pa"] = k("P0_PA");
		d["melt_line_a"] = a;
		d["melt_line_c"] = c;
	}
	d["latent_vaporisation_j_kg"] = pc(p_g.latent_vaporisation);
	d["latent_vaporisation_ref_t_c"] = pc(p_g.latent_vaporisation_ref_t_c);
	d["conductivity"] = pc(p_g.conductivity);
	// The gas mixture's viscosity is read at the law of the gas that dominates it.
	if (String(p_g.id) == "n2") {
		d["viscosity_pa_s"] = pc("AIR_DYNAMIC_VISCOSITY_PA_S");
		d["viscosity_ref_t_c"] = N2_VISCOSITY_REF_T_C;
		d["viscosity_sutherland_k"] = N2_VISCOSITY_SUTHERLAND_K;
	}
	return d;
}

Dictionary water_entry() {
	const ElementCount f[] = { { "H", 2.0 }, { "O", 1.0 } };
	Dictionary d;
	d["formula"] = formula_of(f, 2);
	d["molar_mass"] = pc("MOLAR_MASS_WATER_KG_MOL");
	d["atomisation_j_mol"] = pc("ATOMISATION_H2O_J_MOL");
	d["entropy_gas_j_molk"] = ENTROPY_H2O_GAS_J_MOLK;
	d["formation_enthalpy_j_mol"] = FORMATION_ENTHALPY_H2O_GAS_J_MOL;
	d["density"] = pc("WATER_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["expansion_per_k"] = pc("WATER_VOLUME_EXPANSION_PER_K");
	d["bulk_modulus_pa"] = pc("WATER_BULK_MODULUS_PA");
	d["bulk_modulus_deriv"] = WATER_BULK_MODULUS_DERIV;
	d["viscosity_pa_s"] = pc("WATER_DYNAMIC_VISCOSITY_PA_S");
	d["viscosity_ref_t_c"] = WATER_VISCOSITY_REF_T_C;
	d["viscosity_vogel_b_k"] = WATER_VISCOSITY_VOGEL_B_K;
	d["viscosity_vogel_c_k"] = WATER_VISCOSITY_VOGEL_C_K;
	d["density_solid"] = pc("ICE_DENSITY_KG_M3");
	d["density_solid_ref_t_c"] = pc("WATER_FREEZE_C");
	d["expansion_solid_per_k"] = pc("ICE_VOLUME_EXPANSION_PER_K");
	d["bulk_modulus_solid_pa"] = pc("ICE_BULK_MODULUS_PA");
	d["bulk_modulus_solid_deriv"] = ICE_BULK_MODULUS_DERIV;
	d["specific_heat"] = pc("WATER_SPECIFIC_HEAT_J_KGK");
	d["specific_heat_solid"] = pc("ICE_SPECIFIC_HEAT_J_KGK");
	d["specific_heat_gas"] = pc("VAPOUR_SPECIFIC_HEAT_J_KGK");
	// Water's three phase boundaries are the IAPWS equations, not a two-anchor law: no reference
	// boiling point and no second pressure anchor, and the melting curve's own anchor is the triple point.
	d["melt_c"] = pc("WATER_TRIPLE_T_C");
	la_water::declare_iapws(d);
	d["triple_t_c"] = pc("WATER_TRIPLE_T_C");
	d["triple_p_pa"] = pc("WATER_TRIPLE_P_PA");
	d["critical_t_c"] = pc("WATER_CRITICAL_T_C");
	d["critical_p_pa"] = pc("WATER_CRITICAL_P_PA");
	d["acentric_factor"] = pc("WATER_ACENTRIC_FACTOR");
	d["melt_p_pa"] = pc("WATER_TRIPLE_P_PA");
	d["liquidus_c"] = pc("WATER_TRIPLE_T_C");
	d["latent_fusion_j_kg"] = pc("LATENT_HEAT_FUSION_J_KG");
	d["latent_vaporisation_j_kg"] = pc("LATENT_HEAT_VAPORISATION_0C_J_KG");
	d["latent_vaporisation_ref_t_c"] = pc("WATER_FREEZE_C");
	d["conductivity"] = pc("THERMAL_CONDUCT_WATER_W_MK");
	d["emissivity"] = pc("EMISSIVITY_WATER");
	d["albedo"] = pc("ALBEDO_OCEAN");
	d["albedo_solid"] = pc("ALBEDO_SNOW_ICE");
	return d;
}

// Nitrogen the dead pool carries per carbon, mol/mol, from the litter C:N ratio.
double litter_n_per_c() {
	return (pc("MOLAR_MASS_CARBON_KG_MOL") / pc("LITTER_C_TO_N")) / pc("MOLAR_MASS_NITROGEN_KG_MOL");
}

// Oven-dry wood's volumetric expansivity, 1/K: parallel-to-grain plus radial (eq. 4-19a) and tangential
// (eq. 4-20a) linear coefficients at the oven-dry specific gravity G0 = rho / rho_water (Glass & Zelinka
// 2010, Wood Handbook, FPL-GTR-190, ch. 4, p. 4-14).
constexpr double WOOD_PARALLEL_EXPANSION_PER_K = 3.8e-6;   // midpoint of the source's 3.1 to 4.5e-6
constexpr double WOOD_RADIAL_PER_G0 = 32.4e-6;
constexpr double WOOD_RADIAL_AT_ZERO = 9.9e-6;
constexpr double WOOD_TANGENTIAL_PER_G0 = 32.4e-6;
constexpr double WOOD_TANGENTIAL_AT_ZERO = 18.4e-6;
constexpr double WOOD_HANDBOOK_WATER_DENSITY_KG_M3 = 1000.0;

double wood_expansion_per_k() {
	const double g0 = pc("DRY_WOOD_DENSITY_KG_M3") / WOOD_HANDBOOK_WATER_DENSITY_KG_M3;
	// LA_APPROX: wood_parallel_grain_midpoint
	return WOOD_PARALLEL_EXPANSION_PER_K + (WOOD_RADIAL_PER_G0 * g0 + WOOD_RADIAL_AT_ZERO)
			+ (WOOD_TANGENTIAL_PER_G0 * g0 + WOOD_TANGENTIAL_AT_ZERO);
}

Dictionary organic_entry(const char *p_element_symbol, double p_entropy_j_kgk, const char *p_molar_mass,
		bool p_carries_nitrogen, bool p_vegetated) {
	Dictionary d;
	Dictionary f;
	f[String(p_element_symbol)] = 1.0;
	if (p_carries_nitrogen) {
		f["N"] = litter_n_per_c();
	}
	d["formula"] = f;
	d["molar_mass"] = pc(p_molar_mass);
	d["entropy_j_molk"] = p_entropy_j_kgk * pc(p_molar_mass);
	d["density"] = organic_mol_per_m3() * pc(p_molar_mass);
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["specific_heat_solid"] = pc("DRY_WOOD_SPECIFIC_HEAT_J_KGK");
	if (p_vegetated) {
		d["albedo"] = pc("ALBEDO_VEGETATION");
	}
	d["conductivity"] = pc("THERMAL_CONDUCT_ORGANIC_W_MK");
	// LA_APPROX: litter_pool_wood_expansivity
	d["expansion_per_k"] = wood_expansion_per_k();
	d["bulk_modulus_pa"] = ORGANIC_BULK_MODULUS_PA;
	d["bulk_modulus_deriv"] = ORGANIC_BULK_MODULUS_DERIV;
	return d;
}

Dictionary cellulose_entry() {
	Dictionary f;
	f["C"] = 1.0;
	f["H"] = 2.0;
	f["O"] = 1.0;
	f["N"] = litter_n_per_c();
	Dictionary d;
	d["formula"] = f;
	d["molar_mass"] = pc("MOLAR_MASS_CH2O_UNIT_KG_MOL");
	d["density"] = pc("DRY_WOOD_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["specific_heat_solid"] = pc("DRY_WOOD_SPECIFIC_HEAT_J_KGK");
	d["pyrolysis_ea_over_r_k"] = pc("CELLULOSE_PYROLYSIS_EA_OVER_R_K");
	d["albedo"] = pc("ALBEDO_VEGETATION");
	d["conductivity"] = pc("THERMAL_CONDUCT_CELLULOSE_W_MK");
	d["expansion_per_k"] = wood_expansion_per_k();
	d["bulk_modulus_pa"] = ORGANIC_BULK_MODULUS_PA;
	d["bulk_modulus_deriv"] = ORGANIC_BULK_MODULUS_DERIV;
	return d;
}

Dictionary silicate_entry() {
	const ElementCount f[] = { { "Ca", 1.0 }, { "Si", 1.0 }, { "O", 3.0 } };
	Dictionary d;
	d["formula"] = formula_of(f, 3);
	d["molar_mass"] = pc("MOLAR_MASS_CASIO3_KG_MOL");
	d["formation_enthalpy_j_mol"] = pc("FORMATION_ENTHALPY_CASIO3_J_MOL");
	d["entropy_j_molk"] = pc("ENTROPY_CASIO3_J_MOL_K");
	d["density"] = pc("ROCK_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["expansion_per_k"] = pc("ROCK_VOLUME_EXPANSION_PER_K");
	d["bulk_modulus_pa"] = pc("ROCK_BULK_MODULUS_PA");
	d["bulk_modulus_deriv"] = ROCK_BULK_MODULUS_DERIV;
	d["tensile_strength_pa"] = pc("BASALT_TENSILE_STRENGTH_PA");
	d["specific_heat_solid"] = pc("ROCK_SPECIFIC_HEAT_J_KGK");
	d["melt_c"] = pc("BASALT_SOLIDUS_C");
	d["liquidus_c"] = pc("BASALT_LIQUIDUS_C");
	d["latent_fusion_j_kg"] = pc("BASALT_LATENT_HEAT_CRYSTALLISATION_J_KG");
	d["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	d.merge(LAMeltEos::oxide_melt(d["formula"], pc("BASALT_LIQUIDUS_C")), true);
	// LA_APPROX: melt_compression_endmember
	d.merge(LAMeltEos::diopside_melt_compression(pc("BASALT_LIQUIDUS_C")), true);
	d["conductivity"] = pc("THERMAL_CONDUCT_ROCK_W_MK");
	d["emissivity"] = pc("BASALT_EMISSIVITY");
	d["albedo"] = pc("ALBEDO_BARE_GROUND");
	// One shell mineral of the undifferentiated-silicate mix, so it hosts the registry's traces.
	d["traces"] = LAElementAbundances::shell_traces();
	return d;
}

Dictionary rock_traces(const char *p_u, const char *p_th, const char *p_k) {
	Dictionary t;
	t["U"] = pc(p_u);
	t["Th"] = pc(p_th);
	t["K"] = pc(p_k);
	return t;
}

Dictionary silica_entry() {
	const ElementCount f[] = { { "Si", 1.0 }, { "O", 2.0 } };
	Dictionary d;
	d["formula"] = formula_of(f, 2);
	d["molar_mass"] = pc("MOLAR_MASS_SIO2_KG_MOL");
	d["formation_enthalpy_j_mol"] = pc("FORMATION_ENTHALPY_SIO2_J_MOL");
	d["entropy_j_molk"] = pc("ENTROPY_SIO2_J_MOL_K");
	d["density"] = pc("QUARTZ_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["expansion_per_k"] = pc("QUARTZ_VOLUME_EXPANSION_PER_K");
	d["bulk_modulus_pa"] = pc("QUARTZ_BULK_MODULUS_PA");
	d["bulk_modulus_deriv"] = QUARTZ_BULK_MODULUS_DERIV;
	d["specific_heat_solid"] = pc("QUARTZ_SPECIFIC_HEAT_J_KGK");
	d["conductivity"] = pc("THERMAL_CONDUCT_ROCK_W_MK");
	d["emissivity"] = pc("BASALT_EMISSIVITY");
	d["albedo"] = pc("ALBEDO_BARE_GROUND");
	// The quartz sand the weathering rows leave behind: sandstone's abundance, not the mantle's.
	d["traces"] = rock_traces("SANDSTONE_U_KG_PER_KG", "SANDSTONE_TH_KG_PER_KG", "SANDSTONE_K_KG_PER_KG");
	return d;
}

Dictionary carbonate_entry() {
	const ElementCount f[] = { { "Ca", 1.0 }, { "C", 1.0 }, { "O", 3.0 } };
	Dictionary d;
	d["formula"] = formula_of(f, 3);
	d["molar_mass"] = pc("MOLAR_MASS_CACO3_KG_MOL");
	d["formation_enthalpy_j_mol"] = pc("FORMATION_ENTHALPY_CACO3_J_MOL");
	d["entropy_j_molk"] = pc("ENTROPY_CACO3_J_MOL_K");
	d["density"] = pc("CALCITE_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["expansion_per_k"] = pc("CALCITE_VOLUME_EXPANSION_PER_K");
	d["bulk_modulus_pa"] = CALCITE_BULK_MODULUS_PA;
	d["bulk_modulus_deriv"] = CALCITE_BULK_MODULUS_DERIV;
	d["specific_heat_solid"] = pc("CALCITE_SPECIFIC_HEAT_J_KGK");
	d["conductivity"] = pc("THERMAL_CONDUCT_ROCK_W_MK");
	d["emissivity"] = pc("BASALT_EMISSIVITY");
	d["albedo"] = pc("ALBEDO_BARE_GROUND");
	// Precipitated calcite: uranium substitutes for calcium, thorium and potassium barely do.
	d["traces"] = rock_traces("LIMESTONE_U_KG_PER_KG", "LIMESTONE_TH_KG_PER_KG", "LIMESTONE_K_KG_PER_KG");
	return d;
}

// Fixed nitrogen: nitrogen bound to oxygen, the form a discharge and a flame both leave it in. Held
// DISSOLVED in the soil solution and on its exchange sites, so it displaces no volume of its own and
// carries no bulk modulus. Its further oxidation to nitrate is not modelled.
Dictionary fixed_n_entry() {
	const ElementCount f[] = { { "N", 1.0 }, { "O", 1.0 } };
	Dictionary d;
	d["formula"] = formula_of(f, 2);
	d["molar_mass"] = LAElementAbundances::molar_mass(d["formula"]);
	d["formation_enthalpy_j_mol"] = FORMATION_ENTHALPY_NO_J_MOL;
	d["entropy_gas_j_molk"] = ENTROPY_NO_GAS_J_MOLK;
	d["density"] = pc("ROCK_DENSITY_KG_M3");
	d["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	d["specific_heat_solid"] = pc("ROCK_SPECIFIC_HEAT_J_KGK");
	d["conductivity"] = pc("THERMAL_CONDUCT_ROCK_W_MK");
	return d;
}

Dictionary build_table() {
	Dictionary t;
	t["h2o"] = water_entry();
	for (int i = 0; i < int(sizeof(GASES) / sizeof(GasRow)); i++) {
		t[String(GASES[i].id)] = gas_entry(GASES[i]);
	}
	la_optics::declare(t);
	t["organic_c"] = organic_entry("C", WOOD_ENTROPY_C_J_KGK, "MOLAR_MASS_CARBON_KG_MOL", true, true);
	t["organic_h"] = organic_entry("H", WOOD_ENTROPY_H_J_KGK, "MOLAR_MASS_HYDROGEN_KG_MOL", false, false);
	t["organic_o"] = organic_entry("O", WOOD_ENTROPY_O_J_KGK, "MOLAR_MASS_OXYGEN_KG_MOL", false, false);
	t["cellulose"] = cellulose_entry();
	t["silicate"] = silicate_entry();
	t["silica"] = silica_entry();
	t["carbonate"] = carbonate_entry();
	t["fixed_n"] = fixed_n_entry();
	return t;
}

Dictionary &table_cache() {
	static Dictionary cache;
	return cache;
}

// The differentiated planet's phases. Formulas and solid-solution fractions are DERIVED from
// LAElementAbundances by LAPlanetComposition, so the table cannot disagree with the registry.
void add_planet_minerals() {
	Dictionary &t = table_cache();
	const Dictionary shell_tr = LAElementAbundances::shell_traces();
	Dictionary rock;
	rock["emissivity"] = pc("BASALT_EMISSIVITY");
	rock["albedo"] = pc("ALBEDO_BARE_GROUND");
	rock["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	rock["traces"] = shell_tr;

	const Dictionary f_metal = LAPlanetComposition::metal_formula();
	Dictionary metal_extra;
	metal_extra["density_ref_t_c"] = IRON_MELT_C;
	metal_extra["expansion_per_k"] = IRON_LIQUID_EXPANSION_PER_K;
	metal_extra["density_solid"] = IRON_SOLID_DENSITY_AT_MELT_KG_M3;
	metal_extra["density_solid_ref_t_c"] = IRON_MELT_C;
	metal_extra["expansion_solid_per_k"] = IRON_SOLID_EXPANSION_PER_K;
	metal_extra["bulk_modulus_solid_pa"] = isothermal_modulus(IRON_SOLID_BULK_MODULUS_S_PA, IRON_SOLID_EXPANSION_PER_K,
			IRON_SOLID_DENSITY_25C_KG_M3, IRON_SOLID_SPECIFIC_HEAT_J_KGK, pc("LAB_REFERENCE_TEMP_C"));
	metal_extra["bulk_modulus_solid_deriv"] = IRON_SOLID_BULK_MODULUS_DERIV;
	metal_extra["bulk_modulus_pa"] = isothermal_modulus(IRON_LIQUID_BULK_MODULUS_S_PA, IRON_LIQUID_EXPANSION_PER_K,
			IRON_LIQUID_DENSITY_KG_M3, IRON_LIQUID_SPECIFIC_HEAT_J_KGK, IRON_MELT_C);
	// LA_APPROX: unmeasured_pressure_derivative
	metal_extra["bulk_modulus_deriv"] = IRON_LIQUID_BULK_MODULUS_DERIV;
	metal_extra["specific_heat_solid"] = IRON_SOLID_SPECIFIC_HEAT_J_KGK;
	metal_extra["specific_heat"] = IRON_LIQUID_SPECIFIC_HEAT_J_KGK;
	metal_extra["melt_c"] = IRON_MELT_C;
	metal_extra["liquidus_c"] = IRON_MELT_C;
	metal_extra["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	metal_extra["latent_fusion_j_kg"] = IRON_LATENT_FUSION_J_KG;
	metal_extra["boil_c"] = IRON_BOIL_C;
	metal_extra["boil_ref_p_pa"] = pc("STANDARD_PRESSURE_PA");
	metal_extra["latent_vaporisation_j_kg"] = IRON_LATENT_VAPORISATION_J_KG;
	metal_extra["latent_vaporisation_ref_t_c"] = IRON_BOIL_C;
	metal_extra["critical_t_c"] = IRON_CRITICAL_T_C;
	metal_extra["critical_p_pa"] = IRON_CRITICAL_P_PA;
	metal_extra["traces"] = LAElementAbundances::core_traces();
	metal_extra["specific_heat_gas"] = IRON_VAPOUR_CP_J_MOLK / LAElementAbundances::molar_mass(f_metal);
	// LA_APPROX: pure_iron_core_alloy
	t["metal"] = entry(f_metal, IRON_LIQUID_DENSITY_KG_M3, IRON_LIQUID_SPECIFIC_HEAT_J_KGK,
			IRON_CONDUCTIVITY_W_MK, metal_extra);

	const double m = LAPlanetComposition::mg_number();
	// LA_APPROX: ideal_solid_solution
	const Dictionary f_ol = LAPlanetComposition::olivine_formula();
	const double mm_ol = LAElementAbundances::molar_mass(f_ol);
	Dictionary ol_extra;
	ol_extra["expansion_per_k"] = m * FORSTERITE_EXPANSION_PER_K + (1.0 - m) * FAYALITE_EXPANSION_PER_K;
	ol_extra["bulk_modulus_pa"] = m * FORSTERITE_BULK_MODULUS_PA + (1.0 - m) * FAYALITE_BULK_MODULUS_PA;
	ol_extra["bulk_modulus_deriv"] = m * FORSTERITE_BULK_MODULUS_DERIV + (1.0 - m) * FAYALITE_BULK_MODULUS_DERIV;
	ol_extra["melt_c"] = FORSTERITE_MELT_C;
	ol_extra["liquidus_c"] = FORSTERITE_MELT_C;
	ol_extra["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	ol_extra["latent_fusion_j_kg"] = FORSTERITE_FUSION_J_MOL / mm_ol;
	ol_extra.merge(LAMeltEos::oxide_melt(f_ol, FORSTERITE_MELT_C), true);
	ol_extra.merge(LAMeltEos::olivine_melt_compression(m, FORSTERITE_MELT_C), true);
	t["olivine"] = entry(f_ol, OLIVINE_DENSITY_KG_M3,
			(m * FORSTERITE_CP_J_MOLK + (1.0 - m) * FAYALITE_CP_J_MOLK) / mm_ol,
			OLIVINE_CONDUCTIVITY_W_MK, rock.merged(ol_extra, true));

	const Dictionary f_px = LAPlanetComposition::pyroxene_formula();
	Dictionary px_extra;
	px_extra["expansion_per_k"] = ENSTATITE_EXPANSION_PER_K;
	px_extra["bulk_modulus_pa"] = ENSTATITE_BULK_MODULUS_PA;
	px_extra["bulk_modulus_deriv"] = ENSTATITE_BULK_MODULUS_DERIV;
	px_extra["melt_c"] = ENSTATITE_MELT_C;
	px_extra["liquidus_c"] = ENSTATITE_MELT_C;
	px_extra["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	px_extra["latent_fusion_j_kg"] = ENSTATITE_FUSION_J_MOL / ENSTATITE_MOLAR_MASS_KG_MOL;
	px_extra.merge(LAMeltEos::oxide_melt(f_px, ENSTATITE_MELT_C), true);
	// LA_APPROX: melt_compression_endmember
	px_extra.merge(LAMeltEos::enstatite_melt_compression(ENSTATITE_MELT_C), true);
	t["pyroxene"] = entry(f_px, ENSTATITE_DENSITY_KG_M3,
			ENSTATITE_CP_J_MOLK / ENSTATITE_MOLAR_MASS_KG_MOL, ENSTATITE_CONDUCTIVITY_W_MK,
			rock.merged(px_extra, true));

	// Endmember data mixed ideally at the derived An fraction; the melting interval is the endmember loop.
	const double x = LAPlanetComposition::an_fraction();
	const Dictionary f_pl = LAPlanetComposition::plagioclase_formula();
	const double mm_pl = LAElementAbundances::molar_mass(f_pl);
	Dictionary pl_extra;
	pl_extra["expansion_per_k"] = x * ANORTHITE_EXPANSION_PER_K + (1.0 - x) * ALBITE_EXPANSION_PER_K;
	pl_extra["bulk_modulus_pa"] = x * ANORTHITE_BULK_MODULUS_PA + (1.0 - x) * ALBITE_BULK_MODULUS_PA;
	pl_extra["bulk_modulus_deriv"] = x * ANORTHITE_BULK_MODULUS_DERIV + (1.0 - x) * ALBITE_BULK_MODULUS_DERIV;
	pl_extra["melt_c"] = ALBITE_MELT_C;
	pl_extra["liquidus_c"] = ANORTHITE_MELT_C;
	pl_extra["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	pl_extra["latent_fusion_j_kg"] = (x * ANORTHITE_FUSION_J_MOL + (1.0 - x) * ALBITE_FUSION_J_MOL) / mm_pl;
	pl_extra.merge(LAMeltEos::oxide_melt(f_pl, ANORTHITE_MELT_C), true);
	// LA_APPROX: melt_compression_endmember
	pl_extra.merge(LAMeltEos::anorthite_melt_compression(ANORTHITE_MELT_C), true);
	t["plagioclase"] = entry(f_pl,
			x * ANORTHITE_DENSITY_KG_M3 + (1.0 - x) * ALBITE_DENSITY_KG_M3,
			(x * ANORTHITE_CP_J_MOLK + (1.0 - x) * ALBITE_CP_J_MOLK) / mm_pl,
			x * ANORTHITE_CONDUCTIVITY_W_MK + (1.0 - x) * ALBITE_CONDUCTIVITY_W_MK,
			rock.merged(pl_extra, true));

	const ElementCount f_hal_rows[] = { { "Na", 1.0 }, { "Cl", 1.0 } };
	const Dictionary f_hal = formula_of(f_hal_rows, 2);
	const double mm_hal = LAElementAbundances::molar_mass(f_hal);
	Dictionary hal_extra;
	hal_extra["density_ref_t_c"] = pc("LAB_REFERENCE_TEMP_C");
	hal_extra["expansion_per_k"] = HALITE_EXPANSION_PER_K;
	hal_extra["bulk_modulus_pa"] = HALITE_BULK_MODULUS_PA;
	hal_extra["bulk_modulus_deriv"] = HALITE_BULK_MODULUS_DERIV;
	hal_extra["melt_c"] = HALITE_MELT_C;
	hal_extra["liquidus_c"] = HALITE_MELT_C;
	hal_extra["melt_p_pa"] = pc("STANDARD_PRESSURE_PA");
	hal_extra["latent_fusion_j_kg"] = HALITE_FUSION_J_MOL / mm_hal;
	hal_extra.merge(LAMeltEos::halite_melt(HALITE_MELT_C), true);
	hal_extra["traces"] = shell_tr;
	t["halite"] = entry(f_hal, HALITE_DENSITY_KG_M3, HALITE_CP_J_MOLK / mm_hal,
			HALITE_CONDUCTIVITY_W_MK, hal_extra);

	const Dictionary f_ap = LAPlanetComposition::apatite_formula();
	Dictionary ap_extra = rock.duplicate();
	ap_extra["expansion_per_k"] = APATITE_EXPANSION_PER_K;
	ap_extra["bulk_modulus_pa"] = APATITE_BULK_MODULUS_PA;
	ap_extra["bulk_modulus_deriv"] = APATITE_BULK_MODULUS_DERIV;
	t["apatite"] = entry(f_ap, APATITE_DENSITY_KG_M3,
			APATITE_CP_J_MOLK / LAElementAbundances::molar_mass(f_ap), APATITE_CONDUCTIVITY_W_MK, ap_extra);
}

// Formation enthalpies of the dead organic pool's elements, J/mol, by Hess from the oxidation heats.
void add_organic_formation() {
	Dictionary &t = table_cache();
	Dictionary c = t["organic_c"];
	c["formation_enthalpy_j_mol"] = pc("FORMATION_ENTHALPY_CO2_J_MOL")
			+ LASubstances::organic_energy_j_mol("C");
	Dictionary h = t["organic_h"];
	h["formation_enthalpy_j_mol"] = 0.5 * FORMATION_ENTHALPY_H2O_GAS_J_MOL
			+ LASubstances::organic_energy_j_mol("H");
	Dictionary o = t["organic_o"];
	o["formation_enthalpy_j_mol"] = LASubstances::organic_energy_j_mol("O");
	// Living tissue is the same elements at the same ratios, so it is the same sum: one price for the
	// carbon-hydrogen-oxygen bond, whether a plant holds it or the litter does.
	Dictionary cl = t["cellulose"];
	cl["formation_enthalpy_j_mol"] = double(c["formation_enthalpy_j_mol"])
			+ LASubstances::fresh_litter_per_carbon("H") * double(h["formation_enthalpy_j_mol"])
			+ LASubstances::fresh_litter_per_carbon("O") * double(o["formation_enthalpy_j_mol"]);
}

Dictionary row_of(const String &p_id) {
	return Dictionary(LASubstances::table().get(p_id, Dictionary()));
}

double dget(const Dictionary &p_d, const char *p_key, double p_default) {
	return double(p_d.get(p_key, p_default));
}

// True when this row's phase boundaries are the IAPWS formulations rather than the two-anchor law.
bool iapws_curves(const Dictionary &p_s) {
	return bool(p_s.get("iapws", false));
}

// ln p = A - B/T, with B fixed by the TWO measured points the table carries -- the triple point and the
// normal boiling point -- so both are reproduced exactly and B * R_v is the MEAN latent heat over the
// interval.
double clapeyron_b(const String &p_id) {
	const Dictionary s = row_of(p_id);
	const double t2_c = dget(s, "boil_c", kInf);
	if (!std::isfinite(t2_c)) {
		return 0.0;
	}
	const double p2 = dget(s, "boil_ref_p_pa", pc("STANDARD_PRESSURE_PA"));
	const double t1_c = dget(s, "triple_t_c", kInf);
	const double p1 = dget(s, "triple_p_pa", 0.0);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	if (std::isfinite(t1_c) && p1 > 0.0 && p2 > 0.0 && std::abs(t1_c - t2_c) > 0.0) {
		const double inv = 1.0 / (t1_c + KELVIN_OFFSET) - 1.0 / (t2_c + KELVIN_OFFSET);
		if (std::abs(inv) > 0.0) {
			return std::log(p2 / p1) / inv;
		}
	}
	// THIS substance's specific gas constant, R over its molar mass -- not water's.
	const double mm = dget(s, "molar_mass", 0.0);
	if (mm <= 0.0) {
		return 0.0;
	}
	return LASubstances::latent_vaporisation_at(p_id, t2_c) * mm / pc("GAS_CONSTANT_J_MOL_K");
}

// THIS substance's specific gas constant, J/kg/K -- R over its molar mass, never water's.
double r_specific(const String &p_id) {
	const double mm = dget(row_of(p_id), "molar_mass", 0.0);
	return mm > 0.0 ? pc("GAS_CONSTANT_J_MOL_K") / mm : 0.0;
}

// Monatomic ideal-gas heat capacity of the dissociated substance, J/kgK: (3/2)R per mole of ATOMS.
double monatomic_c_j_kgk(const String &p_id) {
	const Dictionary s = row_of(p_id);
	const double mm = dget(s, "molar_mass", 0.0);
	const Dictionary f = Dictionary(s.get("formula", Dictionary()));
	double atoms = 0.0;
	const Array keys = f.keys();
	for (int i = 0; i < keys.size(); i++) {
		atoms += double(f[keys[i]]);
	}
	if (mm <= 0.0 || atoms <= 0.0) {
		return 0.0;
	}
	return 1.5 * pc("GAS_CONSTANT_J_MOL_K") * atoms / mm;
}

// Specific enthalpy at a temperature above boiling: sensible heat of the gas, plus the share of the
// atomisation and ionisation energies the equilibrium has actually paid for at that temperature.
double gas_enthalpy_at(const String &p_id, double p_t_c, double p_p_pa, double p_boil,
		double p_h_boil_end, double p_c_gas) {
	const double t_k = p_t_c + pc("KELVIN_OFFSET");
	const double a_d = LASubstances::dissociated_fraction(p_id, t_k, p_p_pa);
	const double a_i = LASubstances::ionised_fraction(p_id, t_k, p_p_pa);
	// Once dissociated the carrier is monatomic, so the sensible term crosses over with the fraction.
	const double c_eff = p_c_gas + (monatomic_c_j_kgk(p_id) - p_c_gas) * a_d;
	return p_h_boil_end + c_eff * (p_t_c - p_boil) + a_d * LASubstances::dissociation_j_kg(p_id)
			+ a_d * a_i * LASubstances::ionisation_j_kg(p_id);
}

// Invert h(T) above the boiling plateau. h rises monotonically with T, so bisection is exact to
// tolerance and needs no starting guess.
double invert_gas_enthalpy(const String &p_id, double p_h_j_kg, double p_p_pa, double p_boil,
		double p_h_boil_end, double p_c_gas) {
	double lo = p_boil;
	double hi = p_boil + 1.0e5;
	for (int i = 0; i < 60; i++) {
		const double mid = 0.5 * (lo + hi);
		if (gas_enthalpy_at(p_id, mid, p_p_pa, p_boil, p_h_boil_end, p_c_gas) < p_h_j_kg) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

// ABOVE A CONDENSATION PLATEAU the two high transitions are EQUILIBRIA, not plateaus (law of mass action,
// Saha), so enthalpy stays continuous and monotonic and the state is found by inverting it.
Dictionary gas_state(const String &p_id, double p_h_j_kg, double p_p_pa, double p_ref_t_c,
		double p_h_ref, double p_c_gas, double p_melted) {
	const Dictionary s = row_of(p_id);
	const double t_gas = invert_gas_enthalpy(p_id, p_h_j_kg, p_p_pa, p_ref_t_c, p_h_ref, p_c_gas);
	const double t_k = t_gas + pc("KELVIN_OFFSET");
	const double a_d = LASubstances::dissociated_fraction(p_id, t_k, p_p_pa);
	const double a_i = LASubstances::ionised_fraction(p_id, t_k, p_p_pa);
	int ph = LASubstances::GAS;
	const double p_crit = dget(s, "critical_p_pa", kInf);
	const double t_crit = dget(s, "critical_t_c", kInf);
	if (std::isfinite(p_crit) && p_p_pa >= p_crit && t_gas >= t_crit) {
		ph = LASubstances::SUPERCRITICAL;
	}
	if (a_i >= 0.5) {
		ph = LASubstances::PLASMA;
	} else if (a_d >= 0.5) {
		ph = LASubstances::ATOMS;
	}
	Dictionary out;
	out["t_c"] = t_gas;
	out["phase"] = ph;
	out["melted"] = p_melted;
	out["vaporised"] = 1.0;
	out["dissociated"] = a_d;
	out["ionised"] = a_i;
	return out;
}

// THE LADDER'S ANCHOR: every phase is integrated outward from the row's standard state, where its
// sensible enthalpy is zero (LAPhaseEosFn::anchor). Its energy where the solid starts to melt, J/kg.
double anchor_melt_start(int p_anchor, double p_t_ref, double p_c_sol, double p_c_liq, double p_c_gas,
		double p_melt, double p_boil, double p_l_fus, double p_l_vap) {
	if (p_anchor == 0) {
		return p_c_sol * (p_melt - p_t_ref);
	}
	if (p_anchor == 1) {
		return p_c_liq * (p_melt - p_t_ref) - p_l_fus;
	}
	return p_c_gas * (p_boil - p_t_ref) - p_l_vap - p_c_liq * (p_boil - p_melt) - p_l_fus;
}

// Below the triple pressure: the solid's energy at the frost point, J/kg. A liquid anchor reaches it
// through the triple point.
double anchor_sub_start(int p_anchor, double p_t_ref, double p_c_sol, double p_c_liq, double p_c_gas,
		double p_t_sub, double p_l_sub, double p_t_triple, double p_l_fus) {
	if (p_anchor == 0) {
		return p_c_sol * (p_t_sub - p_t_ref);
	}
	if (p_anchor == 2) {
		return p_c_gas * (p_t_sub - p_t_ref) - p_l_sub;
	}
	return p_c_liq * (p_t_triple - p_t_ref) - p_l_fus - p_c_sol * (p_t_triple - p_t_sub);
}

} // namespace


// The one table. Cached because it is read per cell and per substance on hot paths, and it is built
// entirely from constants; no caller writes to it.
Dictionary LASubstances::table() {
	Dictionary &cache = table_cache();
	if (cache.is_empty()) {
		cache = build_table();
		add_organic_formation();
		add_planet_minerals();
	}
	return cache;
}

// Moles of one element per mole of CARBON in FRESH litter -- the composition a living plant sheds, read
// off the cellulose entry so a credit into the dead pool cannot disagree with the table about litter.
double LASubstances::fresh_litter_per_carbon(const String &p_element) {
	const Dictionary f = Dictionary(row_of("cellulose").get("formula", Dictionary()));
	const double c = dget(f, "C", 0.0);
	if (c <= 0.0) {
		return 0.0;
	}
	return double(f.get(p_element, 0.0)) / c;
}

// Heat released by fully oxidising ONE MOLE of one element of the dead organic pool, J/mol; water leaves
// as vapour.
namespace {

// Standard formation enthalpy of what a reaction slot holds, J/mol; NaN when the table has none. A DERIVED
// slot reads a condensed reservoir, so a vapour-referenced datum is walked down its heat of vaporisation.
double slot_formation_j_mol(const String &p_id, bool p_derived) {
	const Dictionary s = row_of(p_id);
	if (!s.has("formation_enthalpy_j_mol")) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	const double dh = dget(s, "formation_enthalpy_j_mol", 0.0);
	if (!p_derived) {
		return dh;
	}
	return dh - dget(s, "molar_mass", 0.0)
			* LASubstances::latent_vaporisation_at(p_id, pc("LAB_REFERENCE_TEMP_C"));
}

} // namespace

// What the table says about one reaction record: the heat it releases per mole of extent as base / H:C /
// O:C parts, the net moles of GAS it makes on the same split, and the standard entropy change. Empty when
// a participant has no formation enthalpy. A record that only moves a substance between slots releases
// nothing -- the enthalpy ladder books that.
Dictionary LASubstances::reaction_terms(const Dictionary &p_rec, const Dictionary &p_slot_substance,
		const Dictionary &p_derived_slots) {
	Dictionary net;
	Vector3 heat, dn;
	double ds = 0.0;
	bool has_entropy = true;
	const char *sides[] = { "reactants", "products" };
	for (int k = 0; k < 2; k++) {
		const double sgn = k == 0 ? -1.0 : 1.0;
		const Array side = Array(p_rec.get(sides[k], Array()));
		for (int e = 0; e < side.size(); e++) {
			const Array entry = Array(side[e]);
			const int slot = int(entry[0]);
			const String id = String(p_slot_substance.get(slot, String()));
			const bool derived = p_derived_slots.has(slot);
			const double form = slot_formation_j_mol(id, derived);
			if (std::isnan(form)) {
				return Dictionary();
			}
			const Vector3 v = float(sgn) * Vector3(float(entry[1]),
					entry.size() > 2 ? float(entry[2]) : 0.0f, entry.size() > 3 ? float(entry[3]) : 0.0f);
			net[id] = Vector3(net.get(id, Vector3())) + v;
			heat -= float(form) * v;
			const Dictionary s = row_of(id);
			const double entropy = dget(s, "entropy_j_molk", dget(s, "entropy_gas_j_molk", 0.0));
			has_entropy = has_entropy && entropy > 0.0;
			ds += sgn * double(entry[1]) * entropy;
			// Gaseous in the state the heat is referenced to: a standard gas entropy, and not a derived
			// slot, which reads a condensed reservoir out of a cell that holds one.
			if (!derived && dget(s, "entropy_gas_j_molk", 0.0) > 0.0) {
				dn += v;
			}
		}
	}
	const Array ids = net.keys();
	bool transport = true;
	for (int i = 0; i < ids.size(); i++) {
		transport = transport && Vector3(net[ids[i]]).length() <= 1.0e-9f;
	}
	Dictionary out;
	out["enthalpy_j_mol"] = transport ? 0.0f : heat.x;
	out["enthalpy_h_j_mol"] = transport ? 0.0f : heat.y;
	out["enthalpy_o_j_mol"] = transport ? 0.0f : heat.z;
	out["dn_gas"] = dn.x;
	out["dn_gas_h"] = dn.y;
	out["dn_gas_o"] = dn.z;
	out["entropy_j_molk"] = has_entropy ? ds : std::numeric_limits<double>::quiet_NaN();
	return out;
}

double LASubstances::organic_energy_j_mol(const String &p_element) {
	if (p_element == "C") {
		const double n_per_c = litter_n_per_c();
		return HHV_PER_KG_C_J * pc("MOLAR_MASS_CARBON_KG_MOL")
				+ n_per_c * HHV_PER_KG_N_J * pc("MOLAR_MASS_NITROGEN_KG_MOL");
	}
	if (p_element == "H") {
		const double water_per_h = pc("MOLAR_MASS_WATER_KG_MOL") / (2.0 * pc("MOLAR_MASS_HYDROGEN_KG_MOL"));
		const double lhv = HHV_PER_KG_H_J
				- water_per_h * latent_vaporisation_at("h2o", pc("LAB_REFERENCE_TEMP_C"));
		return lhv * pc("MOLAR_MASS_HYDROGEN_KG_MOL");
	}
	if (p_element == "O") {
		return HHV_PER_KG_O_J * pc("MOLAR_MASS_OXYGEN_KG_MOL");
	}
	return 0.0;
}

// Latent heat of sublimation, J/kg -- DERIVED as fusion + vaporisation so Hess's law cannot be violated.
double LASubstances::latent_sublimation_j_kg(const String &p_id) {
	const Dictionary s = row_of(p_id);
	return dget(s, "latent_fusion_j_kg", 0.0) + dget(s, "latent_vaporisation_j_kg", 0.0);
}

double LASubstances::solid_density(const String &p_id) {
	return LAPhaseEosFn::condensed(p_id).solid.rho;
}

double LASubstances::liquid_density(const String &p_id) {
	return LAPhaseEosFn::condensed(p_id).liquid.rho;
}

Dictionary LASubstances::eos_of(const String &p_id) {
	return LAPhaseEosFn::describe(p_id);
}

// True when this row carries an equation of state. A row without one has that dependence UNMEASURED
// here, not zero, and reports its reference value unchanged.
bool LASubstances::has_eos(const String &p_id) {
	const Dictionary s = row_of(p_id);
	return s.has("expansion_per_k") || s.has("bulk_modulus_pa")
			|| s.has("expansion_solid_per_k") || s.has("bulk_modulus_solid_pa");
}

// Density at a temperature and pressure, kg/m^3. `p_p_pa` is the partial pressure of THIS substance. A
// fluid is the Peng-Robinson root at that partial pressure; a condensed state is the one rule's.
double LASubstances::density(const String &p_id, double p_t_c, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	if (s.is_empty()) {
		return 0.0;
	}
	if (LAPhaseEosFn::gas_at(p_id, p_t_c, p_p_pa)) {
		const double mm = dget(s, "molar_mass", 0.0);
		const LAFluidEos &f = LAPhaseEosFn::fluid(p_id);
		ERR_FAIL_COND_V_MSG(!f.valid, NAN, "LASubstances.density(\"" + p_id + "\"): the row has no fluid "
				"equation of state (no critical point or no acentric factor).");
		const double v = LAPhaseEosFn::pr_molar_volume(f, p_t_c + pc("KELVIN_OFFSET"), p_p_pa);
		return (mm > 0.0 && v > 0.0) ? mm / v : 0.0;
	}
	const double v = LAPhaseEosFn::condensed_volume(LAPhaseEosFn::condensed(p_id), p_t_c, p_p_pa);
	return std::isnan(v) ? NAN : (v > 0.0 ? 1.0 / v : 0.0);
}

// mol/m^3 at which a cell is FULL of this substance: density over molar mass. 0 and a named error when
// the table lacks a datum.
double LASubstances::full_mol_m3(const String &p_id) {
	const Dictionary s = row_of(p_id);
	const double rho = dget(s, "density", 0.0);
	const double m = dget(s, "molar_mass", 0.0);
	if (rho <= 0.0 || m <= 0.0) {
		ERR_FAIL_V_MSG(0.0, "LASubstances.full_mol_m3(\"" + p_id + "\"): the table gives no density or molar mass.");
	}
	return rho / m;
}

// SPECIFIC ENTHALPY (J/kg) at a temperature, referenced to the solid at 0 K. The inverse of
// enthalpy_to_state(), rung for rung; on a ZERO-WIDTH plateau it returns the LOWER end.
double LASubstances::enthalpy_at(const String &p_id, double p_t_c, double p_p_pa,
		double p_molality_mol_kg) {
	const Dictionary s = row_of(p_id);
	const double c_liq = dget(s, "specific_heat", NAN);
	const double c_sol = dget(s, "specific_heat_solid", NAN);
	const double c_gas = dget(s, "specific_heat_gas", NAN);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const LAAnchor &anc = LAPhaseEosFn::anchor(p_id);
	const int anchor = anc.phase;
	const double t_ref = anc.t_c;
	const double t_triple = dget(s, "triple_t_c", NAN);
	// Pressure-dependent, and depressed by any dissolved solute. For water the Clapeyron slope is negative.
	const double melt_row = melt_c_at(p_id, p_p_pa, p_molality_mol_kg);
	const bool has_melt = std::isfinite(melt_row);
	const double boil = boil_c_at(p_id, p_p_pa);
	if (!has_melt && !std::isfinite(boil)) {
		// Never melts on this planet: the solid's sensible heat from the standard state.
		return c_sol * (p_t_c - t_ref);
	}
	// A row with no solid is liquid from absolute zero: its fusion rung stands at 0 K and costs nothing.
	const double melt = has_melt ? melt_row : -KELVIN_OFFSET;
	const double l_fus = has_melt ? double(s["latent_fusion_j_kg"]) : 0.0;

	// NO LIQUID BELOW THE TRIPLE POINT. The plateau crossed is SUBLIMATION at the frost point.
	if (sublimes_at(p_id, p_p_pa)) {
		const double t_sub = sublimation_c_at(p_id, p_p_pa);
		const double l_sub = latent_sublimation_j_kg(p_id);
		const double h_sub_start = anchor_sub_start(anchor, t_ref, c_sol, c_liq, c_gas, t_sub, l_sub, t_triple, l_fus);
		if (p_t_c <= t_sub) {
			return p_t_c == t_sub ? h_sub_start : h_sub_start - c_sol * (t_sub - p_t_c);
		}
		return gas_enthalpy_at(p_id, p_t_c, p_p_pa, t_sub, h_sub_start + l_sub, c_gas);
	}

	const double liquidus = has_melt ? liquidus_c_at(p_id, p_p_pa, p_molality_mol_kg) : -KELVIN_OFFSET;
	const double l_vap = std::isfinite(boil) ? latent_vaporisation_at(p_id, boil) : 0.0;
	const double h_start = anchor_melt_start(anchor, t_ref, c_sol, c_liq, c_gas, melt, boil, l_fus, l_vap);
	if (p_t_c <= melt) {
		return p_t_c == melt ? h_start : h_start - c_sol * (melt - p_t_c);
	}
	const double h_end = h_start + l_fus + c_liq * (liquidus - melt);
	if (p_t_c < liquidus) {
		// Lever rule across the mush: solid and liquid enthalpies weighted by the melt fraction.
		const double x = p_t_c - melt;
		const double phi = x / (liquidus - melt);
		return h_start + c_sol * x + phi * (l_fus + (c_liq - c_sol) * x);
	}
	if (!std::isfinite(boil) || p_t_c <= boil) {
		return h_end + c_liq * (p_t_c - liquidus);
	}
	// THE LATENT HEAT AT THE BOUNDARY, not the table's reference value: the plateau is zero at the
	// critical point. Above it the atomisation and ionisation energies are paid by equilibrium.
	const double h_top = h_end + c_liq * (boil - liquidus) + l_vap;
	return gas_enthalpy_at(p_id, p_t_c, p_p_pa, boil, h_top, c_gas);
}

// THE BOILING POINT AT A GIVEN PRESSURE -- the boundary curve solved for temperature.
double LASubstances::boil_c_at(const String &p_id, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	if (iapws_curves(s)) {
		return la_water::iapws_saturation_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	const double t_ref_c = dget(s, "boil_c", kInf);
	if (!std::isfinite(t_ref_c)) {
		return kInf;
	}
	const double p_ref = dget(s, "boil_ref_p_pa", pc("STANDARD_PRESSURE_PA"));
	const double p_crit = dget(s, "critical_p_pa", kInf);
	const double t_crit = dget(s, "critical_t_c", kInf);
	if (std::isfinite(p_crit) && p_p_pa >= p_crit) {
		return t_crit;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p = p_p_pa > 1.0 ? p_p_pa : 1.0;
	const double t_ref_k = t_ref_c + KELVIN_OFFSET;
	const double b = clapeyron_b(p_id);
	if (b <= 0.0) {
		return t_ref_c;
	}
	const double inv_t = 1.0 / t_ref_k - std::log(p / p_ref) / b;
	// Past the curve's own limit no temperature boils it: condensed at every T.
	if (inv_t <= 0.0) {
		return kInf;
	}
	const double t_c = 1.0 / inv_t - KELVIN_OFFSET;
	// The boundary cannot run past the critical point; beyond it the two phases are one.
	return std::isfinite(t_crit) ? (t_c < t_crit ? t_c : t_crit) : t_c;
}

Dictionary LASubstances::element_ionisation_ev() {
	Dictionary d;
	d["H"] = pc("IONISATION_EV_H");
	d["O"] = pc("IONISATION_EV_O");
	d["C"] = pc("IONISATION_EV_C");
	d["N"] = pc("IONISATION_EV_N");
	d["Si"] = pc("IONISATION_EV_SI");
	d["Ca"] = pc("IONISATION_EV_CA");
	d["Fe"] = pc("IONISATION_EV_FE");
	d["Mg"] = pc("IONISATION_EV_MG");
	d["Al"] = pc("IONISATION_EV_AL");
	d["S"] = pc("IONISATION_EV_S");
	return d;
}

Dictionary LASubstances::element_degen() {
	Dictionary d;
	const char *els[] = { "H", "O", "C", "N", "S" };
	const char *g0[] = { "DEGEN_H_0", "DEGEN_O_0", "DEGEN_C_0", "DEGEN_N_0", "DEGEN_S_0" };
	const char *g1[] = { "DEGEN_H_1", "DEGEN_O_1", "DEGEN_C_1", "DEGEN_N_1", "DEGEN_S_1" };
	for (int i = 0; i < 5; i++) {
		Array pair;
		pair.push_back(pc(g0[i]));
		pair.push_back(pc(g1[i]));
		d[String(els[i])] = pair;
	}
	return d;
}

Dictionary LASubstances::element_entropy_j_molk() {
	Dictionary d;
	d["H"] = pc("ENTROPY_H_ATOM_J_MOLK");
	d["O"] = pc("ENTROPY_O_ATOM_J_MOLK");
	d["C"] = pc("ENTROPY_C_ATOM_J_MOLK");
	d["N"] = pc("ENTROPY_N_ATOM_J_MOLK");
	d["S"] = pc("ENTROPY_S_ATOM_J_MOLK");
	return d;
}

// Dissociated fraction at temperature and pressure, from the law of mass action. M <-> v atoms, with
// dG = dH_atomisation - T dS and dS the free atoms' standard entropies minus the molecule's.
double LASubstances::dissociated_fraction(const String &p_id, double p_t_k, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	const double dh = dget(s, "atomisation_j_mol", 0.0);
	const double s_mol = dget(s, "entropy_gas_j_molk", 0.0);
	if (dh <= 0.0 || s_mol <= 0.0 || p_t_k <= 0.0) {
		return 0.0;
	}
	const Dictionary s_ent = element_entropy_j_molk();
	const Dictionary f = Dictionary(s.get("formula", Dictionary()));
	double nu = 0.0;
	double s_atoms = 0.0;
	const Array keys = f.keys();
	for (int i = 0; i < keys.size(); i++) {
		const double n = double(f[keys[i]]);
		if (!s_ent.has(keys[i])) {
			return 0.0;
		}
		nu += n;
		s_atoms += n * double(s_ent[keys[i]]);
	}
	if (nu <= 1.0) {
		return 0.0;
	}
	const double dg = dh - p_t_k * (s_atoms - s_mol);
	const double ln_k = -dg / (pc("GAS_CONSTANT_J_MOL_K") * p_t_k);
	// Bisect on the extent. K_p(alpha) is monotonic increasing, so a bracket search is exact to tolerance.
	const double pr = (p_p_pa > 1.0 ? p_p_pa : 1.0) / pc("STANDARD_PRESSURE_PA");
	double lo = 0.0;
	double hi = 1.0;
	for (int i = 0; i < 48; i++) {
		const double a = 0.5 * (lo + hi);
		const double tot = 1.0 + (nu - 1.0) * a;
		const double x_a = nu * a / tot;
		const double x_m = (1.0 - a) / tot;
		double lhs = -1.0e30;
		if (x_m > 1.0e-30 && x_a > 1.0e-30) {
			lhs = nu * std::log(x_a) - std::log(x_m) + (nu - 1.0) * std::log(pr);
		}
		if (lhs < ln_k) {
			lo = a;
		} else {
			hi = a;
		}
	}
	return 0.5 * (lo + hi);
}

// Ionised fraction from the SAHA equation, per element and mole-weighted. Single stage: the closed-form
// root of x^2/(1-x) = S.
double LASubstances::ionised_fraction(const String &p_id, double p_t_k, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	const Dictionary f = Dictionary(s.get("formula", Dictionary()));
	if (f.is_empty() || p_t_k <= 0.0) {
		return 0.0;
	}
	const double boltzmann = pc("BOLTZMANN_J_K");
	const double planck = pc("PLANCK_J_S");
	const double n_m3 = (p_p_pa > 1.0 ? p_p_pa : 1.0) / (boltzmann * p_t_k);
	const double kt = boltzmann * p_t_k;
	// The thermal de Broglie factor, (2 pi m_e k T / h^2)^(3/2).
	const double lam = std::pow(2.0 * kPi * pc("ELECTRON_MASS_KG") * kt / (planck * planck), 1.5);
	const Dictionary ev = element_ionisation_ev();
	const Dictionary dg = element_degen();
	const double ev_to_j_mol = pc("EV_TO_J_PER_MOL");
	const double avogadro = pc("AVOGADRO_PER_MOL");
	double atoms = 0.0;
	double ion_atoms = 0.0;
	const Array keys = f.keys();
	for (int i = 0; i < keys.size(); i++) {
		const double n = double(f[keys[i]]);
		atoms += n;
		if (!ev.has(keys[i]) || !dg.has(keys[i])) {
			continue;
		}
		const double chi = double(ev[keys[i]]) * ev_to_j_mol / avogadro;
		const Array g = dg[keys[i]];
		const double g0 = double(g[0]) > 1.0 ? double(g[0]) : 1.0;
		const double ratio = 2.0 * double(g[1]) / g0;
		const double big = ratio * lam * std::exp(-chi / kt) / (n_m3 > 1.0 ? n_m3 : 1.0);
		double x = 0.0;
		if (big > 0.0) {
			x = 0.5 * (-big + std::sqrt(big * big + 4.0 * big));
		}
		ion_atoms += n * (x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x));
	}
	return atoms > 0.0 ? ion_atoms / atoms : 0.0;
}

// Melting point at pressure, and depressed by dissolved solute: the one rule's solidus, whose Clapeyron
// slope takes both phases at the melting point.
double LASubstances::melt_c_at(const String &p_id, double p_p_pa, double p_molality_mol_kg) {
	const LACondensedEos &c = LAPhaseEosFn::condensed(p_id);
	double t_c = LAPhaseEosFn::solidus_c(c, p_p_pa);
	if (!std::isfinite(t_c)) {
		return kInf;
	}
	// van 't Hoff, about the PURE solvent's melting point at this pressure: K_f = R T_m^2 / L_fus.
	const double l_fus = dget(row_of(p_id), "latent_fusion_j_kg", 0.0);
	if (p_molality_mol_kg > 0.0 && l_fus > 0.0) {
		const double t_m_k = t_c + pc("KELVIN_OFFSET");
		t_c -= pc("GAS_CONSTANT_J_MOL_K") * t_m_k * t_m_k / l_fus * p_molality_mol_kg;
	}
	return t_c;
}

// THE LIQUIDUS AT PRESSURE -- the temperature the last crystal goes. Water is the degenerate case where
// it meets the solidus. DECISION, not a law: the interval keeps its width, both ends on one Clapeyron
// slope.
double LASubstances::liquidus_c_at(const String &p_id, double p_p_pa, double p_molality_mol_kg) {
	const double solidus = melt_c_at(p_id, p_p_pa, p_molality_mol_kg);
	return std::isfinite(solidus) ? solidus + LAPhaseEosFn::condensed(p_id).width : kInf;
}

// THE LIQUID-VAPOUR BOUNDARY READ AS A PRESSURE -- boil_c_at() inverted, so one curve answers from
// either end and the plateau's temperature cannot disagree with the latent heat charged to cross it.
double LASubstances::saturation_p_at(const String &p_id, double p_t_c) {
	const Dictionary s = row_of(p_id);
	if (iapws_curves(s)) {
		return la_water::iapws_saturation_p_pa(p_t_c + pc("KELVIN_OFFSET"));
	}
	const double t_ref_c = dget(s, "boil_c", kInf);
	if (!std::isfinite(t_ref_c)) {
		return 0.0;
	}
	const double b = clapeyron_b(p_id);
	if (b <= 0.0) {
		return 0.0;
	}
	const double t_crit = dget(s, "critical_t_c", kInf);
	if (std::isfinite(t_crit) && p_t_c >= t_crit) {
		return dget(s, "critical_p_pa", 0.0);
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p_ref = dget(s, "boil_ref_p_pa", pc("STANDARD_PRESSURE_PA"));
	const double t_k_raw = p_t_c + KELVIN_OFFSET;
	const double t_k = t_k_raw > 1.0 ? t_k_raw : 1.0;
	const double t_ref_k = t_ref_c + KELVIN_OFFSET;
	return p_ref * std::exp(-b * (1.0 / t_k - 1.0 / t_ref_k));
}

// Sublimation pressure at temperature -- the solid-vapour boundary, Clausius-Clapeyron anchored on the
// triple point with the SUBLIMATION enthalpy (fusion + vaporisation, derived, so Hess still closes).
double LASubstances::sublimation_p_at(const String &p_id, double p_t_c) {
	const Dictionary s = row_of(p_id);
	if (iapws_curves(s)) {
		return la_water::iapws_sublimation_p_pa(p_t_c + pc("KELVIN_OFFSET"));
	}
	const double t3 = dget(s, "triple_t_c", kInf);
	const double p3 = dget(s, "triple_p_pa", 0.0);
	if (!std::isfinite(t3) || p3 <= 0.0) {
		return 0.0;
	}
	const double l_sub = latent_sublimation_j_kg(p_id);
	const double r_v = r_specific(p_id);
	if (l_sub <= 0.0 || r_v <= 0.0) {
		return 0.0;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double t3_k = t3 + KELVIN_OFFSET;
	const double t_k_raw = p_t_c + KELVIN_OFFSET;
	const double t_k = t_k_raw > 1.0 ? t_k_raw : 1.0;
	return p3 * std::exp(-(l_sub / r_v) * (1.0 / t_k - 1.0 / t3_k));
}

// THE FROST POINT AT A GIVEN PRESSURE, C -- sublimation_p_at() inverted, so the solid-vapour boundary is
// one curve read from either end.
double LASubstances::sublimation_c_at(const String &p_id, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	if (iapws_curves(s)) {
		return la_water::iapws_sublimation_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	const double t3 = dget(s, "triple_t_c", kInf);
	const double p3 = dget(s, "triple_p_pa", 0.0);
	if (!std::isfinite(t3) || p3 <= 0.0) {
		return kInf;
	}
	const double l_sub = latent_sublimation_j_kg(p_id);
	const double r_v = r_specific(p_id);
	if (l_sub <= 0.0 || r_v <= 0.0) {
		return t3;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p = p_p_pa > 1.0e-12 ? p_p_pa : 1.0e-12;
	const double inv_t = 1.0 / (t3 + KELVIN_OFFSET) - (r_v / l_sub) * std::log(p / p3);
	if (inv_t <= 0.0) {
		return t3;
	}
	return 1.0 / inv_t - KELVIN_OFFSET;
}

// True when this substance has NO liquid phase at this pressure: below the triple-point pressure a solid
// goes straight to vapour.
bool LASubstances::sublimes_at(const String &p_id, double p_p_pa) {
	const double p3 = dget(row_of(p_id), "triple_p_pa", 0.0);
	return p3 > 0.0 && p_p_pa < p3;
}

// Ionisation energy per kg, DERIVED from `formula` and the per-element first ionisation energies.
double LASubstances::ionisation_j_kg(const String &p_id) {
	const Dictionary s = row_of(p_id);
	const Dictionary f = Dictionary(s.get("formula", Dictionary()));
	const double mm = dget(s, "molar_mass", 0.0);
	if (f.is_empty() || mm <= 0.0) {
		return 0.0;
	}
	const Dictionary ev = element_ionisation_ev();
	const double ev_to_j_mol = pc("EV_TO_J_PER_MOL");
	double j_mol = 0.0;
	const Array keys = f.keys();
	for (int i = 0; i < keys.size(); i++) {
		if (!ev.has(keys[i])) {
			return 0.0;
		}
		j_mol += double(f[keys[i]]) * double(ev[keys[i]]) * ev_to_j_mol;
	}
	return j_mol / mm;
}

// Atomisation enthalpy per kg -- the gas -> free atoms rung.
double LASubstances::dissociation_j_kg(const String &p_id) {
	const Dictionary s = row_of(p_id);
	const double j_mol = dget(s, "atomisation_j_mol", 0.0);
	const double mm = dget(s, "molar_mass", 0.0);
	return (j_mol > 0.0 && mm > 0.0) ? j_mol / mm : 0.0;
}

double LASubstances::latent_vaporisation_at(const String &p_id, double p_t_c) {
	const Dictionary s = row_of(p_id);
	const double l_ref = dget(s, "latent_vaporisation_j_kg", 0.0);
	if (l_ref <= 0.0) {
		return 0.0;
	}
	const double t_crit = dget(s, "critical_t_c", kInf);
	if (!std::isfinite(t_crit)) {
		return l_ref;
	}
	if (p_t_c >= t_crit) {
		return 0.0;
	}
	const double t_ref = dget(s, "latent_vaporisation_ref_t_c", 0.0);
	const double span_ref = t_crit - t_ref;
	if (span_ref <= 0.0) {
		return l_ref;
	}
	return l_ref * std::pow((t_crit - p_t_c) / span_ref, pc("WATSON_LATENT_EXPONENT"));
}

Dictionary LASubstances::enthalpy_to_state(const String &p_id, double p_h_j_kg, double p_p_pa,
		double p_molality_mol_kg) {
	const Dictionary s = row_of(p_id);
	const double c_liq = dget(s, "specific_heat", NAN);
	const double c_sol = dget(s, "specific_heat_solid", NAN);
	const double c_gas = dget(s, "specific_heat_gas", NAN);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const LAAnchor &anc = LAPhaseEosFn::anchor(p_id);
	const int anchor = anc.phase;
	const double t_ref = anc.t_c;
	const double t_triple = dget(s, "triple_t_c", NAN);
	// Pressure-dependent, and depressed by dissolved solute. For water the Clapeyron slope is negative.
	const double melt_row = melt_c_at(p_id, p_p_pa, p_molality_mol_kg);
	const bool has_melt = std::isfinite(melt_row);
	// A row with no solid is liquid from absolute zero: its fusion rung stands at 0 K and costs nothing.
	const double melt = has_melt ? melt_row : -KELVIN_OFFSET;
	const double liquidus = has_melt ? liquidus_c_at(p_id, p_p_pa, p_molality_mol_kg) : -KELVIN_OFFSET;
	// THE BOUNDARY AT THIS PRESSURE, not the one-atmosphere reference point. See boil_c_at().
	const double boil = boil_c_at(p_id, p_p_pa);
	const double l_fus = has_melt ? double(s["latent_fusion_j_kg"]) : 0.0;
	// THE LATENT HEAT AT THE BOUNDARY: at high pressure the plateau gets SHORTER, reaching zero at the
	// critical point, which is why a supercritical cell has no plateau at all below.
	const double l_vap = std::isfinite(boil) ? latent_vaporisation_at(p_id, boil) : 0.0;

	Dictionary out;
	if (!has_melt && !std::isfinite(boil)) {
		// A substance this planet never melts. Temperature is sensible heat from the standard state.
		out["t_c"] = t_ref + p_h_j_kg / c_sol;
		out["phase"] = int(SOLID);
		out["melted"] = 0.0;
		out["vaporised"] = 0.0;
		return out;
	}

	// NO LIQUID BELOW THE TRIPLE POINT. The plateau crossed is SUBLIMATION at the frost point, not
	// fusion, and the next ramp is the gas.
	if (sublimes_at(p_id, p_p_pa)) {
		const double t_sub = sublimation_c_at(p_id, p_p_pa);
		const double l_sub = latent_sublimation_j_kg(p_id);
		const double h_sub_start = anchor_sub_start(anchor, t_ref, c_sol, c_liq, c_gas, t_sub, l_sub, t_triple, l_fus);
		if (p_h_j_kg <= h_sub_start) {
			out["t_c"] = t_sub - (h_sub_start - p_h_j_kg) / c_sol;
			out["phase"] = int(SOLID);
			out["melted"] = 0.0;
			out["vaporised"] = 0.0;
			out["sublimating"] = true;
			out["dissociated"] = 0.0;
			out["ionised"] = 0.0;
			return out;
		}
		const double h_sub_end = h_sub_start + l_sub;
		if (p_h_j_kg < h_sub_end) {
			out["t_c"] = t_sub;
			out["phase"] = int(SOLID);
			out["melted"] = 0.0;
			out["vaporised"] = l_sub > 0.0 ? (p_h_j_kg - h_sub_start) / l_sub : 1.0;
			out["sublimating"] = true;
			out["dissociated"] = 0.0;
			out["ionised"] = 0.0;
			return out;
		}
		Dictionary st = gas_state(p_id, p_h_j_kg, p_p_pa, t_sub, h_sub_end, c_gas, 0.0);
		st["sublimating"] = true;
		return st;
	}

	const double h_melt_start = anchor_melt_start(anchor, t_ref, c_sol, c_liq, c_gas, melt, boil, l_fus, l_vap);
	if (p_h_j_kg <= h_melt_start) {
		out["t_c"] = melt - (h_melt_start - p_h_j_kg) / c_sol;
		out["phase"] = int(SOLID);
		out["melted"] = 0.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_melt_end = h_melt_start + l_fus + c_liq * (liquidus - melt);
	if (p_h_j_kg < h_melt_end) {
		// IN THE MUSH: temperature RISES through the melting interval as the crystals go. The quadratic
		// is the lever rule solved for the melt fraction; a zero-width interval pins the temperature.
		const double dh = p_h_j_kg - h_melt_start;
		const double dt = liquidus - melt;
		const double a2 = (c_liq - c_sol) * dt;
		const double a1 = c_sol * dt + l_fus;
		const double phi = dt > 0.0 ? 2.0 * dh / (a1 + std::sqrt(a1 * a1 + 4.0 * a2 * dh)) : dh / l_fus;
		out["t_c"] = melt + phi * dt;
		out["phase"] = int(SOLID);
		out["melted"] = phi;
		out["vaporised"] = 0.0;
		return out;
	}

	if (!std::isfinite(boil)) {
		out["t_c"] = liquidus + (p_h_j_kg - h_melt_end) / c_liq;
		out["phase"] = int(LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_boil_start = h_melt_end + c_liq * (boil - liquidus);
	if (p_h_j_kg <= h_boil_start) {
		out["t_c"] = liquidus + (p_h_j_kg - h_melt_end) / c_liq;
		out["phase"] = int(LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_boil_end = h_boil_start + l_vap;
	if (p_h_j_kg < h_boil_end) {
		out["t_c"] = boil;
		out["phase"] = int(LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = l_vap > 0.0 ? (p_h_j_kg - h_boil_start) / l_vap : 1.0;
		return out;
	}

	return gas_state(p_id, p_h_j_kg, p_p_pa, boil, h_boil_end, c_gas, 1.0);
}

void LASubstances::_bind_methods() {
	ClassDB::bind_static_method("LASubstances", D_METHOD("table"), &table);
	ClassDB::bind_static_method("LASubstances", D_METHOD("fresh_litter_per_carbon", "element"), &fresh_litter_per_carbon);
	ClassDB::bind_static_method("LASubstances",
			D_METHOD("reaction_terms", "rec", "slot_substance", "derived_slots"), &reaction_terms);
	ClassDB::bind_static_method("LASubstances", D_METHOD("organic_energy_j_mol", "element"), &organic_energy_j_mol);
	ClassDB::bind_static_method("LASubstances", D_METHOD("latent_sublimation_j_kg", "id"), &latent_sublimation_j_kg);
	ClassDB::bind_static_method("LASubstances", D_METHOD("has_eos", "id"), &has_eos);
	ClassDB::bind_static_method("LASubstances", D_METHOD("solid_density", "id"), &solid_density);
	ClassDB::bind_static_method("LASubstances", D_METHOD("liquid_density", "id"), &liquid_density);
	ClassDB::bind_static_method("LASubstances", D_METHOD("eos_of", "id"), &eos_of);
	ClassDB::bind_static_method("LASubstances", D_METHOD("density", "id", "t_c", "p_pa"), &density);
	ClassDB::bind_static_method("LASubstances", D_METHOD("full_mol_m3", "id"), &full_mol_m3);
	ClassDB::bind_static_method("LASubstances",
			D_METHOD("enthalpy_at", "id", "t_c", "p_pa", "molality_mol_kg"), &enthalpy_at, DEFVAL(0.0));
	ClassDB::bind_static_method("LASubstances",
			D_METHOD("enthalpy_to_state", "id", "h_j_kg", "p_pa", "molality_mol_kg"), &enthalpy_to_state, DEFVAL(0.0));
	ClassDB::bind_static_method("LASubstances", D_METHOD("boil_c_at", "id", "p_pa"), &boil_c_at);
	ClassDB::bind_static_method("LASubstances",
			D_METHOD("melt_c_at", "id", "p_pa", "molality_mol_kg"), &melt_c_at, DEFVAL(0.0));
	ClassDB::bind_static_method("LASubstances",
			D_METHOD("liquidus_c_at", "id", "p_pa", "molality_mol_kg"), &liquidus_c_at, DEFVAL(0.0));
	ClassDB::bind_static_method("LASubstances", D_METHOD("saturation_p_at", "id", "t_c"), &saturation_p_at);
	ClassDB::bind_static_method("LASubstances", D_METHOD("sublimation_p_at", "id", "t_c"), &sublimation_p_at);
	ClassDB::bind_static_method("LASubstances", D_METHOD("sublimation_c_at", "id", "p_pa"), &sublimation_c_at);
	ClassDB::bind_static_method("LASubstances", D_METHOD("sublimes_at", "id", "p_pa"), &sublimes_at);
	ClassDB::bind_static_method("LASubstances", D_METHOD("latent_vaporisation_at", "id", "t_c"), &latent_vaporisation_at);
	ClassDB::bind_static_method("LASubstances", D_METHOD("element_ionisation_ev"), &element_ionisation_ev);
	ClassDB::bind_static_method("LASubstances", D_METHOD("element_degen"), &element_degen);
	ClassDB::bind_static_method("LASubstances", D_METHOD("element_entropy_j_molk"), &element_entropy_j_molk);
	ClassDB::bind_static_method("LASubstances", D_METHOD("dissociated_fraction", "id", "t_k", "p_pa"), &dissociated_fraction);
	ClassDB::bind_static_method("LASubstances", D_METHOD("ionised_fraction", "id", "t_k", "p_pa"), &ionised_fraction);
	ClassDB::bind_static_method("LASubstances", D_METHOD("ionisation_j_kg", "id"), &ionisation_j_kg);
	ClassDB::bind_static_method("LASubstances", D_METHOD("dissociation_j_kg", "id"), &dissociation_j_kg);

	BIND_ENUM_CONSTANT(SOLID);
	BIND_ENUM_CONSTANT(LIQUID);
	BIND_ENUM_CONSTANT(GAS);
	BIND_ENUM_CONSTANT(ATOMS);
	BIND_ENUM_CONSTANT(PLASMA);
	BIND_ENUM_CONSTANT(SUPERCRITICAL);
}
