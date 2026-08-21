#include "LAPlanetTables.hpp"

#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>

using namespace godot;

namespace {

// Static GDScript entry points this table still consults — the substance table and the sim clock.
Variant call_gd(const char *p_path, const StringName &p_method, const Array &p_args) {
	Ref<Script> s = ResourceLoader::get_singleton()->load(p_path);
	ERR_FAIL_COND_V_MSG(s.is_null(), Variant(), String("LAPlanetTables: failed to load ") + p_path);
	return s->callv(p_method, p_args);
}

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
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const Array keys = w.keys();
	double v_shell = 0.0;
	for (int i = 0; i < keys.size(); i++) {
		v_shell += double(w[keys[i]]) / substance_density(String(keys[i]), p_t_c, p_std);
	}
	Dictionary amounts;
	for (int i = 0; i < keys.size(); i++) {
		const double rho = substance_density(String(keys[i]), p_t_c, p_std);
		const double vf = (double(w[keys[i]]) / rho) / v_shell;
		amounts[keys[i]] = vf * rho / substance_molar_mass(String(keys[i]));
	}
	const double metal_full = substance_density("metal", p_t_c, p_std) / substance_molar_mass("metal");
	Array cargs;
	cargs.push_back(p_field);
	const Vector3 centre = Vector3(call_gd(
			"res://addons/local_agents/sim/material/FieldGeometry3D.gd", "centre", cargs));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = PackedByteArray(p_field->get("_solid"));
	PackedFloat32Array cement = PackedFloat32Array(p_field->get("_cement"));
	PackedFloat32Array metal = PackedFloat32Array(p_field->get("_metal"));
	Dictionary shell;
	const PackedStringArray ch = shell_channels();
	for (int i = 0; i < ch.size(); i++) {
		shell[ch[i]] = PackedFloat32Array(p_field->get("_" + ch[i]));
	}
	double r_max = 0.0;
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			const Vector3 pos = Vector3(grid->call("cell_world_pos", c));
			r_max = MAX(r_max, (pos - centre).length());
		}
	}
	const double r_core = r_max * core_radius_frac(p_t_c, p_std);
	for (int c = 0; c < cc; c++) {
		const bool is_solid = solid[c] != 0;
		cement.set(c, is_solid ? 1.0f : 0.0f);
		if (!is_solid) {
			continue;
		}
		const Vector3 pos = Vector3(grid->call("cell_world_pos", c));
		if ((pos - centre).length() < r_core) {
			metal.set(c, float(metal_full));
			continue;
		}
		for (int i = 0; i < ch.size(); i++) {
			PackedFloat32Array arr = PackedFloat32Array(shell[ch[i]]);
			arr.set(c, float(double(amounts[ch[i]])));
			shell[ch[i]] = arr;
		}
	}
	p_field->set("_cement", cement);
	p_field->set("_metal", metal);
	for (int i = 0; i < ch.size(); i++) {
		p_field->set("_" + ch[i], shell[ch[i]]);
	}
}

void LAPlanetComposition::_bind_methods() {
	ClassDB::bind_static_method("LAPlanetComposition", D_METHOD("shell_channels"), &shell_channels);
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
	const Variant clock = call_gd("res://addons/local_agents/sim/SimClock.gd", "active", Array());
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
