#include "LAMeltEos.hpp"

#include "LABirchMurnaghan.hpp"
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

// Third- and fourth-order Birch-Murnaghan/Mie-Grueneisen fits to shocked liquids (Thomas & Asimow 2013, JGR
// 118:5738): the principal isentrope through rho0 at T0, adiabatic K_S, K_S', K_S'' in 1/Pa, the
// Grueneisen parameter gamma = gamma0 (rho0/rho)^q, and Cp at T0. Mg2SiO4 BM3 (Table 3); CaMgSi2O6 BM3,
// Fe2SiO4 BM3 (both from Thomas et al. 2012, JGR 117:B10206), CaAl2Si2O8 BM4 and MgSiO3 BM4 (Table 4).
constexpr double FO_LIQ_T0_K = 2273.0;
constexpr double FO_LIQ_RHO0_KG_M3 = 2597.0;
constexpr double FO_LIQ_GAMMA0 = 0.396;
constexpr double FO_LIQ_Q = -2.02;
constexpr double FO_LIQ_KS_PA = 16.41e9;
constexpr double FO_LIQ_KS_DERIV = 7.37;
constexpr double FO_LIQ_CP_J_KGK = 1926.18;
constexpr double FA_LIQ_T0_K = 1573.0;
constexpr double FA_LIQ_RHO0_KG_M3 = 3699.0;
constexpr double FA_LIQ_GAMMA0 = 0.412;
constexpr double FA_LIQ_Q = -0.95;
constexpr double FA_LIQ_KS_PA = 21.99e9;
constexpr double FA_LIQ_KS_DERIV = 7.28;
constexpr double FA_LIQ_CP_J_KGK = 1182.35;
constexpr double AN_LIQ_T0_K = 1932.0;
constexpr double AN_LIQ_RHO0_KG_M3 = 2560.0;
constexpr double AN_LIQ_GAMMA0 = 0.174;
constexpr double AN_LIQ_Q = -1.86;
constexpr double AN_LIQ_KS_PA = 19.77e9;
constexpr double AN_LIQ_KS_DERIV = 3.73;
constexpr double AN_LIQ_KS_DERIV2_PER_PA = 0.38e-9;
constexpr double AN_LIQ_CP_J_KGK = 1528.72;
constexpr double EN_LIQ_T0_K = 1673.0;
constexpr double EN_LIQ_RHO0_KG_M3 = 2617.0;
constexpr double EN_LIQ_GAMMA0 = 0.365;
constexpr double EN_LIQ_Q = -0.88;
constexpr double EN_LIQ_KS_PA = 24.66e9;
constexpr double EN_LIQ_KS_DERIV = 10.07;
constexpr double EN_LIQ_KS_DERIV2_PER_PA = -2.35e-9;
constexpr double EN_LIQ_CP_J_KGK = 1761.15;
constexpr double DI_LIQ_T0_K = 1673.0;
constexpr double DI_LIQ_RHO0_KG_M3 = 2643.0;
constexpr double DI_LIQ_GAMMA0 = 0.493;
constexpr double DI_LIQ_Q = -1.28;
constexpr double DI_LIQ_KS_PA = 24.57e9;
constexpr double DI_LIQ_KS_DERIV = 6.77;
constexpr double DI_LIQ_CP_J_KGK = 1612.56;

// Molten NaCl at its melting point and the fall of its density with temperature, kg/m^3 and
// kg/(m^3 K) (Janz 1988, J. Phys. Chem. Ref. Data 17 Suppl. 2; CRC 97th ed. 4-128).
constexpr double HALITE_LIQUID_DENSITY_KG_M3 = 1556.0;
constexpr double HALITE_LIQUID_DENSITY_SLOPE_KG_M3K = 0.543;

// Molten NaCl's sound speed at 1253 K, m/s (Bockris & Richards 1957, Proc. R. Soc. A 241:44, as quoted by
// Bryk, Ruocco & Seitsonen 2023, Sci. Rep. 13:18042), and its heat capacity there, J/(mol K), off the
// liquid's Shomate fit (Chase 1998, NIST-JANAF, via the NIST WebBook).
constexpr double HALITE_LIQUID_SOUND_T_K = 1253.0;
constexpr double HALITE_LIQUID_SOUND_M_S = 1586.3;
constexpr double HALITE_LIQUID_CP_J_MOLK = 67.80;
// Second-order Birch-Murnaghan K' (Birch 1947), exact.
constexpr double SECOND_ORDER_BM_DERIV = 4.0;

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

struct MgFit {
	double t0_k;
	double rho0;
	double gamma0;
	double q;
	double ks;
	double ksp;
	double kspp;
	bool fourth;
	double cp;
};

const MgFit FO_LIQ = { FO_LIQ_T0_K, FO_LIQ_RHO0_KG_M3, FO_LIQ_GAMMA0, FO_LIQ_Q, FO_LIQ_KS_PA, FO_LIQ_KS_DERIV, 0.0,
	false, FO_LIQ_CP_J_KGK };
const MgFit FA_LIQ = { FA_LIQ_T0_K, FA_LIQ_RHO0_KG_M3, FA_LIQ_GAMMA0, FA_LIQ_Q, FA_LIQ_KS_PA, FA_LIQ_KS_DERIV, 0.0,
	false, FA_LIQ_CP_J_KGK };
const MgFit AN_LIQ = { AN_LIQ_T0_K, AN_LIQ_RHO0_KG_M3, AN_LIQ_GAMMA0, AN_LIQ_Q, AN_LIQ_KS_PA, AN_LIQ_KS_DERIV,
	AN_LIQ_KS_DERIV2_PER_PA, true, AN_LIQ_CP_J_KGK };
const MgFit DI_LIQ = { DI_LIQ_T0_K, DI_LIQ_RHO0_KG_M3, DI_LIQ_GAMMA0, DI_LIQ_Q, DI_LIQ_KS_PA, DI_LIQ_KS_DERIV, 0.0,
	false, DI_LIQ_CP_J_KGK };
const MgFit EN_LIQ = { EN_LIQ_T0_K, EN_LIQ_RHO0_KG_M3, EN_LIQ_GAMMA0, EN_LIQ_Q, EN_LIQ_KS_PA, EN_LIQ_KS_DERIV,
	EN_LIQ_KS_DERIV2_PER_PA, true, EN_LIQ_CP_J_KGK };

// A power series in eps to third order.
struct T3 {
	double c[4] = { 0.0, 0.0, 0.0, 0.0 };
	T3() {}
	explicit T3(double p_a0) { c[0] = p_a0; }
};

T3 t3(double a0, double a1 = 0.0, double a2 = 0.0, double a3 = 0.0) {
	T3 r;
	r.c[0] = a0;
	r.c[1] = a1;
	r.c[2] = a2;
	r.c[3] = a3;
	return r;
}

T3 operator+(const T3 &a, const T3 &b) {
	return t3(a.c[0] + b.c[0], a.c[1] + b.c[1], a.c[2] + b.c[2], a.c[3] + b.c[3]);
}

T3 operator*(double s, const T3 &a) {
	return t3(s * a.c[0], s * a.c[1], s * a.c[2], s * a.c[3]);
}

T3 operator*(const T3 &a, const T3 &b) {
	T3 r;
	for (int i = 0; i < 4; i++) {
		for (int j = 0; i + j < 4; j++) {
			r.c[i + j] += a.c[i] * b.c[j];
		}
	}
	return r;
}

T3 t3_exp(const T3 &a) {
	const T3 d = t3(0.0, a.c[1], a.c[2], a.c[3]);
	const T3 d2 = d * d;
	const T3 d3 = d2 * d;
	return std::exp(a.c[0]) * (t3(1.0) + d + 0.5 * d2 + (1.0 / 6.0) * d3);
}

// (x0 (1 + eps))^r.
T3 t3_pow(double p_x0, double p_r) {
	return std::pow(p_x0, p_r) * t3(1.0, p_r, 0.5 * p_r * (p_r - 1.0), p_r * (p_r - 1.0) * (p_r - 2.0) / 6.0);
}

// Cv at T0 from the fit's own identities: alpha K_S = gamma0 rho0 Cp, Cv = Cp / (1 + alpha gamma0 T0).
double mg_cv(const MgFit &p_f) {
	const double alpha = p_f.gamma0 * p_f.rho0 * p_f.cp / p_f.ks;
	return p_f.cp / (1.0 + alpha * p_f.gamma0 * p_f.t0_k);
}

// P(V, T) - P0 about V = V0 x0 (1 + eps): the isentrope plus the Mie-Grueneisen thermal pressure
// gamma rho Cv (T - T_S(V)), T_S = T0 exp((gamma0/q)(1 - x^q)).
T3 mg_pressure(const MgFit &p_f, double p_x0, double p_t_k) {
	const T3 f = 0.5 * (t3_pow(p_x0, -2.0 / 3.0) + t3(-1.0));
	const T3 p_s = la_bm::pressure_of<T3>(f, t3_pow(p_x0, -5.0 / 3.0), p_f.ks, p_f.ksp,
			la_bm::b4(p_f.ks, p_f.ksp, p_f.kspp, p_f.fourth));
	const T3 xq = t3_pow(p_x0, p_f.q);
	const T3 t_s = p_f.t0_k * t3_exp((p_f.gamma0 / p_f.q) * (t3(1.0) + (-1.0) * xq));
	const T3 thermal = (p_f.gamma0 * p_f.rho0 * mg_cv(p_f)) * (xq * t3_pow(p_x0, -1.0) * (t3(p_t_k) + (-1.0) * t_s));
	return p_s + thermal;
}

// The fit's one-bar volume ratio x0 = V/V0 at `p_t_k`, where the fit's P(V, T) reads its own reference.
double mg_x0(const MgFit &p_f, double p_t_k) {
	double x = 1.0;
	for (int i = 0; i < 60; i++) {
		const T3 p = mg_pressure(p_f, x, p_t_k);
		ERR_FAIL_COND_V_MSG(!(p.c[1] < 0.0), NAN, "LAMeltEos: the fit's isotherm does not stiffen at this state.");
		const double step = -p.c[0] / p.c[1];
		x *= 1.0 + step;
		if (std::abs(step) < 1.0e-14) {
			break;
		}
	}
	return x;
}

// V/V0 about the one-bar state as a series in dP: eps = b1 dP + b2 dP^2 + b3 dP^3, the reversion of P(eps).
T3 mg_volume_series(const MgFit &p_f, double p_x0, double p_t_k) {
	const T3 p = mg_pressure(p_f, p_x0, p_t_k);
	const double p1 = p.c[1];
	const double p2 = p.c[2];
	const double p3 = p.c[3];
	return t3(1.0, 1.0 / p1, -p2 / (p1 * p1 * p1), (2.0 * p2 * p2 - p1 * p3) / std::pow(p1, 5.0));
}

// LA_APPROX: melt_isotherm_birch_murnaghan
// K_T = -V dP/dV as a series in dP: K_T, K_T' and K_T'' at one bar, from V/V0 = 1 + b1 dP + b2 dP^2 + b3 dP^3.
Dictionary isothermal_moduli(const T3 &p_v) {
	const double b1 = p_v.c[1];
	const double b2 = p_v.c[2];
	const double b3 = p_v.c[3];
	const double k0 = -1.0 / b1;
	const double k1 = (-b1 - k0 * 2.0 * b2) / b1;
	const double k2 = (-b2 - k0 * 3.0 * b3 - k1 * 2.0 * b2) / b1;
	Dictionary out;
	out["bulk_modulus_melt_pa"] = k0;
	out["bulk_modulus_melt_deriv"] = k1;
	out["bulk_modulus_melt_deriv2"] = 2.0 * k2;
	return out;
}

// One liquid's isotherm at `p_t_c` and one bar.
Dictionary mg_isotherm(const MgFit &p_f, double p_t_c) {
	const double t_k = p_t_c + kelvin();
	const double x0 = mg_x0(p_f, t_k);
	ERR_FAIL_COND_V_MSG(!std::isfinite(x0), Dictionary(), "LAMeltEos: the fit has no one-bar state here.");
	Dictionary out = isothermal_moduli(mg_volume_series(p_f, x0, t_k));
	out["specific_heat"] = p_f.cp;
	return out;
}

Dictionary formula2(const char *p_a, double p_na, const char *p_b, double p_nb, double p_o) {
	Dictionary f;
	f[p_a] = p_na;
	f[p_b] = p_nb;
	f["O"] = p_o;
	return f;
}

} // namespace

Dictionary LAMeltEos::oxide_melt(const Dictionary &p_formula, double p_t_c) {
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
	oxide_volume(ox, 6, p_t_c + kelvin(), v, dvdt);
	ERR_FAIL_COND_V_MSG(!(v > 0.0), out, "LAMeltEos: the formula gives the liquid no volume.");
	out["density_melt"] = LAElementAbundances::molar_mass(p_formula) / v;
	out["density_melt_ref_t_c"] = p_t_c;
	out["expansion_melt_per_k"] = dvdt / v;
	return out;
}

// Ideal volume mixing at one pressure: the end-members' V(P)/V0 series add by one-bar volume fraction.
Dictionary LAMeltEos::olivine_melt_compression(double p_mg, double p_t_c) {
	const double t_k = p_t_c + kelvin();
	const double x_fo = mg_x0(FO_LIQ, t_k);
	const double x_fa = mg_x0(FA_LIQ, t_k);
	ERR_FAIL_COND_V_MSG(!std::isfinite(x_fo) || !std::isfinite(x_fa), Dictionary(),
			"LAMeltEos: an olivine end-member liquid has no one-bar state here.");
	const double v_fo = p_mg * LAElementAbundances::molar_mass(formula2("Mg", 2.0, "Si", 1.0, 4.0)) * x_fo / FO_LIQ.rho0;
	const double v_fa = (1.0 - p_mg) * LAElementAbundances::molar_mass(formula2("Fe", 2.0, "Si", 1.0, 4.0)) * x_fa
			/ FA_LIQ.rho0;
	const double phi = v_fo / (v_fo + v_fa);
	Dictionary out = isothermal_moduli(phi * mg_volume_series(FO_LIQ, x_fo, t_k)
			+ (1.0 - phi) * mg_volume_series(FA_LIQ, x_fa, t_k));
	// Heat capacities add by mass.
	const double m_fo = p_mg * LAElementAbundances::molar_mass(formula2("Mg", 2.0, "Si", 1.0, 4.0));
	const double m_fa = (1.0 - p_mg) * LAElementAbundances::molar_mass(formula2("Fe", 2.0, "Si", 1.0, 4.0));
	out["specific_heat"] = (m_fo * FO_LIQ.cp + m_fa * FA_LIQ.cp) / (m_fo + m_fa);
	return out;
}

Dictionary LAMeltEos::enstatite_melt_compression(double p_t_c) {
	return mg_isotherm(EN_LIQ, p_t_c);
}

Dictionary LAMeltEos::diopside_melt_compression(double p_t_c) {
	return mg_isotherm(DI_LIQ, p_t_c);
}

Dictionary LAMeltEos::anorthite_melt_compression(double p_t_c) {
	return mg_isotherm(AN_LIQ, p_t_c);
}

// The liquid at the temperature its sound speed was measured: Janz's density there, K_S = rho c^2, and
// K_T = K_S / (1 + alpha gamma T) with gamma = alpha K_S / (rho c_p).
Dictionary LAMeltEos::halite_melt(double p_melt_c) {
	const double t_c = HALITE_LIQUID_SOUND_T_K - kelvin();
	const double rho = HALITE_LIQUID_DENSITY_KG_M3 - HALITE_LIQUID_DENSITY_SLOPE_KG_M3K * (t_c - p_melt_c);
	const double alpha = HALITE_LIQUID_DENSITY_SLOPE_KG_M3K / rho;
	const double k_s = rho * HALITE_LIQUID_SOUND_M_S * HALITE_LIQUID_SOUND_M_S;
	Dictionary f;
	f["Na"] = 1.0;
	f["Cl"] = 1.0;
	const double cp = HALITE_LIQUID_CP_J_MOLK / LAElementAbundances::molar_mass(f);
	Dictionary out;
	out["density_melt"] = rho;
	out["density_melt_ref_t_c"] = t_c;
	out["expansion_melt_per_k"] = alpha;
	out["density_melt_linear"] = true;
	out["specific_heat"] = cp;
	out["bulk_modulus_melt_pa"] = k_s / (1.0 + alpha * alpha * k_s * HALITE_LIQUID_SOUND_T_K / (rho * cp));
	// LA_APPROX: unmeasured_pressure_derivative
	out["bulk_modulus_melt_deriv"] = SECOND_ORDER_BM_DERIV;
	return out;
}
