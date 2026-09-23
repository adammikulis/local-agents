#include "LAPhaseEos.hpp"

#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"
#include "LAWaterCurves.hpp"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/templates/hash_map.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
// The kernel's float epsilon, so la_eos_p's twin stops where the kernel does.
constexpr double LA_FLOAT_EPS = std::numeric_limits<float>::epsilon();
using std::abs;
using std::max;
using std::sqrt;

// Peng & Robinson 1976, Ind. Eng. Chem. Fundam. 15:59: a_c = OMEGA_A R^2 Tc^2 / pc, b = OMEGA_B R Tc / pc,
// kappa = K0 + K1 omega - K2 omega^2.
constexpr double PR_OMEGA_A = 0.45724;
constexpr double PR_OMEGA_B = 0.07780;
constexpr double PR_KAPPA_0 = 0.37464;
constexpr double PR_KAPPA_1 = 1.54226;
constexpr double PR_KAPPA_2 = 0.26992;
// The acentric factor's reduced temperature (Pitzer 1955, J. Am. Chem. Soc. 77:3427).
constexpr double ACENTRIC_TR = 0.7;

double pc(const char *p_name) {
	return la_physical(p_name);
}

double dget(const Dictionary &p_d, const char *p_key, double p_default) {
	return double(p_d.get(p_key, p_default));
}

Dictionary row_of(const String &p_id) {
	return Dictionary(LASubstances::table().get(p_id, Dictionary()));
}

// Liquid water, kg/m^3: the saturated liquid from the triple point to the critical point (IAPWS SR1-86).
double water_liquid_density(double p_t_c) {
	const double t_k = std::min(std::max(p_t_c, pc("WATER_TRIPLE_T_C")), pc("WATER_CRITICAL_T_C")) + pc("KELVIN_OFFSET");
	const double tau = std::max(1.0 - t_k / (pc("WATER_CRITICAL_T_C") + pc("KELVIN_OFFSET")), 0.0);
	const double t3 = std::cbrt(tau);
	return pc("WATER_CRITICAL_DENSITY_KG_M3") * (1.0 + pc("IAPWS_SAT_RHO_B1") * t3 + pc("IAPWS_SAT_RHO_B2") * t3 * t3
			+ pc("IAPWS_SAT_RHO_B3") * std::pow(tau, 5.0 / 3.0) + pc("IAPWS_SAT_RHO_B4") * std::pow(tau, 16.0 / 3.0)
			+ pc("IAPWS_SAT_RHO_B5") * std::pow(tau, 43.0 / 3.0) + pc("IAPWS_SAT_RHO_B6") * std::pow(tau, 110.0 / 3.0));
}

// Birch-Murnaghan (Birch 1947, Phys. Rev. 71:809; fourth order, Birch 1978, JGR 83:1257):
//   P = 3 K0 f (1 + 2f)^(5/2) [1 + a f + b4 f^2], a = 3/2 (K0' - 4), b4 = 3/2 (K0 K0'' + (K0' - 4)(K0' - 3) + 35/9)
double bm_b4(const LAPhaseEos &p_e) {
	return p_e.fourth ? 1.5 * (p_e.k * p_e.kpp + (p_e.kp - 4.0) * (p_e.kp - 3.0) + 35.0 / 9.0) : 0.0;
}

double bm_pressure(const LAPhaseEos &p_e, double p_f) {
	const double a = 1.5 * (p_e.kp - 4.0);
	return 3.0 * p_e.k * p_f * std::pow(1.0 + 2.0 * p_f, 2.5) * (1.0 + a * p_f + bm_b4(p_e) * p_f * p_f);
}

// dP/df / (3 K0 (1 + 2f)^(3/2)).
double bm_slope(const LAPhaseEos &p_e, double p_f) {
	const double a = 1.5 * (p_e.kp - 4.0);
	const double b4 = bm_b4(p_e);
	const double u = 1.0 + 2.0 * p_f;
	return (u + 5.0 * p_f) * (1.0 + a * p_f + b4 * p_f * p_f) + p_f * u * (a + 2.0 * b4 * p_f);
}

// The strain interval about f = 0 over which P(f) rises; past its ends the form is not invertible.
void bm_bracket(LAPhaseEos &r_e) {
	r_e.f_lo = -0.45;
	r_e.f_hi = 1.5;
	if (!(r_e.k > 0.0)) {
		return;
	}
	const double step = 1.0e-4;
	for (double f = step; f <= r_e.f_hi; f += step) {
		if (bm_slope(r_e, f) <= 0.0) {
			r_e.f_hi = f - step;
			break;
		}
	}
	for (double f = -step; f >= r_e.f_lo; f -= step) {
		if (bm_slope(r_e, f) <= 0.0) {
			r_e.f_lo = f + step;
			break;
		}
	}
}

// Eulerian strain at a pressure above the reference; NaN, with a named error, outside the bracket.
double bm_strain(const LAPhaseEos &p_e, double p_dp) {
	if (!(p_e.k > 0.0) || p_dp == 0.0) {
		return 0.0;
	}
	double lo = p_e.f_lo;
	double hi = p_e.f_hi;
	ERR_FAIL_COND_V_MSG(!std::isfinite(p_dp) || p_dp < bm_pressure(p_e, lo) || p_dp > bm_pressure(p_e, hi), NAN,
			"LAPhaseEos: " + String::num_scientific(p_dp) + " Pa lies outside the range the Birch-Murnaghan form of a "
					"phase with K0 " + String::num_scientific(p_e.k) + " Pa, K0' " + String::num_scientific(p_e.kp)
					+ ", b4 " + String::num_scientific(bm_b4(p_e)) + " can invert, up to "
					+ String::num_scientific(bm_pressure(p_e, hi)) + " Pa.");
	for (int i = 0; i < 60; ++i) {
		const double mid = 0.5 * (lo + hi);
		if (bm_pressure(p_e, mid) < p_dp) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

// The expansivity falls under pressure as alpha * K_T stays constant (Anderson 1995), K_T = K0 + K0' P.
double phase_alpha_p(const LAPhaseEos &p_e, double p_p_pa) {
	const double dp = p_p_pa - pc("STANDARD_PRESSURE_PA");
	return (p_e.k > 0.0 && dp > 0.0) ? p_e.alpha * p_e.k / (p_e.k + p_e.kp * dp) : p_e.alpha;
}

bool iapws_row(const Dictionary &p_s) {
	return bool(p_s.get("iapws", false));
}

// One named condensed phase: `<rho_key>` at `<rho_key>_ref_t_c`, and the keys that follow it.
LAPhaseEos named_phase(const Dictionary &p_s, const String &p_id, const String &p_rho, const String &p_alpha,
		const String &p_k) {
	LAPhaseEos e;
	if (!p_s.has(p_rho)) {
		return e;
	}
	const String ref = p_rho + String("_ref_t_c");
	ERR_FAIL_COND_V_MSG(!p_s.has(ref), e, "LASubstances(\"" + p_id + "\"): the table gives " + p_rho + " and no " + ref + ".");
	e.rho = double(p_s[p_rho]);
	e.t_ref_c = double(p_s[ref]);
	e.alpha = double(p_s.get(p_alpha, 0.0));
	e.linear_density = bool(p_s.get(p_rho + String("_linear"), false));
	if (p_s.has(p_k + String("_pa"))) {
		ERR_FAIL_COND_V_MSG(!p_s.has(p_k + String("_deriv")), e, "LASubstances(\"" + p_id + "\"): the table gives " + p_k
				+ "_pa and no " + p_k + "_deriv.");
		e.k = double(p_s[p_k + String("_pa")]);
		e.kp = double(p_s[p_k + String("_deriv")]);
		e.fourth = p_s.has(p_k + String("_deriv2"));
		e.kpp = e.fourth ? double(p_s[p_k + String("_deriv2")]) : 0.0;
	}
	bm_bracket(e);
	return e;
}

// The phase a row's own `density` is at its reference temperature and one atmosphere: 0 gas, 1 liquid,
// 2 solid; -1 when the row declares no reference temperature.
int own_phase(const Dictionary &p_s, const String &p_id) {
	if (!p_s.has("density_ref_t_c")) {
		return -1;
	}
	const double t_c = double(p_s["density_ref_t_c"]);
	if (LAPhaseEosFn::gas_at(p_id, t_c, pc("STANDARD_PRESSURE_PA"))) {
		return 0;
	}
	return t_c < dget(p_s, "melt_c", kInf) ? 2 : 1;
}

LACondensedEos build_condensed(const String &p_id) {
	LACondensedEos c;
	const Dictionary s = row_of(p_id);
	const int own = own_phase(s, p_id);
	ERR_FAIL_COND_V_MSG(own < 0, c, "LASubstances(\"" + p_id + "\"): the table gives no density_ref_t_c.");
	c.iapws = iapws_row(s);
	const LAPhaseEos own_eos = named_phase(s, p_id, "density", "expansion_per_k", "bulk_modulus");
	c.solid = own == 2 ? own_eos : named_phase(s, p_id, "density_solid", "expansion_solid_per_k", "bulk_modulus_solid");
	c.liquid = own == 1 ? own_eos : named_phase(s, p_id, "density_melt", "expansion_melt_per_k", "bulk_modulus_melt");
	c.liquid.kell = c.iapws;
	c.valid = true;
	c.melt_c = dget(s, "melt_c", kInf);
	c.melts = std::isfinite(c.melt_c);
	if (!c.melts) {
		return c;
	}
	c.width = std::max(dget(s, "liquidus_c", c.melt_c) - c.melt_c, 0.0);
	c.p_ref = dget(s, "triple_p_pa", pc("STANDARD_PRESSURE_PA"));
	const double v_s = LAPhaseEosFn::phase_volume(c.solid, c.melt_c, c.p_ref);
	const double v_l = LAPhaseEosFn::phase_volume(c.liquid, c.melt_c, c.p_ref);
	c.rho_fus_solid = v_s > 0.0 ? 1.0 / v_s : 0.0;
	c.rho_fus_liquid = v_l > 0.0 ? 1.0 / v_l : 0.0;
	// Clapeyron at the melting point: dT/dP = T dv / L_fus, both phases at that temperature and pressure.
	const double l_fus = dget(s, "latent_fusion_j_kg", 0.0);
	if (v_s > 0.0 && v_l > 0.0 && l_fus > 0.0) {
		c.slope_k_per_pa = (c.melt_c + pc("KELVIN_OFFSET")) * (v_l - v_s) / l_fus;
	}
	return c;
}

LAFluidEos build_fluid(const String &p_id) {
	LAFluidEos f;
	const Dictionary s = row_of(p_id);
	if (!s.has("critical_t_c") || !s.has("critical_p_pa")) {
		return f;
	}
	f.tc_k = double(s["critical_t_c"]) + pc("KELVIN_OFFSET");
	const double p_c = double(s["critical_p_pa"]);
	const double p_sat = LASubstances::saturation_p_at(p_id, ACENTRIC_TR * f.tc_k - pc("KELVIN_OFFSET"));
	ERR_FAIL_COND_V_MSG(!(p_sat > 0.0) || !(p_c > 0.0), f, "LASubstances(\"" + p_id
			+ "\"): no vapour pressure at 0.7 Tc, so the fluid has no acentric factor.");
	const double omega = -1.0 - std::log10(p_sat / p_c);
	const double r = pc("GAS_CONSTANT_J_MOL_K");
	f.a_c = PR_OMEGA_A * r * r * f.tc_k * f.tc_k / p_c;
	f.b = PR_OMEGA_B * r * f.tc_k / p_c;
	f.kappa = PR_KAPPA_0 + PR_KAPPA_1 * omega - PR_KAPPA_2 * omega * omega;
	f.valid = true;
	return f;
}

Dictionary phase_dict(const LAPhaseEos &p_e) {
	Dictionary d;
	if (!(p_e.rho > 0.0)) {
		return d;
	}
	d["rho"] = p_e.rho;
	d["t_ref_c"] = p_e.t_ref_c;
	d["alpha"] = p_e.alpha;
	d["k"] = p_e.k;
	d["kp"] = p_e.kp;
	d["kpp"] = p_e.kpp;
	d["fourth"] = p_e.fourth;
	d["b4"] = bm_b4(p_e);
	d["linear_density"] = p_e.linear_density;
	d["f_lo"] = p_e.f_lo;
	d["f_hi"] = p_e.f_hi;
	return d;
}

} // namespace

const LACondensedEos &LAPhaseEosFn::condensed(const String &p_id) {
	static HashMap<String, LACondensedEos> cache;
	if (!cache.has(p_id)) {
		cache.insert(p_id, build_condensed(p_id));
	}
	return cache[p_id];
}

const LAFluidEos &LAPhaseEosFn::fluid(const String &p_id) {
	static HashMap<String, LAFluidEos> cache;
	if (!cache.has(p_id)) {
		cache.insert(p_id, build_fluid(p_id));
	}
	return cache[p_id];
}

// Gaseous at these conditions? The row's own vapour boundary decides: the frost point below the triple
// pressure, the boiling point above it.
bool LAPhaseEosFn::gas_at(const String &p_id, double p_t_c, double p_p_pa) {
	const Dictionary s = row_of(p_id);
	if (!iapws_row(s) && !std::isfinite(dget(s, "boil_c", kInf))) {
		return false;
	}
	if (LASubstances::sublimes_at(p_id, p_p_pa)) {
		return p_t_c > LASubstances::sublimation_c_at(p_id, p_p_pa);
	}
	return p_t_c > LASubstances::boil_c_at(p_id, p_p_pa);
}

double LAPhaseEosFn::solidus_c(const LACondensedEos &p_c, double p_p_pa) {
	if (!p_c.melts) {
		return kInf;
	}
	if (p_c.iapws) {
		return la_water::iapws_melting_ih_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	return p_c.melt_c + (p_p_pa - p_c.p_ref) * p_c.slope_k_per_pa;
}

double LAPhaseEosFn::melt_fraction(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double solidus = solidus_c(p_c, p_p_pa);
	if (!(p_t_c > solidus)) {
		return 0.0;
	}
	return p_t_c < solidus + p_c.width ? (p_t_c - solidus) / p_c.width : 1.0;
}

double LAPhaseEosFn::phase_volume(const LAPhaseEos &p_e, double p_t_c, double p_p_pa) {
	if (!(p_e.rho > 0.0)) {
		return 0.0;
	}
	const double al = phase_alpha_p(p_e, p_p_pa);
	const double dt = p_t_c - p_e.t_ref_c;
	double v = p_e.kell ? 1.0 / water_liquid_density(p_t_c)
			: (p_e.linear_density ? 1.0 / (p_e.rho * (1.0 - al * dt)) : (1.0 + al * dt) / p_e.rho);
	if (p_e.k > 0.0 && p_p_pa > 0.0) {
		const double f = bm_strain(p_e, p_p_pa - pc("STANDARD_PRESSURE_PA"));
		if (!std::isfinite(f)) {
			return 0.0;
		}
		v *= std::pow(1.0 + 2.0 * f, -1.5);
	}
	return v > 0.0 ? v : 0.0;
}

// K_T = -V dP/dV = (1 + 2f) dP/df / 3 at the pressure's own strain.
double LAPhaseEosFn::phase_k_t(const LAPhaseEos &p_e, double p_p_pa) {
	if (!(p_e.k > 0.0)) {
		return 0.0;
	}
	const double f = bm_strain(p_e, p_p_pa - pc("STANDARD_PRESSURE_PA"));
	return std::isfinite(f) ? p_e.k * std::pow(1.0 + 2.0 * f, 2.5) * bm_slope(p_e, f) : 0.0;
}

double LAPhaseEosFn::condensed_volume(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	if (!p_c.valid) {
		return 0.0;
	}
	if (!(p_c.solid.rho > 0.0)) {
		return phase_volume(p_c.liquid, p_t_c, p_p_pa);
	}
	const double v_s = phase_volume(p_c.solid, p_t_c, p_p_pa);
	const double phi = melt_fraction(p_c, p_t_c, p_p_pa);
	if (phi <= 0.0) {
		return v_s;
	}
	const double v_l = phase_volume(p_c.liquid, p_t_c, p_p_pa);
	if (!(v_l > 0.0) || !(v_s > 0.0)) {
		return 0.0;
	}
	return (1.0 - phi) * v_s + phi * v_l;
}

bool LAPhaseEosFn::representable(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double dp = p_p_pa - pc("STANDARD_PRESSURE_PA");
	auto reaches = [&](const LAPhaseEos &e) {
		return !(e.k > 0.0) || (dp >= bm_pressure(e, e.f_lo) && dp <= bm_pressure(e, e.f_hi));
	};
	const double phi = (p_c.solid.rho > 0.0) ? melt_fraction(p_c, p_t_c, p_p_pa) : 1.0;
	return (phi >= 1.0 || reaches(p_c.solid)) && (phi <= 0.0 || reaches(p_c.liquid));
}

// Each phase's own expansivity at this state, weighted by the volume it fills; the melting step is not one.
double LAPhaseEosFn::condensed_alpha(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	auto phase_alpha = [&](const LAPhaseEos &e) {
		const double al = phase_alpha_p(e, p_p_pa);
		const double dt = p_t_c - e.t_ref_c;
		return e.linear_density ? al / (1.0 - al * dt) : al / (1.0 + al * dt);
	};
	const double phi = (p_c.solid.rho > 0.0) ? melt_fraction(p_c, p_t_c, p_p_pa) : 1.0;
	const double v_s = phi < 1.0 ? phase_volume(p_c.solid, p_t_c, p_p_pa) : 0.0;
	const double v_l = phi > 0.0 ? phase_volume(p_c.liquid, p_t_c, p_p_pa) : 0.0;
	const double v = (1.0 - phi) * v_s + phi * v_l;
	if (!(v > 0.0)) {
		return 0.0;
	}
	return ((1.0 - phi) * v_s * phase_alpha(p_c.solid) + phi * v_l * phase_alpha(p_c.liquid)) / v;
}

double LAPhaseEosFn::condensed_compressibility(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double phi = (p_c.solid.rho > 0.0) ? melt_fraction(p_c, p_t_c, p_p_pa) : 1.0;
	auto part = [&](const LAPhaseEos &e, double w) {
		if (!(w > 0.0)) {
			return 0.0;
		}
		const double k = phase_k_t(e, p_p_pa);
		return k > 0.0 ? w * phase_volume(e, p_t_c, p_p_pa) / k : 0.0;
	};
	return part(p_c.solid, 1.0 - phi) + part(p_c.liquid, phi);
}

double LAPhaseEosFn::pr_a(const LAFluidEos &p_f, double p_t_k) {
	const double s = 1.0 + p_f.kappa * (1.0 - std::sqrt(std::max(p_t_k, 0.0) / p_f.tc_k));
	return p_f.a_c * s * s;
}

// LA_APPROX: peng_robinson_fluid
// Z^3 - (1 - B) Z^2 + (A - 3B^2 - 2B) Z - (AB - B^2 - B^3) = 0, which reads -2B^2 at Z = B. Newton from
// above every root, kept inside the bracket, lands on the largest: the vapour or the one supercritical fluid.
double LAPhaseEosFn::pr_molar_volume(const LAFluidEos &p_f, double p_t_k, double p_p_pa) {
	const double rt = pc("GAS_CONSTANT_J_MOL_K") * p_t_k;
	if (!p_f.valid || !(rt > 0.0) || !(p_p_pa > 0.0)) {
		return 0.0;
	}
	const double a = pr_a(p_f, p_t_k) * p_p_pa / (rt * rt);
	const double b = p_f.b * p_p_pa / rt;
	const double c2 = -(1.0 - b);
	const double c1 = a - 3.0 * b * b - 2.0 * b;
	const double c0 = -(a * b - b * b - b * b * b);
	double lo = b;
	double hi = 1.0 + std::abs(c2) + std::abs(c1) + std::abs(c0);
	double z = hi;
	for (int i = 0; i < 200; i++) {
		const double f = ((z + c2) * z + c1) * z + c0;
		const double df = (3.0 * z + 2.0 * c2) * z + c1;
		if (f > 0.0) {
			hi = z;
		} else {
			lo = z;
		}
		double next = df > 0.0 ? z - f / df : 0.5 * (lo + hi);
		next = (next > lo && next < hi) ? next : 0.5 * (lo + hi);
		const bool done = std::abs(next - z) <= 1.0e-14 * z;
		z = next;
		if (done) {
			break;
		}
	}
	ERR_FAIL_COND_V_MSG(!(z > b), 0.0, "LAPhaseEos: the Peng-Robinson cubic has no fluid root here.");
	return z * rt / p_p_pa;
}

double LAPhaseEosFn::mixture_pressure(double vol, double a_gas_rt, double s_a, double s_b, double b_vol, double c_comp,
		double p_ref) {
	if (vol <= 0.0) {
		return 0.0;
	}
	if (c_comp <= 0.0) {
		double room = vol - b_vol;
		return room > s_b ? a_gas_rt / (room - s_b) - s_a * s_a / (room * room + 2.0 * s_b * room - s_b * s_b) : 0.0;
	}
	// No gas at all: the condensed phases alone are squeezed into the cell.
	if (a_gas_rt <= 0.0) {
		return p_ref + (b_vol - vol) / c_comp;
	}
	double k = vol - b_vol - s_b - c_comp * p_ref;
	double disc = sqrt(k * k + 4.0 * c_comp * a_gas_rt);
	double p_id = (k > 0.0) ? 2.0 * a_gas_rt / (k + disc) : (disc - k) / (2.0 * c_comp);
	if (s_a <= 0.0) {
		return p_id;
	}
	double lo = p_ref + (s_b - vol + b_vol) / c_comp;
	double hi = max(p_id, lo + abs(lo) * 4.0 * LA_FLOAT_EPS + 1.0);
	for (int i = 0; i < 64; ++i) {
		double room = vol - b_vol + c_comp * (hi - p_ref);
		double r = hi - (a_gas_rt / (room - s_b) - s_a * s_a / (room * room + 2.0 * s_b * room - s_b * s_b));
		if (r >= 0.0) { break; }
		hi = lo + 2.0 * (hi - lo);
	}
	for (int i = 0; i < 64; ++i) {
		double mid = 0.5 * (lo + hi);
		double room = vol - b_vol + c_comp * (mid - p_ref);
		double r = mid - (a_gas_rt / (room - s_b) - s_a * s_a / (room * room + 2.0 * s_b * room - s_b * s_b));
		if (r < 0.0) { lo = mid; } else { hi = mid; }
		if (hi - lo <= 4.0 * LA_FLOAT_EPS * abs(hi)) {
			break;
		}
	}
	return 0.5 * (lo + hi);
}

Dictionary LAPhaseEosFn::describe(const String &p_id) {
	const LACondensedEos &c = condensed(p_id);
	const LAFluidEos &f = fluid(p_id);
	Dictionary out;
	out["solid"] = phase_dict(c.solid);
	out["liquid"] = phase_dict(c.liquid);
	Dictionary fl;
	if (f.valid) {
		fl["tc_k"] = f.tc_k;
		fl["a_c"] = f.a_c;
		fl["b"] = f.b;
		fl["kappa"] = f.kappa;
	}
	out["fluid"] = fl;
	return out;
}
