#include "LAGridGeometry.hpp"
#include <godot_cpp/variant/utility_functions.hpp>
#include "LAPlanetTables.hpp"

#include "LAFieldMirrors.hpp"

#include <godot_cpp/variant/utility_functions.hpp>
#include "LAScriptCall.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include "LAPhysicalRead.hpp"
#include "LATerrainLattice.hpp"
#include "LASubstances.hpp"
#include "LABodySystem.hpp"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

struct Row {
	const char *el;
	double f;
};

Dictionary rows_to_dict(const Row *p_rows, int p_n) {
	Dictionary d;
	for (int i = 0; i < p_n; i++) {
		d[String(p_rows[i].el)] = p_rows[i].f;
	}
	return d;
}

// Bulk Earth (McDonough 2003, Table 3).
const Row BULK_EARTH[] = {
	{ "Fe", 0.320 }, { "O", 0.297 }, { "Si", 0.161 }, { "Mg", 0.154 }, { "Ni", 0.0182 },
	{ "Ca", 0.0171 }, { "Al", 0.0159 }, { "S", 6.35e-3 }, { "Cr", 4.70e-3 }, { "Na", 1.80e-3 },
	{ "Co", 880e-6 }, { "Ti", 810e-6 }, { "Mn", 800e-6 }, { "P", 715e-6 }, { "C", 730e-6 },
	{ "H", 260e-6 }, { "K", 160e-6 }, { "V", 105e-6 }, { "Cl", 76e-6 }, { "N", 25e-6 },
	{ "Sc", 10.9e-6 }, { "F", 10e-6 }, { "Cu", 60e-6 }, { "Zn", 40e-6 }, { "Ge", 7e-6 },
	{ "Mo", 1.7e-6 }, { "Li", 1.1e-6 }, { "Sn", 0.25e-6 }, { "W", 0.17e-6 }, { "Au", 0.16e-6 },
	{ "Pb", 0.23e-6 }, { "Ag", 50e-9 }, { "Sb", 0.05e-6 }, { "Te", 0.3e-6 }, { "Pt", 1.9e-6 },
	{ "Os", 0.9e-6 }, { "Ir", 0.9e-6 }, { "Ru", 1.3e-6 }, { "Rh", 0.24e-6 }, { "Pd", 1.0e-6 },
	{ "Re", 0.075e-6 }, { "U", 15e-9 }, { "Th", 55e-9 },
	{ "La", 0.44e-6 }, { "Ce", 1.13e-6 }, { "Pr", 0.17e-6 }, { "Nd", 0.84e-6 }, { "Sm", 0.27e-6 },
	{ "Eu", 0.10e-6 }, { "Gd", 0.37e-6 }, { "Tb", 0.067e-6 }, { "Dy", 0.46e-6 }, { "Ho", 0.10e-6 },
	{ "Er", 0.30e-6 }, { "Tm", 0.046e-6 }, { "Yb", 0.30e-6 }, { "Lu", 0.046e-6 },
};

// Silicate Earth / pyrolite (McDonough & Sun 1995, Table 5; F per McDonough 2003, Table 2).
const Row SILICATE_EARTH[] = {
	{ "O", 0.44 }, { "Mg", 0.228 }, { "Si", 0.210 }, { "Fe", 0.0626 }, { "Ca", 0.0253 },
	{ "Al", 0.0235 }, { "Na", 2.67e-3 }, { "Cr", 2.625e-3 }, { "Ni", 1.96e-3 }, { "Mn", 1.045e-3 },
	{ "Ti", 1.205e-3 }, { "K", 240e-6 }, { "S", 250e-6 }, { "P", 90e-6 }, { "C", 120e-6 },
	{ "H", 100e-6 }, { "Co", 105e-6 }, { "V", 82e-6 }, { "Cl", 17e-6 }, { "F", 15e-6 },
	{ "Sc", 16.2e-6 }, { "N", 2e-6 }, { "Cu", 30e-6 }, { "Zn", 55e-6 }, { "Ge", 1.1e-6 },
	{ "Li", 1.6e-6 }, { "Mo", 50e-9 }, { "Ag", 8e-9 }, { "Sn", 130e-9 }, { "Sb", 5.5e-9 },
	{ "Te", 12e-9 }, { "W", 29e-9 }, { "Au", 1.0e-9 }, { "Pb", 150e-9 }, { "Pt", 7.1e-9 },
	{ "Os", 3.4e-9 }, { "Ir", 3.2e-9 }, { "Ru", 5.0e-9 }, { "Rh", 0.9e-9 }, { "Pd", 3.9e-9 },
	{ "Re", 0.28e-9 }, { "U", 20.3e-9 }, { "Th", 79.5e-9 },
	{ "La", 0.648e-6 }, { "Ce", 1.675e-6 }, { "Pr", 0.254e-6 }, { "Nd", 1.250e-6 },
	{ "Sm", 0.406e-6 }, { "Eu", 0.154e-6 }, { "Gd", 0.544e-6 }, { "Tb", 0.099e-6 },
	{ "Dy", 0.674e-6 }, { "Ho", 0.149e-6 }, { "Er", 0.438e-6 }, { "Tm", 0.068e-6 },
	{ "Yb", 0.441e-6 }, { "Lu", 0.0675e-6 },
};

// Core (McDonough 2003, Table 4). Devoid of U, Th and K.
const Row CORE[] = {
	{ "Fe", 0.855 }, { "Ni", 0.052 }, { "Si", 0.060 }, { "S", 0.019 }, { "Cr", 9.0e-3 },
	{ "Co", 2.5e-3 }, { "P", 2.0e-3 }, { "C", 2.0e-3 }, { "H", 600e-6 }, { "Mn", 300e-6 },
	{ "Cl", 200e-6 }, { "V", 150e-6 }, { "Cu", 125e-6 }, { "N", 75e-6 }, { "Ge", 20e-6 },
	{ "Mo", 5e-6 }, { "Ru", 4e-6 }, { "Pd", 3.1e-6 }, { "Os", 2.8e-6 }, { "Ir", 2.6e-6 },
	{ "Pt", 5.7e-6 }, { "Rh", 0.74e-6 }, { "Te", 0.85e-6 }, { "Sn", 0.5e-6 }, { "Au", 0.5e-6 },
	{ "W", 0.47e-6 }, { "Pb", 0.4e-6 }, { "Re", 0.23e-6 }, { "Ag", 0.15e-6 }, { "Sb", 0.13e-6 },
};

// Element symbol -> the LAPhysical molar-mass constant, for the formula elements.
const char *ATOMIC_MASS_CONST[][2] = {
	{ "H", "MOLAR_MASS_HYDROGEN_KG_MOL" }, { "C", "MOLAR_MASS_CARBON_KG_MOL" },
	{ "N", "MOLAR_MASS_NITROGEN_KG_MOL" }, { "O", "MOLAR_MASS_OXYGEN_KG_MOL" },
	{ "F", "MOLAR_MASS_F_KG_MOL" }, { "Na", "MOLAR_MASS_NA_KG_MOL" },
	{ "Mg", "MOLAR_MASS_MG_KG_MOL" }, { "Al", "MOLAR_MASS_AL_KG_MOL" },
	{ "Si", "MOLAR_MASS_SI_KG_MOL" }, { "P", "MOLAR_MASS_P_KG_MOL" },
	{ "S", "MOLAR_MASS_S_KG_MOL" }, { "Cl", "MOLAR_MASS_CL_KG_MOL" },
	{ "K", "MOLAR_MASS_K_KG_MOL" }, { "Ca", "MOLAR_MASS_CA_KG_MOL" },
	{ "Fe", "MOLAR_MASS_FE_KG_MOL" }, { "Ni", "MOLAR_MASS_NI_KG_MOL" },
};

Dictionary traces_of(const Dictionary &p_reservoir, const PackedStringArray &p_formula_elements) {
	Dictionary out;
	const Array keys = p_reservoir.keys();
	for (int i = 0; i < keys.size(); i++) {
		const String el = keys[i];
		if (!p_formula_elements.has(el)) {
			out[el] = p_reservoir[el];
		}
	}
	return out;
}

double substance_density(const String &p_id, double p_t_c, double p_p_pa) {
	return LASubstances::density(p_id, p_t_c, p_p_pa);
}

double substance_molar_mass(const String &p_id) {
	return double(Dictionary(LASubstances::table()[p_id])["molar_mass"]);
}

// Moles of one element per kg of silicate shell.
double smol(const char *p_el) {
	return double(LAElementAbundances::silicate_earth().get(String(p_el), 0.0)) /
			LAElementAbundances::atomic_mass(String(p_el));
}

} // namespace

double LAElementAbundances::core_mass_fraction() {
	return la_physical("EARTH_CORE_MASS_FRACTION");
}

Dictionary LAElementAbundances::bulk_earth() {
	static Dictionary d = rows_to_dict(BULK_EARTH, sizeof(BULK_EARTH) / sizeof(Row));
	return d;
}

Dictionary LAElementAbundances::silicate_earth() {
	static Dictionary d = rows_to_dict(SILICATE_EARTH, sizeof(SILICATE_EARTH) / sizeof(Row));
	return d;
}

Dictionary LAElementAbundances::core() {
	static Dictionary d = rows_to_dict(CORE, sizeof(CORE) / sizeof(Row));
	return d;
}

PackedStringArray LAElementAbundances::shell_formula_elements() {
	PackedStringArray out;
	const char *els[] = { "O", "Mg", "Si", "Fe", "Ca", "Al", "Na", "P", "Cl", "F" };
	for (const char *el : els) {
		out.push_back(String(el));
	}
	return out;
}

PackedStringArray LAElementAbundances::core_formula_elements() {
	PackedStringArray out;
	const char *els[] = { "Fe", "Ni", "S", "Si" };
	for (const char *el : els) {
		out.push_back(String(el));
	}
	return out;
}

double LAElementAbundances::atomic_mass(const String &p_el) {
	for (auto &row : ATOMIC_MASS_CONST) {
		if (p_el == String(row[0])) {
			return la_physical(row[1]);
		}
	}
	ERR_FAIL_V_MSG(0.0, "LAElementAbundances.atomic_mass(\"" + p_el + "\"): no atomic mass declared.");
}

double LAElementAbundances::molar_mass(const Dictionary &p_formula) {
	double m = 0.0;
	const Array keys = p_formula.keys();
	for (int i = 0; i < keys.size(); i++) {
		m += double(p_formula[keys[i]]) * atomic_mass(String(keys[i]));
	}
	return m;
}

Dictionary LAElementAbundances::mass_fractions(const Dictionary &p_formula) {
	Dictionary out;
	const double m = molar_mass(p_formula);
	if (m <= 0.0) {
		return out;
	}
	const Array keys = p_formula.keys();
	for (int i = 0; i < keys.size(); i++) {
		out[keys[i]] = double(p_formula[keys[i]]) * atomic_mass(String(keys[i])) / m;
	}
	return out;
}

Dictionary LAElementAbundances::shell_traces() {
	return traces_of(silicate_earth(), shell_formula_elements());
}

Dictionary LAElementAbundances::core_traces() {
	return traces_of(core(), core_formula_elements());
}

void LAElementAbundances::_bind_methods() {
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("core_mass_fraction"), &core_mass_fraction);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("bulk_earth"), &bulk_earth);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("silicate_earth"), &silicate_earth);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("core"), &core);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("shell_formula_elements"), &shell_formula_elements);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("core_formula_elements"), &core_formula_elements);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("atomic_mass", "el"), &atomic_mass);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("molar_mass", "formula"), &molar_mass);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("mass_fractions", "formula"), &mass_fractions);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("shell_traces"), &shell_traces);
	ClassDB::bind_static_method("LAElementAbundances", D_METHOD("core_traces"), &core_traces);
}

// --- LAPlanetComposition ----------------------------------------------------------------------------

PackedStringArray LAPlanetComposition::shell_channels() {
	PackedStringArray out;
	const char *ch[] = { "olivine", "pyroxene", "plagioclase", "silicate", "apatite", "halite" };
	for (const char *c : ch) {
		out.push_back(String(c));
	}
	return out;
}

double LAPlanetComposition::mg_number() {
	const double mg = smol("Mg");
	return mg / (mg + smol("Fe"));
}

// Na fixes albite, the remaining Al fixes anorthite; Cl is halite's sodium first.
double LAPlanetComposition::an_fraction() {
	const double n_ab = smol("Na") - smol("Cl");
	const double n_an = (smol("Al") - n_ab) / 2.0;
	return n_an / (n_an + n_ab);
}

double LAPlanetComposition::apatite_f_fraction() {
	const double f = smol("F") / (smol("P") / 3.0);
	return CLAMP(f, 0.0, 1.0);
}

Dictionary LAPlanetComposition::olivine_formula() {
	const double m = mg_number();
	Dictionary d;
	d["Mg"] = 2.0 * m;
	d["Fe"] = 2.0 * (1.0 - m);
	d["Si"] = 1.0;
	d["O"] = 4.0;
	return d;
}

Dictionary LAPlanetComposition::pyroxene_formula() {
	const double m = mg_number();
	Dictionary d;
	d["Mg"] = m;
	d["Fe"] = 1.0 - m;
	d["Si"] = 1.0;
	d["O"] = 3.0;
	return d;
}

Dictionary LAPlanetComposition::plagioclase_formula() {
	const double x = an_fraction();
	Dictionary d;
	d["Na"] = 1.0 - x;
	d["Ca"] = x;
	d["Al"] = 1.0 + x;
	d["Si"] = 3.0 - x;
	d["O"] = 8.0;
	return d;
}

Dictionary LAPlanetComposition::apatite_formula() {
	const double y = apatite_f_fraction();
	Dictionary d;
	d["Ca"] = 5.0;
	d["P"] = 3.0;
	d["O"] = 12.0 + (1.0 - y);
	d["F"] = y;
	d["H"] = 1.0 - y;
	return d;
}

// Metal alloy: mole ratios per mole Fe, from the core model's major-element mass fractions.
Dictionary LAPlanetComposition::metal_formula() {
	const Dictionary c = LAElementAbundances::core();
	const double n_fe = double(c["Fe"]) / LAElementAbundances::atomic_mass("Fe");
	Dictionary d;
	d["Fe"] = 1.0;
	d["Ni"] = (double(c["Ni"]) / LAElementAbundances::atomic_mass("Ni")) / n_fe;
	d["S"] = (double(c["S"]) / LAElementAbundances::atomic_mass("S")) / n_fe;
	d["Si"] = (double(c["Si"]) / LAElementAbundances::atomic_mass("Si")) / n_fe;
	return d;
}

// kg of each shell mineral per kg of silicate shell: a mole balance against the registry. A negative
// mole count means the mineral basis cannot carry the registry, and is an error.
Dictionary LAPlanetComposition::shell_minerals() {
	static Dictionary cache;
	if (!cache.is_empty()) {
		return cache;
	}
	const double n_hal = smol("Cl");
	const double n_ap = smol("P") / 3.0;
	const double n_ab = smol("Na") - n_hal;
	const double n_an = (smol("Al") - n_ab) / 2.0;
	const double n_plag = n_ab + n_an;
	const double n_wo = smol("Ca") - n_an - 5.0 * n_ap;
	const double x = an_fraction();
	const double si_rem = smol("Si") - (3.0 - x) * n_plag - n_wo;
	const double m_rem = smol("Mg") + smol("Fe");
	const double n_ol = m_rem - si_rem;
	const double n_px = 2.0 * si_rem - m_rem;
	Dictionary moles;
	moles["olivine"] = n_ol;
	moles["pyroxene"] = n_px;
	moles["plagioclase"] = n_plag;
	moles["silicate"] = n_wo;
	moles["apatite"] = n_ap;
	moles["halite"] = n_hal;
	Dictionary forms;
	forms["olivine"] = olivine_formula();
	forms["pyroxene"] = pyroxene_formula();
	forms["plagioclase"] = plagioclase_formula();
	Dictionary wo;
	wo["Ca"] = 1.0;
	wo["Si"] = 1.0;
	wo["O"] = 3.0;
	forms["silicate"] = wo;
	forms["apatite"] = apatite_formula();
	Dictionary hal;
	hal["Na"] = 1.0;
	hal["Cl"] = 1.0;
	forms["halite"] = hal;
	Dictionary out;
	const PackedStringArray ch = shell_channels();
	for (int i = 0; i < ch.size(); i++) {
		const double n = double(moles[ch[i]]);
		ERR_FAIL_COND_V_MSG(n < 0.0, Dictionary(),
				"LAPlanetComposition: the normative solve gives " + ch[i] + " a negative mole count.");
		out[ch[i]] = n * LAElementAbundances::molar_mass(Dictionary(forms[ch[i]]));
	}
	cache = out;
	return cache;
}

// Reference density of the shell mineral mix at the seed state, kg/m^3: volumes add.
double LAPlanetComposition::shell_density(double p_t_c, double p_p_pa) {
	const Dictionary w = shell_minerals();
	double v = 0.0;
	double mass = 0.0;
	const Array keys = w.keys();
	for (int i = 0; i < keys.size(); i++) {
		const double rho = substance_density(String(keys[i]), p_t_c, p_p_pa);
		if (rho <= 0.0) {
			return 0.0;
		}
		mass += double(w[keys[i]]);
		v += double(w[keys[i]]) / rho;
	}
	return v > 0.0 ? mass / v : 0.0;
}

// Radius at which the metal sphere holds the core's declared share of the planet's mass.
double LAPlanetComposition::core_radius_frac(double p_t_c, double p_p_pa) {
	const double f = LAElementAbundances::core_mass_fraction();
	const double rho_m = substance_density("metal", p_t_c, p_p_pa);
	const double rho_s = shell_density(p_t_c, p_p_pa);
	if (rho_m <= 0.0 || rho_s <= 0.0) {
		return 0.0;
	}
	return std::pow(f * rho_s / (rho_m * (1.0 - f) + f * rho_s), 1.0 / 3.0);
}

// ONE TRIAL RADIUS: relax the radial structure and report the mass it holds. Density depends on pressure,
// pressure on the mass above, mass on density, so the three are iterated until they stop moving. The core
// is wherever the inner `f_core` of the mass ends up, not a radius anybody declared.
constexpr double kPi = 3.14159265358979323846;

// The relaxed radial structure of a body of radius R: pressure per shell and the core's shell count.
struct RadialProfile {
	int n = 0;
	int i_core = 0;
	double dr = 0.0;
	std::vector<double> p_at;
	std::vector<double> t_at;
	std::vector<double> m_in;
	double mass = 0.0;
};

// THE BODY STANDS AT ITS OWN GEOTHERM: each shell's density is the composition's at that shell's own
// temperature and pressure, so the radius that holds the declared mass is the hot body's.
// THE GEOTHERM ON THE PROFILE'S OWN GRID, kelvin per shell: the conductive lithosphere down to the mantle
// adiabat, the core-mantle jump, then the core's adiabat. Each adiabat integrates dT/dr = -alpha g T / cp
// with alpha falling under pressure as alpha * K_T stays constant (Anderson 1995, Equations of State of
// Solids for Geophysics), K_T = K0 + K0' P off the same Birch-Murnaghan the densities use.
static void geotherm_on_profile(double p_radius_m, double p_t_c, int p_n, int p_i_core, double p_dr,
		const std::vector<double> &p_m_in, const std::vector<double> &p_p_at, std::vector<double> &r_t_at) {
	const Dictionary table = LASubstances::table();
	const Dictionary rock = table.get("silicate", Dictionary());
	const Dictionary metal = table.get("metal", Dictionary());
	const double rho_m = double(rock.get("density", 0.0));
	const double cp_m = double(rock.get("specific_heat", 0.0));
	const double cp_c = double(metal.get("specific_heat", 0.0));
	const double k_m = double(rock.get("conductivity", 0.0));
	const double alpha_m0 = double(rock.get("expansion_per_k", 0.0));
	const double alpha_c0 = double(metal.get("expansion_per_k", 0.0));
	const double k0_m = double(rock.get("bulk_modulus_pa", rock.get("bulk_modulus_solid_pa", 0.0)));
	const double k0_c = double(metal.get("bulk_modulus_pa", metal.get("bulk_modulus_solid_pa", 0.0)));
	const double kp_m = double(rock.get("bulk_modulus_deriv", 4.0));
	const double kp_c = double(metal.get("bulk_modulus_deriv", 4.0));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double a_w_m3 = LARadiogenicDecay::heat_w_kg_of(rock.get("traces", Dictionary()),
			-la_physical("PLANET_EPOCH_YEARS_BEFORE_PRESENT")) * rho_m;
	const double g_const = la_physical("GRAVITATIONAL_CONSTANT");
	const double t_surface_k = p_t_c + la_physical("KELVIN_OFFSET");
	const double q_surf = la_physical("SURFACE_HEAT_FLOW_W_M2");
	auto alpha_at = [&](double a0, double k0, double kp, double p) {
		const double k_t = k0 + kp * std::max(p - p_std, 0.0);
		return (k0 > 0.0 && k_t > 0.0) ? a0 * k0 / k_t : a0;
	};
	double t_ad = la_physical("MANTLE_POTENTIAL_TEMP_K");
	// THE LID ENDS WHERE ITS CONDUCTIVE GEOTHERM MEETS THE ADIABAT, and below that the adiabat holds:
	// the conductive parabola is the lithosphere's alone and turns over past it.
	bool lid = true;
	for (int i = p_n - 1; i >= p_i_core; --i) {
		const double r = (double(i) + 0.5) * p_dr;
		const double z = p_radius_m - r;
		const double t_cond = (k_m > 0.0) ? t_surface_k + q_surf * z / k_m - a_w_m3 * z * z / (2.0 * k_m) : t_surface_k;
		lid = lid && t_cond < t_ad;
		r_t_at[i] = lid ? t_cond : t_ad;
		const double g = g_const * p_m_in[i] / std::max(r * r, 1.0);
		t_ad *= 1.0 + alpha_at(alpha_m0, k0_m, kp_m, p_p_at[i]) * g * p_dr / std::max(cp_m, 1.0);
	}
	double t_core = la_physical("CORE_MANTLE_BOUNDARY_TEMP_K");
	for (int i = p_i_core - 1; i >= 0; --i) {
		const double r = (double(i) + 0.5) * p_dr;
		r_t_at[i] = t_core;
		const double g = g_const * p_m_in[i] / std::max(r * r, 1.0);
		t_core *= 1.0 + alpha_at(alpha_c0, k0_c, kp_c, p_p_at[i]) * g * p_dr / std::max(cp_c, 1.0);
	}
}

// ONE SHOT FROM THE CENTRE: for a central pressure, integrate dp/dr = -rho g and dm/dr = 4 pi r^2 rho
// outward until the pressure reaches one atmosphere, reading each shell's density at its own pressure
// and at the temperature the previous shot's geotherm gives its radius. Mass and radius both rise with
// the central pressure, so either is found by bisection on it. The metal core is the composition's mass
// fraction, laid first; the shells above it are the silicate mixture.
static RadialProfile shoot_profile(double p_centre_pa, double p_t_c, const RadialProfile &p_last) {
	RadialProfile out;
	const int N_MAX = 4096;
	const double g_const = la_physical("GRAVITATIONAL_CONSTANT");
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double f_core = LAElementAbundances::core_mass_fraction();
	// The target mass sets where the core ends; an unsolved profile takes the declared body's.
	const double m_target = p_last.mass > 0.0 ? p_last.mass
			: double(LABodySeeds::of("planet").get("mass_kg", 0.0));
	// The step: a 192nd of the radius that mass would have uncompressed at the surface's state.
	const double rho_un = LAPlanetComposition::shell_density(p_t_c, p_std);
	if (!(m_target > 0.0) || !(rho_un > 0.0)) {
		return out;
	}
	const double dr = std::pow(3.0 * m_target / (4.0 * kPi * rho_un), 1.0 / 3.0) / 192.0;
	std::vector<double> rho, m_in, p_at, t_at;
	double p = p_centre_pa;
	double m = 0.0;
	int i_core = -1;
	for (int i = 0; i < N_MAX && p > p_std; ++i) {
		const double r_lo = double(i) * dr;
		const double r_mid = r_lo + 0.5 * dr;
		const double r_hi = r_lo + dr;
		// The temperature this shell had on the last shot, at this radius; the surface's before any.
		double t_c = p_t_c;
		if (p_last.n > 0) {
			const int j = std::min(p_last.n - 1, int(r_mid / p_last.dr));
			t_c = p_last.t_at[j];
		}
		const bool core = i_core < 0 && (m < f_core * m_target);
		const double d = core ? LASubstances::density("metal", t_c, p) : LAPlanetComposition::shell_density(t_c, p);
		if (!(std::isfinite(d) && d > 0.0)) {
			out.n = -1;
			return out;
		}
		if (!core && i_core < 0) {
			i_core = i;
		}
		rho.push_back(d);
		p_at.push_back(p);
		t_at.push_back(t_c);
		m += d * (4.0 / 3.0) * kPi * (r_hi * r_hi * r_hi - r_lo * r_lo * r_lo);
		m_in.push_back(m);
		const double g = g_const * m / (r_hi * r_hi);
		p -= d * g * dr;
	}
	if (rho.empty() || i_core < 0) {
		return out;
	}
	out.n = int(rho.size());
	out.i_core = i_core;
	out.dr = dr;
	out.p_at = p_at;
	out.t_at = t_at;
	out.m_in = m_in;
	out.mass = m;
	return out;
}

// The profile's temperatures replaced by the geotherm solved on its own grid, for the next shot.
static RadialProfile with_geotherm(RadialProfile p_prof, double p_t_c) {
	if (p_prof.n <= 0) {
		return p_prof;
	}
	const double kelvin = la_physical("KELVIN_OFFSET");
	const double r_body = double(p_prof.n) * p_prof.dr;
	std::vector<double> t_k(p_prof.n, p_t_c + kelvin);
	geotherm_on_profile(r_body, p_t_c, p_prof.n, p_prof.i_core, p_prof.dr, p_prof.m_in, p_prof.p_at, t_k);
	for (int i = 0; i < p_prof.n; ++i) {
		p_prof.t_at[i] = t_k[i] - kelvin;
	}
	return p_prof;
}

// The profile whose surface stands at `p_radius_m`: bisection on the central pressure, the geotherm
// re-solved on each converged shot until the radius holds.
static RadialProfile radial_profile(double p_radius_m, double p_t_c) {
	RadialProfile last;
	if (!(p_radius_m > 0.0)) {
		return last;
	}
	for (int outer = 0; outer < 6; ++outer) {
		double lo = la_physical("STANDARD_PRESSURE_PA") * 10.0;
		double hi = 1.0e13;
		RadialProfile best;
		for (int i = 0; i < 60; ++i) {
			const double mid = std::sqrt(lo * hi);
			const RadialProfile prof = shoot_profile(mid, p_t_c, last);
			const double r = prof.n > 0 ? double(prof.n) * prof.dr : 0.0;
			if (prof.n == 0 || (prof.n > 0 && r < p_radius_m)) {
				lo = mid;
			} else if (prof.n < 0) {
				hi = mid;
			} else {
				hi = mid;
				best = prof;
			}
		}
		if (best.n <= 0) {
			return best;
		}
		last = with_geotherm(best, p_t_c);
	}
	return last;
}

PackedFloat32Array LAPlanetComposition::geotherm_k(double p_radius_m, double p_t_c) {
	const RadialProfile prof = radial_profile(p_radius_m, p_t_c);
	PackedFloat32Array out;
	out.resize(prof.n);
	const double kelvin = la_physical("KELVIN_OFFSET");
	for (int i = 0; i < prof.n; i++) {
		out[i] = float(prof.t_at[i] + kelvin);
	}
	return out;
}

// THE BODY'S OWN FIELD at every cell of a grid, from the relaxed radial profile: g = G m(<r)/r^2 and
// its potential, zero at infinity, integrated inward from the surface. "g" is cell*3 float32,
// "phi" double per cell, "ref" its float32 copy and "dev" the zero deviation.
Dictionary LAPlanetComposition::body_field(Object *p_grid, const Vector3 &p_centre, double p_radius_m, double p_t_c) {
	Dictionary out;
	const RadialProfile prof = radial_profile(p_radius_m, p_t_c);
	if (!p_grid || prof.n <= 0) {
		return out;
	}
	const double g_si = la_physical("GRAVITATIONAL_CONSTANT");
	const int N = prof.n;
	const double dr = prof.dr;
	// Potential at every shell boundary r_k = k dr, inward from -GM/R.
	std::vector<double> phi_k(N + 1, 0.0);
	phi_k[N] = -g_si * prof.mass / p_radius_m;
	for (int k = N - 1; k >= 0; k--) {
		const double r_mid = (double(k) + 0.5) * dr;
		const double m_mid = k > 0 ? 0.5 * (prof.m_in[k - 1] + prof.m_in[k]) : 0.5 * prof.m_in[0];
		phi_k[k] = phi_k[k + 1] - g_si * m_mid / (r_mid * r_mid) * dr;
	}
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(p_grid);
	const int cc = cw.size() / 3;
	const double phi_datum = -g_si * prof.mass / p_radius_m;
	PackedFloat32Array g, ref, dev;
	PackedFloat64Array phi;
	g.resize(cc * 3);
	phi.resize(cc);
	ref.resize(cc);
	dev.resize(cc);
	dev.fill(0.0f);
	float *gw = g.ptrw();
	float *rw = ref.ptrw();
	double *pw = phi.ptrw();
	for (int c = 0; c < cc; c++) {
		const double dx = cw[c * 3] - double(p_centre.x), dy = cw[c * 3 + 1] - double(p_centre.y), dz = cw[c * 3 + 2] - double(p_centre.z);
		const double r = std::sqrt(dx * dx + dy * dy + dz * dz);
		double m = prof.mass, ph = 0.0;
		if (r >= p_radius_m) {
			ph = -g_si * prof.mass / r;
		} else {
			const double x = r / dr;
			const int k = std::min(int(x), N - 1);
			const double f = x - double(k);
			const double m_lo = k > 0 ? prof.m_in[k - 1] : 0.0;
			m = m_lo + (prof.m_in[k] - m_lo) * f;
			ph = phi_k[k] + (phi_k[k + 1] - phi_k[k]) * f;
		}
		const double mag = r > 0.0 ? g_si * m / (r * r) : 0.0;
		gw[c * 3] = float(r > 0.0 ? -mag * dx / r : 0.0);
		gw[c * 3 + 1] = float(r > 0.0 ? -mag * dy / r : 0.0);
		gw[c * 3 + 2] = float(r > 0.0 ? -mag * dz / r : 0.0);
		pw[c] = ph;
		rw[c] = float(ph - phi_datum);
	}
	out["g"] = g;
	out["phi"] = phi;
	out["ref"] = ref;
	out["phi_datum"] = phi_datum;
	out["dev"] = dev;
	return out;
}

// The body's field onto a slab's device buffers: "gravity", "grav_ref" (against the datum) and a zero
// "grav_phi". Returns body_field's dictionary.
Dictionary LAPlanetComposition::upload_body_field(RenderingDevice *p_rd, const Dictionary &p_bufs, Object *p_grid,
		const Vector3 &p_centre, double p_radius_m, double p_t_c) {
	Dictionary bf = body_field(p_grid, p_centre, p_radius_m, p_t_c);
	if (!p_rd || bf.is_empty() || !p_bufs.has("gravity") || !p_bufs.has("grav_ref") || !p_bufs.has("grav_phi")) {
		return Dictionary();
	}
	const char *keys[3] = { "g", "ref", "dev" };
	const char *bufs[3] = { "gravity", "grav_ref", "grav_phi" };
	for (int i = 0; i < 3; i++) {
		const PackedByteArray b = PackedFloat32Array(bf[keys[i]]).to_byte_array();
		p_rd->buffer_update(RID(p_bufs[bufs[i]]), 0, b.size(), b);
	}
	return bf;
}

// The core boundary of the relaxed body of radius R, metres.
double LAPlanetComposition::core_radius_m(double p_radius_m, double p_t_c) {
	const RadialProfile prof = radial_profile(p_radius_m, p_t_c);
	return prof.n > 0 ? double(prof.i_core) * prof.dr : 0.0;
}

// THE RADIUS IS AN OUTPUT. A body is given a mass and a composition; how big it is follows from how far
// that much matter spreads once its own weight has squeezed it. Bisection, because mass rises with radius.
double LAPlanetComposition::radius_for_mass(double p_mass_kg, double p_t_c) {
	if (!(p_mass_kg > 0.0)) {
		return 0.0;
	}
	RadialProfile last;
	last.mass = p_mass_kg;
	double r_out = 0.0;
	for (int outer = 0; outer < 6; ++outer) {
		double lo = la_physical("STANDARD_PRESSURE_PA") * 10.0;
		double hi = 1.0e13;
		RadialProfile best;
		for (int i = 0; i < 60; ++i) {
			const double mid = std::sqrt(lo * hi);
			const RadialProfile prof = shoot_profile(mid, p_t_c, last);
			if (prof.n == 0 || (prof.n > 0 && prof.mass < p_mass_kg)) {
				lo = mid;
			} else if (prof.n < 0) {
				hi = mid;
			} else {
				hi = mid;
				best = prof;
			}
		}
		if (best.n <= 0) {
			return 0.0;
		}
		r_out = double(best.n) * best.dr;
		last = with_geotherm(best, p_t_c);
		last.mass = p_mass_kg;
	}
	return r_out;
}

// Fill the field's mineral mirrors: a differentiated body — metal core, one silicate shell of the
// registry's own mineral mix. Differentiation at ~10^13 steps is not computable, so the layering is
// seeded; the maintainer's decision, not a law.
void LAPlanetComposition::seed(Object *p_field, double p_t_c, const PackedFloat32Array &p_t_rock) {
	ERR_FAIL_NULL(p_field);
	const Dictionary w = shell_minerals();
	Object *grid = p_field->get("_grid");
	if (w.is_empty() || grid == nullptr) {
		return;
	}
	const double r_body = LABodySeeds::seed_radius_m(String(p_field->get("_body_key")));
	const RadialProfile prof = radial_profile(r_body, p_t_c);
	ERR_FAIL_COND_MSG(prof.n <= 0, "LAPlanetComposition: the body has no radial profile to seed from.");
	const Array keys = w.keys();
	// Mole density of each mineral per shell, kg/m^3 at that shell's pressure: volumes add.
	std::vector<std::vector<double>> amounts(prof.n, std::vector<double>(keys.size(), 0.0));
	std::vector<double> metal_at(prof.n, 0.0);
	for (int j = 0; j < prof.n; j++) {
		const double t_j = j < int(prof.t_at.size()) ? prof.t_at[j] : p_t_c;
		double v_shell = 0.0;
		for (int i = 0; i < keys.size(); i++) {
			v_shell += double(w[keys[i]]) / substance_density(String(keys[i]), t_j, prof.p_at[j]);
		}
		for (int i = 0; i < keys.size(); i++) {
			const double rho = substance_density(String(keys[i]), t_j, prof.p_at[j]);
			amounts[j][i] = (double(w[keys[i]]) / rho) / v_shell * rho / substance_molar_mass(String(keys[i]));
		}
		metal_at[j] = substance_density("metal", t_j, prof.p_at[j]) / substance_molar_mass("metal");
	}
	Array cargs;
	cargs.push_back(p_field);
	const Vector3 centre = Vector3(la_call_gd(
			"res://addons/local_agents/sim/material/FieldGeometry3D.gd", "centre", cargs));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = PackedByteArray(p_field->get("_solid"));
	PackedFloat32Array cement = LAFieldMirrors::of(p_field, "cement");
	PackedFloat32Array metal = LAFieldMirrors::of(p_field, "metal");
	const PackedStringArray ch = shell_channels();
	std::vector<PackedFloat32Array> shell(ch.size());
	std::vector<int> col(ch.size(), -1);
	for (int i = 0; i < ch.size(); i++) {
		shell[i] = LAFieldMirrors::of(p_field, ch[i]);
		if (shell[i].size() != cc) {
			shell[i].resize(cc);
		}
		col[i] = keys.find(ch[i]);
	}
	const PackedVector3Array la_cw = grid->get("centres");
	const PackedFloat32Array frac = PackedFloat32Array(p_field->get("_rock_fraction"));
	const PackedFloat32Array edge = grid->call("cell_edges");
	if (cement.size() != cc) {
		cement.resize(cc);
	}
	if (metal.size() != cc) {
		metal.resize(cc);
	}
	float *cw = cement.ptrw();
	float *mw = metal.ptrw();
	std::vector<float *> sw(ch.size());
	for (int i = 0; i < ch.size(); i++) {
		sw[i] = shell[i].ptrw();
	}
	// A cell holds the rock volume the terrain's signed distance puts in it: whole below the relief,
	// a fraction where the surface crosses it. Seeded rock is consolidated whatever its share. The
	// profile is averaged over SUB^3 points of the cell, so a core boundary or a density gradient inside
	// one cell lands as the volume it occupies.
	const int SUB = 4;
	const double w_sub = 1.0 / double(SUB * SUB * SUB);
	std::vector<double> acc(ch.size(), 0.0);
	// Each sample's amount is at its shell's own T; the cell's rock stands at the cell's own T, so every
	// sample is carried to it over its expansion and the lattice fills exactly the chord's volume there.
	const Dictionary table = LASubstances::table();
	std::vector<double> alpha(ch.size(), 0.0), tref(ch.size(), 0.0), k0(ch.size(), 0.0), kp(ch.size(), 4.0);
	for (int i = 0; i < ch.size(); i++) {
		const Dictionary sub = table.get(ch[i], Dictionary());
		alpha[i] = double(sub.get("expansion_per_k", 0.0));
		tref[i] = double(sub.get("density_ref_t_c", 0.0));
		k0[i] = double(sub.get("bulk_modulus_pa", sub.get("bulk_modulus_solid_pa", 0.0)));
		kp[i] = double(sub.get("bulk_modulus_deriv", 4.0));
	}
	const Dictionary metal_sub = table.get("metal", Dictionary());
	const double alpha_m = double(metal_sub.get("expansion_per_k", 0.0));
	const double tref_m = double(metal_sub.get("density_ref_t_c", 0.0));
	const double k0_m = double(metal_sub.get("bulk_modulus_pa", metal_sub.get("bulk_modulus_solid_pa", 0.0)));
	const double kp_m = double(metal_sub.get("bulk_modulus_deriv", 4.0));
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	// alpha * K_T stays constant under pressure (Anderson 1995): the same law the density carries.
	auto alpha_at = [&](double a0, double k, double kprime, double p) {
		const double dp = p - p_std;
		return (k > 0.0 && dp > 0.0) ? a0 * k / (k + kprime * dp) : a0;
	};
	for (int c = 0; c < cc; c++) {
		const float f = frac.size() == cc ? frac[c] : (solid[c] != 0 ? 1.0f : 0.0f);
		cw[c] = f > 0.0f ? 1.0f : 0.0f;
		if (f <= 0.0f) {
			continue;
		}
		const double e = c < edge.size() ? double(edge[c]) : 0.0;
		const double se = e / double(SUB);
		double m_acc = 0.0;
		std::fill(acc.begin(), acc.end(), 0.0);
		for (int a = 0; a < SUB; a++) {
			for (int b = 0; b < SUB; b++) {
				for (int d = 0; d < SUB; d++) {
					const Vector3 p = la_cw[c] + Vector3(float((a + 0.5) * se - 0.5 * e), float((b + 0.5) * se - 0.5 * e),
							float((d + 0.5) * se - 0.5 * e));
					const int j = std::min(prof.n - 1, int((p - centre).length() / prof.dr));
					const double t_j = j < int(prof.t_at.size()) ? prof.t_at[j] : p_t_c;
					const double p_j = j < int(prof.p_at.size()) ? prof.p_at[j] : p_std;
					if (j < prof.i_core) {
						m_acc += metal_at[j] * (1.0 + alpha_at(alpha_m, k0_m, kp_m, p_j) * (t_j - tref_m));
						continue;
					}
					for (int i = 0; i < ch.size(); i++) {
						acc[i] += col[i] >= 0 ? amounts[j][col[i]] * (1.0 + alpha_at(alpha[i], k0[i], kp[i], p_j) * (t_j - tref[i])) : 0.0;
					}
				}
			}
		}
		const double t_rock = c < p_t_rock.size() ? double(p_t_rock[c]) : p_t_c;
		const int j_c = std::min(prof.n - 1, int((la_cw[c] - centre).length() / prof.dr));
		const double p_c = j_c < int(prof.p_at.size()) ? prof.p_at[j_c] : p_std;
		mw[c] = float(m_acc * w_sub * f / (1.0 + alpha_at(alpha_m, k0_m, kp_m, p_c) * (t_rock - tref_m)));
		for (int i = 0; i < ch.size(); i++) {
			sw[i][c] = float(acc[i] * w_sub * f / (1.0 + alpha_at(alpha[i], k0[i], kp[i], p_c) * (t_rock - tref[i])));
		}
	}
	LAFieldMirrors::store(p_field, "cement", cement);
	LAFieldMirrors::store(p_field, "metal", metal);
	for (int i = 0; i < ch.size(); i++) {
		LAFieldMirrors::store(p_field, ch[i], shell[i]);
	}
}

// THE ROCK FRACTION, one walk: the share of each cell's volume inside the terrain's signed distance.
// THE CUT CELL'S GEOMETRY, BY RADIAL CHORDS. The terrain is a height field over the sphere, so along a
// line through the cell in the local vertical the ground is one crossing and the sea a second: the rock
// is the chord below the ground, the water the chord between the ground and the sea shell, the rest is
// air. SUB^2 such lines cover the cell's projection; every fraction is a ratio of chords, so a cell wholly
// inside rock reads exactly one. "rock" and "water" are each the cell's volume share.
// LA_APPROX: chord_quadrature_lattice
Dictionary LAPlanetComposition::surface_fractions(Object *p_grid, Object *p_terrain, const Vector3 &p_centre,
		double p_sea_r) {
	Dictionary out;
	if (!p_grid || !p_terrain) {
		return out;
	}
	const int cc = int(p_grid->get("cell_count"));
	const PackedVector3Array cw = p_grid->get("centres");
	// The RADIUS in double: float32 spacing at a body's radius is half a metre, a whole fine cell.
	const PackedFloat64Array cwd = LAGridGeometry::centres_f64(p_grid);
	double lo = -1.0, hi = -1.0;
	if (p_terrain->has_method("min_surface_radius") && p_terrain->has_method("max_surface_radius")) {
		lo = double(p_terrain->call("min_surface_radius"));
		hi = double(p_terrain->call("max_surface_radius"));
	}
	const PackedFloat32Array edge = p_grid->call("cell_edges");
	auto radius_of = [&](int c) {
		return std::hypot(cwd[c * 3] - double(p_centre.x), cwd[c * 3 + 1] - double(p_centre.y),
				cwd[c * 3 + 2] - double(p_centre.z));
	};
	PackedFloat32Array rock, water, ground;
	rock.resize(cc);
	water.resize(cc);
	ground.resize(cc);
	float *rw = rock.ptrw();
	float *ww = water.ptrw();
	float *gw = ground.ptrw();
	std::vector<int> ask;
	for (int c = 0; c < cc; c++) {
		const double r = radius_of(c);
		const double pad = c < edge.size() ? 0.5 * std::sqrt(3.0) * double(edge[c]) : 0.0;
		ww[c] = 0.0f;
		// The ground under a cell the relief never reaches: the cell's own bottom along the vertical,
		// so a band of water in it starts at its lowest corner.
		{
			const Vector3 rel = cw[c] - p_centre;
			const Vector3 up = rel.length() > 0.0 ? rel / rel.length() : Vector3(0, 1, 0);
			const double e = c < edge.size() ? double(edge[c]) : 0.0;
			gw[c] = float(0.5 * e * (std::abs(up.x) + std::abs(up.y) + std::abs(up.z)));
		}
		if (lo > 0.0 && hi > 0.0 && r + pad < lo) {
			rw[c] = 1.0f;
		} else if (lo > 0.0 && hi > 0.0 && r - pad > hi && r - pad > p_sea_r) {
			rw[c] = 0.0f;
		} else {
			rw[c] = 0.0f;
			ask.push_back(c);
		}
	}
	if (ask.empty()) {
		out["rock_fraction"] = rock;
		out["water_fraction"] = water;
		out["ground_d"] = ground;
		return out;
	}
	const Vector3 origin = p_grid->get("origin");
	const int span = std::max(int(p_grid->get("nx")), std::max(int(p_grid->get("ny")), int(p_grid->get("nz"))));
	const double base = double(p_grid->get("cell_size"));
	const LATerrainLattice &lat = LATerrainLattice::build(p_terrain, origin, base * span, LATerrainLattice::lod_for(base * span), 32, p_centre, lo, hi);
	if (!lat.valid()) {
		UtilityFunctions::push_error("LAPlanetComposition: the terrain lattice did not build; no rock is seeded in the relief band.");
		return out;
	}
	const int SUB = 6;
	const int BISECT = 20;
	for (int c : ask) {
		const double e = c < edge.size() ? double(edge[c]) : base;
		const double h = 0.5 * e;
		const Vector3 rel = cw[c] - p_centre;
		const double r0 = radius_of(c);
		if (!(rel.length() > 0.0)) {
			continue;
		}
		const Vector3 up = rel / rel.length();
		// A lateral basis across the vertical.
		Vector3 a = std::abs(up.y) < 0.9 ? Vector3(0, 1, 0).cross(up) : Vector3(1, 0, 0).cross(up);
		a = a.normalized();
		const Vector3 b = up.cross(a).normalized();
		const double reach = std::sqrt(3.0) * h;
		double chord = 0.0, chord_rock = 0.0, chord_water = 0.0;
		double ground_sum = 0.0;
		int ground_n = 0;
		for (int i = 0; i < SUB; i++) {
			for (int j = 0; j < SUB; j++) {
				const double s = ((i + 0.5) / double(SUB) * 2.0 - 1.0) * reach;
				const double t = ((j + 0.5) / double(SUB) * 2.0 - 1.0) * reach;
				const Vector3 q = cw[c] + a * float(s) + b * float(t);
				// The line q + x up against the cube: a slab test per axis.
				double x_in = -std::numeric_limits<double>::infinity();
				double x_out = std::numeric_limits<double>::infinity();
				bool miss = false;
				for (int k = 0; k < 3 && !miss; k++) {
					const double d = double(up[k]);
					const double o = double(q[k] - cw[c][k]);
					if (std::abs(d) < 1e-12) {
						if (std::abs(o) > h) {
							miss = true;
						}
						continue;
					}
					double x1 = (-h - o) / d, x2 = (h - o) / d;
					if (x1 > x2) {
						std::swap(x1, x2);
					}
					x_in = std::max(x_in, x1);
					x_out = std::min(x_out, x2);
				}
				if (miss || !(x_out > x_in)) {
					continue;
				}
				chord += x_out - x_in;
				// Where the ground crosses this line: rock below it. The lattice sign at both ends brackets it.
				const bool rock_in = lat.sample(q + up * float(x_in)) < 0.0;
				const bool rock_out = lat.sample(q + up * float(x_out)) < 0.0;
				double x_ground = x_out;
				if (rock_in && rock_out) {
					x_ground = x_out;
				} else if (!rock_in && !rock_out) {
					x_ground = x_in;
				} else {
					double lo_x = x_in, hi_x = x_out;
					for (int it = 0; it < BISECT; it++) {
						const double m = 0.5 * (lo_x + hi_x);
						if (lat.sample(q + up * float(m)) < 0.0) {
							lo_x = m;
						} else {
							hi_x = m;
						}
					}
					x_ground = 0.5 * (lo_x + hi_x);
				}
				chord_rock += x_ground - x_in;
				// The ground's depth below the centre along this line: the rock top, or the cube's bottom.
				ground_sum += -x_ground;
				ground_n += 1;
				// The sea shell along this line: r(x) = |q - centre + x up|.
				const Vector3 qr = q - p_centre;
				const double par = double(qr.dot(up));
				const double perp2 = std::max(double(qr.length_squared()) - par * par, 0.0);
				const double inside = p_sea_r * p_sea_r - perp2;
				if (p_sea_r > 0.0 && inside > 0.0) {
					const double x_sea = std::sqrt(inside) - par;
					const double w_lo = std::max(x_ground, x_in);
					const double w_hi = std::min(x_sea, x_out);
					if (w_hi > w_lo) {
						chord_water += w_hi - w_lo;
					}
				}
			}
		}
		if (chord > 0.0) {
			rw[c] = float(std::min(std::max(chord_rock / chord, 0.0), 1.0));
			ww[c] = float(std::min(std::max(chord_water / chord, 0.0), 1.0));
		}
		if (ground_n > 0) {
			gw[c] = float(ground_sum / double(ground_n));
		}
	}
	out["rock_fraction"] = rock;
	out["water_fraction"] = water;
	out["ground_d"] = ground;
	return out;
}

// SEA LEVEL IS WHERE THE WATER REACHES: the elevation against the hypsographic curve's zero at which
// the curve holds `p_ocean_m3` on a body of radius `p_r_m`, bisected over the curve's own range. The
// curve is piecewise linear in cumulative area, so each segment's wet volume is exact.
double LAPlanetComposition::sea_level_m(double p_r_m, double p_ocean_m3, const PackedFloat64Array &p_area_below,
		const PackedFloat64Array &p_elevation_m) {
	const int n = std::min(p_area_below.size(), p_elevation_m.size());
	if (n < 2 || !(p_r_m > 0.0)) {
		return 0.0;
	}
	auto volume = [&](double e_sea) {
		double acc = 0.0;
		for (int i = 1; i < n; i++) {
			const double d0 = std::max(e_sea - p_elevation_m[i - 1], 0.0);
			const double d1 = std::max(e_sea - p_elevation_m[i], 0.0);
			const double span = p_area_below[i] - p_area_below[i - 1];
			if (d0 > 0.0 && d1 > 0.0) {
				acc += 0.5 * (d0 + d1) * span;
			} else if (d0 > 0.0 || d1 > 0.0) {
				const double rise = std::abs(p_elevation_m[i] - p_elevation_m[i - 1]);
				const double wet = rise > 0.0 ? span * std::max(d0, d1) / rise : 0.0;
				acc += 0.5 * std::max(d0, d1) * wet;
			}
		}
		return 4.0 * kPi * p_r_m * p_r_m * acc;
	};
	double lo = p_elevation_m[0], hi = p_elevation_m[n - 1];
	for (int i = 0; i < 64; i++) {
		const double mid = 0.5 * (lo + hi);
		if (volume(mid) < p_ocean_m3) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

// Directions swept over the body, lands whose shores are examined, halvings onto a waterline, and
// samples per side of a footprint reading.
static const int kSweepSamples = 128;
static const int kSiteCandidates = 16;
static const int kCoastBisect = 24;
static const int kFootprintSamples = 7;
// THE SITE RULE, one declaration: the share of the footprint standing under the waterline that makes it
// a shore rather than a pond or a headland.
static const double kSiteSeaShareMin = 0.25;
static const double kSiteSeaShareMax = 0.75;

// The body's OWN frame: a place on the planet, not a direction the rotating world sweeps past.
static double la_surface_radius(Object *p_surface, const Vector3 &p_dir) {
	return double(p_surface->call("body_surface_radius", p_dir));
}

// A Fibonacci lattice direction: even coverage, no clustering at the poles.
static Vector3 la_sweep_dir(int p_i, int p_n) {
	const double golden = kPi * (3.0 - std::sqrt(5.0));
	const double y = 1.0 - 2.0 * (double(p_i) + 0.5) / double(p_n);
	const double s = std::sqrt(std::max(0.0, 1.0 - y * y));
	return Vector3(std::cos(golden * p_i) * s, y, std::sin(golden * p_i) * s).normalized();
}

Dictionary LAPlanetComposition::footprint_ground(Object *p_surface, const Vector3 &p_dir, double p_body_r_m,
		double p_sea_r_m, double p_footprint_m) {
	Dictionary out;
	if (!p_surface) {
		return out;
	}
	const Vector3 d = p_dir.normalized();
	const double span = p_footprint_m / std::max(p_body_r_m, 1.0);
	const Vector3 ref = std::abs(d.y) < 0.95 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
	const Vector3 u = ref.cross(d).normalized();
	const Vector3 v = d.cross(u);
	double land = -INFINITY, deep = -INFINITY;
	int wet = 0;
	for (int i = 0; i < kFootprintSamples; i++) {
		const double a = span * (double(i) / double(kFootprintSamples - 1) - 0.5);
		for (int j = 0; j < kFootprintSamples; j++) {
			const double b = span * (double(j) / double(kFootprintSamples - 1) - 0.5);
			const double h = la_surface_radius(p_surface, (d + u * a + v * b).normalized()) - p_sea_r_m;
			land = std::max(land, h);
			deep = std::max(deep, -h);
			wet += h <= 0.0 ? 1 : 0;
		}
	}
	out["foot_m"] = p_footprint_m;
	out["land_m"] = land;
	out["depth_m"] = deep;
	out["sea_share"] = double(wet) / double(kFootprintSamples * kFootprintSamples);
	return out;
}

// WHERE TO STAND A BOX SO IT HOLDS A SHORE: of the waterlines between the body's highest lands and its
// deepest water, the one whose footprint straddles the waterline by the site rule and carries the most
// relief across it -- the deepest basin under the highest land, which is what a coast looks like.
// LA_APPROX: site_from_settled_level
Dictionary LAPlanetComposition::coast_site(Object *p_surface, double p_body_r_m, double p_sea_r_m,
		double p_footprint_m) {
	Dictionary out;
	if (!p_surface || !(p_footprint_m > 0.0)) {
		return out;
	}
	std::vector<std::pair<double, Vector3>> high, low;
	for (int i = 0; i < kSweepSamples; i++) {
		const Vector3 d = la_sweep_dir(i, kSweepSamples);
		const double r = la_surface_radius(p_surface, d);
		(r - p_sea_r_m > 0.0 ? high : low).push_back({ r, d });
	}
	if (high.empty() || low.empty()) {
		return out;
	}
	std::sort(high.begin(), high.end(), [](const std::pair<double, Vector3> &x,
					const std::pair<double, Vector3> &y) { return x.first > y.first; });
	double score = -INFINITY;
	for (int k = 0; k < std::min(kSiteCandidates, int(high.size())); k++) {
		Vector3 a = high[k].second;
		// THE STEEPEST SHORE THIS LAND HAS: of the water this height stands over, the one whose drop per
		// radian is greatest -- a deep basin close by, not the deepest one on the body.
		Vector3 b;
		double steep = -INFINITY;
		for (const std::pair<double, Vector3> &w : low) {
			const double ang = std::acos(std::clamp(double(a.dot(w.second)), -1.0, 1.0));
			const double s = ang > 1.0e-6 ? (high[k].first - w.first) / ang : -INFINITY;
			if (s > steep) {
				steep = s;
				b = w.second;
			}
		}
		for (int i = 0; i < kCoastBisect; i++) {
			const Vector3 m = (a + b).normalized();
			if (la_surface_radius(p_surface, m) - p_sea_r_m > 0.0) {
				a = m;
			} else {
				b = m;
			}
		}
		const Vector3 site = (a + b).normalized();
		const Dictionary g = footprint_ground(p_surface, site, p_body_r_m, p_sea_r_m, p_footprint_m);
		const double share = double(g["sea_share"]);
		if (share < kSiteSeaShareMin || share > kSiteSeaShareMax) {
			continue;
		}
		const double s = double(g["land_m"]) + double(g["depth_m"]);
		if (s > score) {
			score = s;
			out = g;
			out["dir"] = site;
		}
	}
	return out;
}

// Saturated pore column standing ABOVE the sea under ground at elevation p_e_m, m of water per m^2, with
// the table p_h_m over the sea: Athy porosity integrated from the table down to sea level.
static double pore_above_sea(double p_e_m, double p_h_m, double p_phi0, double p_zc, double p_aquifer_m) {
	const double z_hi = std::min(std::max(p_e_m, 0.0), p_aquifer_m);
	const double z_wt = std::max(p_e_m - p_h_m, 0.0);
	if (!(z_hi > z_wt)) {
		return 0.0;
	}
	return p_phi0 * p_zc * (std::exp(-z_wt / p_zc) - std::exp(-z_hi / p_zc));
}

double LAPlanetComposition::water_table_m(double p_r_m, double p_groundwater_m3, double p_sea_level_m,
		const PackedFloat64Array &p_area_below, const PackedFloat64Array &p_elevation_m) {
	const int n = std::min(p_area_below.size(), p_elevation_m.size());
	const double phi0 = la_physical("REGOLITH_SURFACE_POROSITY");
	const double zc = la_physical("COMPACTION_LENGTH_M");
	const double aq = la_physical("GROUNDWATER_CIRCULATION_M");
	if (n < 2 || !(p_r_m > 0.0) || !(phi0 > 0.0) || !(zc > 0.0) || !(aq > 0.0)) {
		return 0.0;
	}
	auto volume = [&](double h) {
		double acc = 0.0;
		for (int i = 1; i < n; i++) {
			const double a = pore_above_sea(p_elevation_m[i - 1] - p_sea_level_m, h, phi0, zc, aq);
			const double b = pore_above_sea(p_elevation_m[i] - p_sea_level_m, h, phi0, zc, aq);
			acc += 0.5 * (a + b) * (p_area_below[i] - p_area_below[i - 1]);
		}
		return 4.0 * kPi * p_r_m * p_r_m * acc;
	};
	// The table cannot stand above the highest ground, and there it saturates every pore over the sea.
	double hi = std::max(p_elevation_m[n - 1] - p_sea_level_m, 0.0);
	if (volume(hi) < p_groundwater_m3) {
		UtilityFunctions::push_error("LAPlanetComposition: the body declares more groundwater than the pore "
				"space standing over its sea can hold, so the table would stand above the ground everywhere.");
		return hi;
	}
	double lo = 0.0;
	for (int i = 0; i < 64; i++) {
		const double mid = 0.5 * (lo + hi);
		if (volume(mid) < p_groundwater_m3) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

PackedFloat32Array LAPlanetComposition::surface_depth(Object *p_grid, Object *p_terrain, const Vector3 &p_centre) {
	PackedFloat32Array out;
	if (!p_grid || !p_terrain) {
		return out;
	}
	const int cc = int(p_grid->get("cell_count"));
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(p_grid);
	double lo = -1.0, hi = -1.0;
	if (p_terrain->has_method("min_surface_radius") && p_terrain->has_method("max_surface_radius")) {
		lo = double(p_terrain->call("min_surface_radius"));
		hi = double(p_terrain->call("max_surface_radius"));
	}
	const Vector3 origin = p_grid->get("origin");
	const int span = std::max(int(p_grid->get("nx")), std::max(int(p_grid->get("ny")), int(p_grid->get("nz"))));
	const double base = double(p_grid->get("cell_size"));
	const LATerrainLattice &lat = LATerrainLattice::build(p_terrain, origin, base * span, LATerrainLattice::lod_for(base * span), 32, p_centre, lo, hi);
	if (!lat.valid() || !(lo > 0.0) || !(hi > 0.0)) {
		UtilityFunctions::push_error("LAPlanetComposition: the terrain lattice did not build; no cell has a depth below its ground.");
		return out;
	}
	out.resize(cc);
	float *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		const double rx = cw[c * 3] - double(p_centre.x);
		const double ry = cw[c * 3 + 1] - double(p_centre.y);
		const double rz = cw[c * 3 + 2] - double(p_centre.z);
		const double r = std::hypot(rx, ry, rz);
		if (!(r > 0.0)) {
			w[c] = float(lo);
			continue;
		}
		const Vector3 dir(float(rx / r), float(ry / r), float(rz / r));
		double a = lo, b = hi;
		for (int i = 0; i < 24; i++) {
			const double m = 0.5 * (a + b);
			if (lat.sample(p_centre + dir * float(m)) < 0.0) {
				a = m;   // still rock: the surface is farther out
			} else {
				b = m;
			}
		}
		w[c] = float(0.5 * (a + b) - r);
	}
	return out;
}

// 1 where the rock's share of the cell reaches the lock-up crystal fraction: the same law the derive
// locks a cell on.
PackedByteArray LAPlanetComposition::solid_of(const PackedFloat32Array &p_fraction) {
	PackedByteArray out;
	out.resize(p_fraction.size());
	uint8_t *w = out.ptrw();
	const float lock = float(la_physical("RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC"));
	for (int c = 0; c < p_fraction.size(); c++) {
		w[c] = p_fraction[c] >= lock ? 1 : 0;
	}
	return out;
}

void LAPlanetComposition::_bind_methods() {
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("shell_channels"), &shell_channels);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("surface_fractions", "grid", "terrain", "centre", "sea_r"), &surface_fractions);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("solid_of", "fraction"), &solid_of);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("surface_depth", "grid", "terrain", "centre"), &surface_depth);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("sea_level_m", "r_m", "ocean_m3", "area_below", "elevation_m"), &sea_level_m);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("footprint_ground", "surface", "dir", "body_r_m", "sea_r_m", "footprint_m"), &footprint_ground);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("coast_site", "surface", "body_r_m", "sea_r_m", "footprint_m"), &coast_site);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("water_table_m", "r_m", "groundwater_m3", "sea_level_m", "area_below", "elevation_m"), &water_table_m);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("mg_number"), &mg_number);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("an_fraction"), &an_fraction);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("apatite_f_fraction"), &apatite_f_fraction);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("olivine_formula"), &olivine_formula);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("pyroxene_formula"), &pyroxene_formula);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("plagioclase_formula"), &plagioclase_formula);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("apatite_formula"), &apatite_formula);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("metal_formula"), &metal_formula);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("shell_minerals"), &shell_minerals);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("shell_density", "t_c", "p_pa"), &shell_density);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("core_radius_frac", "t_c", "p_pa"), &core_radius_frac);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("radius_for_mass", "mass_kg", "t_c"), &radius_for_mass);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("core_radius_m", "radius_m", "t_c"), &core_radius_m);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("body_field", "grid", "centre", "radius_m", "t_c"), &body_field);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("upload_body_field", "rd", "bufs", "grid", "centre", "radius_m", "t_c"), &upload_body_field);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("geotherm_k", "radius_m", "t_surface_c"), &geotherm_k);
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("seed", "field", "t_c", "t_rock"), &seed);
}

// --- LARadiogenicDecay ------------------------------------------------------------------------------

namespace {

// Present-epoch watts per kg of rock from one nuclide.
double w_per_kg(double p_kg_per_kg, double p_half_life_years, double p_j_per_decay, double p_molar_mass) {
	if (p_half_life_years <= 0.0 || p_molar_mass <= 0.0) {
		return 0.0;
	}
	const double lambda_per_s = std::log(2.0) / (p_half_life_years * la_physical("SECONDS_PER_YEAR"));
	const double atoms = (p_kg_per_kg / p_molar_mass) * la_physical("AVOGADRO_PER_MOL");
	return lambda_per_s * atoms * p_j_per_decay;
}

Array nuclide_row(double p_frac, const char *p_hl, const char *p_mev, const char *p_mm,
		const Dictionary &p_daughters) {
	Array row;
	row.push_back(p_frac);
	row.push_back(la_physical(p_hl));
	row.push_back(la_physical(p_mev) * la_physical("MEV_J"));
	row.push_back(la_physical(p_mm));
	row.push_back(p_daughters);
	return row;
}

Dictionary two_daughters(const char *p_a, double p_na, const char *p_b, double p_nb) {
	Dictionary d;
	d[String(p_a)] = p_na;
	d[String(p_b)] = p_nb;
	return d;
}

} // namespace

// The abundances every entry in LASubstances is quoted at: today. Years run forward from there, so this
// world's own epoch — the declared 4.4 Ga referent — is NEGATIVE and the store fuller than Earth's now.
double LARadiogenicDecay::epoch_years() {
	const Variant clock = la_call_gd("res://addons/local_agents/sim/SimClock.gd", "active", Array());
	const double anchor = -la_physical("PLANET_EPOCH_YEARS_BEFORE_PRESENT");
	Object *c = clock;
	if (c == nullptr) {
		return anchor;
	}
	return anchor + double(c->call("elapsed")) / la_physical("SECONDS_PER_YEAR");
}

// nuclide -> [kg of nuclide per kg of rock today, half-life years, decay energy J per decay, molar
// mass, atoms of each daughter per decay]. Decay conserves nucleons; K40 splits by measured branching.
Dictionary LARadiogenicDecay::nuclides(const Dictionary &p_traces) {
	const double u = double(p_traces.get("U", 0.0));
	const double th = double(p_traces.get("Th", 0.0));
	const double k = double(p_traces.get("K", 0.0));
	Dictionary out;
	out["U238"] = nuclide_row(u * la_physical("ISOTOPE_FRAC_U238"), "HALF_LIFE_U238_YEARS",
			"DECAY_ENERGY_U238_MEV", "MOLAR_MASS_U238_KG_MOL", two_daughters("Pb", 1.0, "He", 8.0));
	out["U235"] = nuclide_row(u * la_physical("ISOTOPE_FRAC_U235"), "HALF_LIFE_U235_YEARS",
			"DECAY_ENERGY_U235_MEV", "MOLAR_MASS_U235_KG_MOL", two_daughters("Pb", 1.0, "He", 7.0));
	out["TH232"] = nuclide_row(th * la_physical("ISOTOPE_FRAC_TH232"), "HALF_LIFE_TH232_YEARS",
			"DECAY_ENERGY_TH232_MEV", "MOLAR_MASS_TH232_KG_MOL", two_daughters("Pb", 1.0, "He", 6.0));
	out["K40"] = nuclide_row(k * la_physical("ISOTOPE_FRAC_K40"), "HALF_LIFE_K40_YEARS",
			"DECAY_ENERGY_K40_MEV", "MOLAR_MASS_K40_KG_MOL",
			two_daughters("Ca", la_physical("K40_BETA_FRAC"), "Ar", la_physical("K40_EC_FRAC")));
	return out;
}

// Watts per kilogram of a rock carrying `traces`, `years` after the present epoch.
double LARadiogenicDecay::heat_w_kg_of(const Dictionary &p_traces, double p_years) {
	double w = 0.0;
	const Dictionary n = nuclides(p_traces);
	const Array keys = n.keys();
	for (int i = 0; i < keys.size(); i++) {
		const Array row = n[keys[i]];
		w += w_per_kg(row[0], row[1], row[2], row[3]) * std::pow(2.0, -p_years / double(row[1]));
	}
	return w;
}

// Moles of each daughter element accumulated per kg of rock between formation and `years`.
Dictionary LARadiogenicDecay::daughters_mol_per_kg(const Dictionary &p_traces, double p_years) {
	Dictionary out;
	const double t0 = -la_physical("EARTH_FORMATION_AGE_YEARS");
	const Dictionary n = nuclides(p_traces);
	const Array keys = n.keys();
	for (int i = 0; i < keys.size(); i++) {
		const Array row = n[keys[i]];
		const double n_today = double(row[0]) / double(row[3]);
		const double hl = double(row[1]);
		const double decayed = n_today * (std::pow(2.0, -t0 / hl) - std::pow(2.0, -p_years / hl));
		if (decayed <= 0.0) {
			continue;
		}
		const Dictionary d = row[4];
		const Array dk = d.keys();
		for (int j = 0; j < dk.size(); j++) {
			out[dk[j]] = double(out.get(dk[j], 0.0)) + decayed * double(d[dk[j]]);
		}
	}
	return out;
}

void LARadiogenicDecay::_bind_methods() {
	ClassDB::bind_static_method("LARadiogenicDecay", D_METHOD("epoch_years"), &epoch_years);
	ClassDB::bind_static_method("LARadiogenicDecay", D_METHOD("nuclides", "traces"), &nuclides);
	ClassDB::bind_static_method("LARadiogenicDecay", D_METHOD("heat_w_kg_of", "traces", "years"), &heat_w_kg_of);
	ClassDB::bind_static_method("LARadiogenicDecay", D_METHOD("daughters_mol_per_kg", "traces", "years"), &daughters_mol_per_kg);
}
