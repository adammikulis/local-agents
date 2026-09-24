#include "LASubstanceOptics.hpp"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

using namespace godot;

namespace {

// A GAS'S RAYLEIGH OPTICS. Refractivity y = sum B_i / (C_i - D_i s^2) + sum P_j s^2j, s = 1 / lambda in 1/um,
// is n - 1, or n^2 - 1 where `squared`, measured at the reference state; the King factor is sum K_j s^2j.
struct GasOptics {
	const char *id;
	bool squared;
	std::vector<double> b;
	std::vector<double> c;
	std::vector<double> d_um2;
	std::vector<double> poly;
	double ref_t_c;
	double ref_p_pa;
	std::vector<double> king;
};

const GasOptics GAS_OPTICS[] = {
	// n^2 - 1 = sum B_i lambda^2 / (lambda^2 - C_i), lambda in um, at 0 C and 1000 hPa (Borzsonyi et al. 2008,
	// Appl. Opt. 47:4856); F_K = 1.034 + 3.17e-4 / lambda^2 (Bates 1984, Planet. Space Sci. 32:785).
	{ "n2", true, { 39209.95e-8, 18806.48e-8 }, { 1.0, 1.0 }, { 1146.24e-6, 13.476e-3 }, {}, 0.0, 1.0e5,
			{ 1.034, 3.17e-4 } },
	// n - 1 at 0 C and 101325 Pa (Bideau-Mehu et al. 1973, Opt. Commun. 9:432); F_K = 1.1364 + 25.3e-12 nu^2,
	// nu in 1/cm (Sneep & Ubachs 2005, JQSRT 92:293), 1e8 nu^2 per s^2.
	{ "co2", false, { 6.99100e-2, 1.44720e-3, 6.42941e-5, 5.21306e-5, 1.46847e-6 },
			{ 166.175, 79.609, 56.3064, 46.0196, 0.0584738 }, { 1.0, 1.0, 1.0, 1.0, 1.0 }, {}, 0.0, 101325.0,
			{ 1.1364, 25.3e-12 * 1.0e8 } },
	// n - 1 at 0 C and 101325 Pa (Peck & Hung 1977, J. Opt. Soc. Am. 67:1550); F_K = 1 + (2/9) (gamma/alpha)^2,
	// the rotational S(0) over the Rayleigh coefficient of J = 0 (Oklopcic, Hirata & Heng 2016, ApJ 832:30).
	// LA_APPROX: static_polarizability_king_factor
	{ "h2", false, { 0.0148956, 0.0049037 }, { 180.7, 92.0 }, { 1.0, 1.0 }, {}, 0.0, 101325.0,
			{ 1.0 + 2.64973960879e-46 / 8.40817110301e-45 } },
	// Vapour: n - 1 = 1.022e-8 (295.235 + 2.6422 s^2 - 0.032380 s^4 + 0.004028 s^6) at 20 C and 1333 Pa
	// (Ciddor 1996, Appl. Opt. 35:1566); F_K = (6 + 3 rho) / (6 - 7 rho), rho 3.0e-4 (Murphy 1977, J. Chem.
	// Phys. 67:5877).
	{ "h2o", false, {}, {}, {}, { 1.022e-8 * 295.235, 1.022e-8 * 2.6422, -1.022e-8 * 0.032380, 1.022e-8 * 0.004028 },
			20.0, 1333.0, { (6.0 + 3.0 * 3.0e-4) / (6.0 - 7.0 * 3.0e-4) } },
};

// Liquid water: refractive index at 589 nm, 0 C and 0.1 MPa (IAPWS R9-97 1997, Table 3); pure water's
// absorption (Pope & Fry 1997, Appl. Opt. 36:8710) and scattering (Morel 1974, as listed in Pegau, Zaneveld &
// Mueller 2003, NASA/TM-2003-211621/Rev4-Vol.IV, Table 1.1), 1/m, at the listed nm, and the depolarization
// ratio of its volume scattering function (Morel 1974).
constexpr double WATER_LIQUID_REFRACTIVE_INDEX = 1.334344;
const std::vector<double> WATER_LIQUID_OPTICS_NM = { 440.0, 550.0, 680.0 };
const std::vector<double> WATER_LIQUID_ABSORPTION_PER_M = { 0.00635, 0.0565, 0.465 };
const std::vector<double> WATER_LIQUID_SCATTERING_PER_M = { 0.0038, 0.0015, 0.0006 };
constexpr double WATER_LIQUID_SCATTERING_DEPOLARIZATION = 0.09;

Array doubles_of(const std::vector<double> &p_v) {
	Array a;
	for (double x : p_v) {
		a.push_back(x);
	}
	return a;
}

} // namespace

void la_optics::declare(Dictionary &p_table) {
	for (const GasOptics &o : GAS_OPTICS) {
		Dictionary row = p_table.get(String(o.id), Dictionary());
		ERR_CONTINUE_MSG(row.is_empty(), String("la_optics: optics for ") + o.id + " name no row.");
		row["refractivity_squared"] = o.squared;
		row["refractivity_b"] = doubles_of(o.b);
		row["refractivity_c"] = doubles_of(o.c);
		row["refractivity_d_um2"] = doubles_of(o.d_um2);
		row["refractivity_poly"] = doubles_of(o.poly);
		row["refractivity_ref_t_c"] = o.ref_t_c;
		row["refractivity_ref_p_pa"] = o.ref_p_pa;
		row["king_factor"] = doubles_of(o.king);
	}
	Dictionary water = p_table.get("h2o", Dictionary());
	ERR_FAIL_COND_MSG(water.is_empty(), "la_optics: the table holds no h2o row for liquid water's optics.");
	water["refractive_index_liquid"] = WATER_LIQUID_REFRACTIVE_INDEX;
	water["optics_liquid_nm"] = doubles_of(WATER_LIQUID_OPTICS_NM);
	water["absorption_liquid_per_m"] = doubles_of(WATER_LIQUID_ABSORPTION_PER_M);
	water["scattering_liquid_per_m"] = doubles_of(WATER_LIQUID_SCATTERING_PER_M);
	water["scattering_liquid_depolarization"] = WATER_LIQUID_SCATTERING_DEPOLARIZATION;
}
