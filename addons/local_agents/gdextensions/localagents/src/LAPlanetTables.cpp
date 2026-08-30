#include "LAGridGeometry.hpp"
#include <godot_cpp/variant/utility_functions.hpp>
#include "LAPlanetTables.hpp"

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
	std::vector<double> m_in;
	double mass = 0.0;
};

static RadialProfile radial_profile(double p_radius_m, double p_t_c) {
	RadialProfile out;
	if (!(p_radius_m > 0.0)) {
		return out;
	}
	const int N = 192;
	const double g_const = la_physical("GRAVITATIONAL_CONSTANT");
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double f_core = LAElementAbundances::core_mass_fraction();
	const double dr = p_radius_m / double(N);
	std::vector<double> rho(N, 0.0), m_in(N, 0.0), p_at(N, p_std);
	const double rho_shell0 = LAPlanetComposition::shell_density(p_t_c, p_std);
	const double rho_core0 = LASubstances::density("metal", p_t_c, p_std);
	if (rho_shell0 <= 0.0 || rho_core0 <= 0.0) {
		return out;
	}
	int i_core = int(double(N) * LAPlanetComposition::core_radius_frac(p_t_c, p_std));
	for (int i = 0; i < N; ++i) {
		rho[i] = (i < i_core) ? rho_core0 : rho_shell0;
	}
	for (int pass = 0; pass < 24; ++pass) {
		double acc = 0.0;
		for (int i = 0; i < N; ++i) {
			const double r_lo = double(i) * dr;
			const double r_hi = r_lo + dr;
			acc += rho[i] * (4.0 / 3.0) * kPi * (r_hi * r_hi * r_hi - r_lo * r_lo * r_lo);
			m_in[i] = acc;
		}
		const double total = acc;
		if (!(total > 0.0)) {
			return out;
		}
		// The core boundary is a MASS fraction, so it moves as the profile compresses.
		i_core = 0;
		while (i_core < N && m_in[i_core] < f_core * total) {
			++i_core;
		}
		// Hydrostatic pressure, integrated inward from one atmosphere at the surface.
		double p = p_std;
		for (int i = N - 1; i >= 0; --i) {
			const double r_mid = (double(i) + 0.5) * dr;
			const double g = g_const * m_in[i] / (r_mid * r_mid);
			p += rho[i] * g * dr;
			p_at[i] = p;
		}
		for (int i = 0; i < N; ++i) {
			const double d = (i < i_core) ? LASubstances::density("metal", p_t_c, p_at[i])
										  : LAPlanetComposition::shell_density(p_t_c, p_at[i]);
			if (d > 0.0) {
				rho[i] = d;
			}
		}
	}
	double total = 0.0;
	for (int i = 0; i < N; ++i) {
		const double r_lo = double(i) * dr;
		const double r_hi = r_lo + dr;
		total += rho[i] * (4.0 / 3.0) * kPi * (r_hi * r_hi * r_hi - r_lo * r_lo * r_lo);
	}
	out.n = N;
	out.m_in = m_in;
	out.i_core = i_core;
	out.dr = dr;
	out.p_at = p_at;
	out.mass = total;
	return out;
}

static double mass_at_radius(double p_radius_m, double p_t_c) {
	return radial_profile(p_radius_m, p_t_c).mass;
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
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double rho_un = shell_density(p_t_c, p_std);
	if (rho_un <= 0.0) {
		return 0.0;
	}
	// The uncompressed body is the largest it can be, so it brackets the answer from above.
	double hi = std::pow(3.0 * p_mass_kg / (4.0 * kPi * rho_un), 1.0 / 3.0) * 1.2;
	double lo = hi * 0.2;
	for (int i = 0; i < 48; ++i) {
		const double mid = 0.5 * (lo + hi);
		if (mass_at_radius(mid, p_t_c) < p_mass_kg) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

// Fill the field's mineral mirrors: a differentiated body — metal core, one silicate shell of the
// registry's own mineral mix. Differentiation at ~10^13 steps is not computable, so the layering is
// seeded; the maintainer's decision, not a law.
void LAPlanetComposition::seed(Object *p_field, double p_t_c) {
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
		double v_shell = 0.0;
		for (int i = 0; i < keys.size(); i++) {
			v_shell += double(w[keys[i]]) / substance_density(String(keys[i]), p_t_c, prof.p_at[j]);
		}
		for (int i = 0; i < keys.size(); i++) {
			const double rho = substance_density(String(keys[i]), p_t_c, prof.p_at[j]);
			amounts[j][i] = (double(w[keys[i]]) / rho) / v_shell * rho / substance_molar_mass(String(keys[i]));
		}
		metal_at[j] = substance_density("metal", p_t_c, prof.p_at[j]) / substance_molar_mass("metal");
	}
	Array cargs;
	cargs.push_back(p_field);
	const Vector3 centre = Vector3(la_call_gd(
			"res://addons/local_agents/sim/material/FieldGeometry3D.gd", "centre", cargs));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = PackedByteArray(p_field->get("_solid"));
	PackedFloat32Array cement = PackedFloat32Array(p_field->get("_cement"));
	PackedFloat32Array metal = PackedFloat32Array(p_field->get("_metal"));
	const PackedStringArray ch = shell_channels();
	std::vector<PackedFloat32Array> shell(ch.size());
	std::vector<int> col(ch.size(), -1);
	for (int i = 0; i < ch.size(); i++) {
		shell[i] = PackedFloat32Array(p_field->get("_" + ch[i]));
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
					if (j < prof.i_core) {
						m_acc += metal_at[j];
						continue;
					}
					for (int i = 0; i < ch.size(); i++) {
						acc[i] += col[i] >= 0 ? amounts[j][col[i]] : 0.0;
					}
				}
			}
		}
		mw[c] = float(m_acc * w_sub * f);
		for (int i = 0; i < ch.size(); i++) {
			sw[i][c] = float(acc[i] * w_sub * f);
		}
	}
	p_field->set("_cement", cement);
	p_field->set("_metal", metal);
	for (int i = 0; i < ch.size(); i++) {
		p_field->set("_" + ch[i], shell[i]);
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
	double lo = -1.0, hi = -1.0;
	if (p_terrain->has_method("min_surface_radius") && p_terrain->has_method("max_surface_radius")) {
		lo = double(p_terrain->call("min_surface_radius"));
		hi = double(p_terrain->call("max_surface_radius"));
	}
	const PackedFloat32Array edge = p_grid->call("cell_edges");
	PackedFloat32Array rock, water, ground;
	rock.resize(cc);
	water.resize(cc);
	ground.resize(cc);
	float *rw = rock.ptrw();
	float *ww = water.ptrw();
	float *gw = ground.ptrw();
	std::vector<int> ask;
	for (int c = 0; c < cc; c++) {
		const double r = double((cw[c] - p_centre).length());
		const double pad = c < edge.size() ? 0.5 * std::sqrt(3.0) * double(edge[c]) : 0.0;
		ww[c] = 0.0f;
		// The ground under a cell the relief never reaches: the cell's own bottom along the vertical,
		// so a band of water in it starts at its lowest corner.
		{
			const Vector3 rel = cw[c] - p_centre;
			const double r0 = double(rel.length());
			const Vector3 up = r0 > 0.0 ? rel / float(r0) : Vector3(0, 1, 0);
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
		const double r0 = double(rel.length());
		if (!(r0 > 0.0)) {
			continue;
		}
		const Vector3 up = rel / float(r0);
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

PackedFloat32Array LAPlanetComposition::surface_depth(Object *p_grid, Object *p_terrain, const Vector3 &p_centre) {
	PackedFloat32Array out;
	if (!p_grid || !p_terrain) {
		return out;
	}
	const int cc = int(p_grid->get("cell_count"));
	const PackedVector3Array cw = p_grid->get("centres");
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
		const Vector3 rel = cw[c] - p_centre;
		const double r = double(rel.length());
		if (!(r > 0.0)) {
			w[c] = float(lo);
			continue;
		}
		const Vector3 dir = rel / float(r);
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
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("seed", "field", "t_c"), &seed);
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
