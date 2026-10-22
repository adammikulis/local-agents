#include "LAPhaseEos.hpp"

#include "LABirchMurnaghan.hpp"
#include "LAMeltingLine.hpp"
#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"
#include "LAWaterCurves.hpp"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/templates/hash_map.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>

using namespace godot;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
// The kernel's float epsilon, so la_eos_p's twin stops where the kernel does.
constexpr double LA_FLOAT_EPS = std::numeric_limits<float>::epsilon();
// A gas packed past its co-volume states no pressure.
constexpr double LA_NAN = std::numeric_limits<double>::quiet_NaN();
using std::abs;
using std::max;
using std::sqrt;

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

double bm_b4(const LAPhaseEos &p_e) {
	return la_bm::b4(p_e.k, p_e.kp, p_e.kpp, p_e.fourth);
}

double bm_pressure(const LAPhaseEos &p_e, double p_f) {
	return la_bm::pressure(p_f, p_e.k, p_e.kp, bm_b4(p_e));
}

// Eulerian strain at a pressure off the reference; NaN, with a named error, where the phase's modulus is
// unmeasured or the pressure lies outside the bracket its form can invert.
double bm_strain(const LAPhaseEos &p_e, double p_dp) {
	if (p_dp == 0.0) {
		return 0.0;
	}
	ERR_FAIL_COND_V_MSG(!p_e.has_k, NAN, "LAPhaseEos: a phase with no measured bulk modulus is asked for its volume "
			"off one atmosphere.");
	double lo = p_e.f_lo;
	double hi = p_e.f_hi;
	// Where P rises for every positive strain, the bracket's top is the first doubling that passes p.
	for (int i = 0; i < 64 && std::isinf(hi) && p_dp > 0.0; ++i) {
		const double f = std::ldexp(1.0, i);
		hi = bm_pressure(p_e, f) >= p_dp ? f : hi;
	}
	ERR_FAIL_COND_V_MSG(!std::isfinite(p_dp) || p_dp < bm_pressure(p_e, lo) || (!std::isinf(hi) && p_dp > bm_pressure(p_e, hi)), NAN,
			"LAPhaseEos: " + String::num_scientific(p_dp) + " Pa lies outside the range the Birch-Murnaghan form of a "
					"phase with K0 " + String::num_scientific(p_e.k) + " Pa, K0' " + String::num_scientific(p_e.kp)
					+ ", b4 " + String::num_scientific(bm_b4(p_e)) + " can invert, up to "
					+ String::num_scientific(bm_pressure(p_e, hi)) + " Pa.");
	hi = std::isinf(hi) ? 0.0 : hi;
	// Newton on P(f) = p inside the bracket, halving it wherever a step would leave it.
	const double eps = std::numeric_limits<double>::epsilon();
	double f = std::clamp(p_dp / (3.0 * p_e.k), lo, hi);
	for (int i = 0; i < 200; ++i) {
		const double r = bm_pressure(p_e, f) - p_dp;
		if (r == 0.0) {
			return f;
		}
		(r < 0.0 ? lo : hi) = f;
		const double slope = 3.0 * p_e.k * std::pow(1.0 + 2.0 * f, 1.5) * la_bm::slope(f, p_e.kp, bm_b4(p_e));
		double next = slope > 0.0 ? f - r / slope : 0.5 * (lo + hi);
		next = (next > lo && next < hi) ? next : 0.5 * (lo + hi);
		if (std::abs(next - f) <= 2.0 * eps * std::abs(next) || hi - lo <= 2.0 * eps * std::max(std::abs(lo), std::abs(hi))) {
			return next;
		}
		f = next;
	}
	return f;
}

// LA_APPROX: separable_thermal_compression
// The expansivity falls under pressure as alpha * K_T stays constant (Anderson 1995), K_T = K0 + K0' dP.
double phase_alpha_p(const LAPhaseEos &p_e, double p_p_pa) {
	const double dp = p_p_pa - pc("STANDARD_PRESSURE_PA");
	return p_e.alpha * p_e.k / (p_e.k + p_e.kp * dp);
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
	e.has_alpha = p_s.has(p_alpha);
	e.alpha = e.has_alpha ? double(p_s[p_alpha]) : NAN;
	e.linear_density = bool(p_s.get(p_rho + String("_linear"), false));
	e.has_k = p_s.has(p_k + String("_pa"));
	e.k = NAN;
	e.kp = NAN;
	if (e.has_k) {
		ERR_FAIL_COND_V_MSG(!p_s.has(p_k + String("_deriv")), LAPhaseEos(), "LASubstances(\"" + p_id
				+ "\"): the table gives " + p_k + "_pa and no " + p_k + "_deriv.");
		e.k = double(p_s[p_k + String("_pa")]);
		e.kp = double(p_s[p_k + String("_deriv")]);
		e.fourth = p_s.has(p_k + String("_deriv2"));
		e.kpp = e.fourth ? double(p_s[p_k + String("_deriv2")]) : 0.0;
		la_bm::bracket(e.kp, bm_b4(e), e.f_lo, e.f_hi);
	}
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
	c.melts = s.has("melt_c");
	if (!c.melts) {
		c.valid = true;
		return c;
	}
	for (const char *key : { "liquidus_c", "melt_p_pa", "latent_fusion_j_kg" }) {
		ERR_FAIL_COND_V_MSG(!s.has(key), c, "LASubstances(\"" + p_id + "\"): the table gives melt_c and no " + key + ".");
	}
	c.melt_c = double(s["melt_c"]);
	c.width = double(s["liquidus_c"]) - c.melt_c;
	c.p_ref = double(s["melt_p_pa"]);
	const double l_fus = double(s["latent_fusion_j_kg"]);
	ERR_FAIL_COND_V_MSG(c.width < 0.0 || !(l_fus > 0.0), c, "LASubstances(\"" + p_id
			+ "\"): a liquidus below the solidus, or melting that costs no heat.");
	if (c.iapws) {
		c.valid = true;
		return c;
	}
	// A row that carries its published melting line reads it; any other takes Clapeyron at the melting
	// point, dT/dP = T dv / L_fus, both phases at that temperature and pressure.
	if (s.has("melt_line_form")) {
		const String form = s["melt_line_form"];
		const Array a = s.get("melt_line_a", Array());
		const Array cx = s.get("melt_line_c", Array());
		c.fusion_kind = form == "simon" ? 1 : (form == "reduced_poly" ? 2 : (form == "reduced_simon" ? 3 : -1));
		ERR_FAIL_COND_V_MSG(c.fusion_kind < 0 || a.is_empty() || a.size() != cx.size() || a.size() > 2
						|| !s.has("melt_line_t0_k") || !s.has("melt_line_p0_pa"),
				c, "LASubstances(\"" + p_id + "\"): the melting line is not one the rule reads.");
		c.fusion_t0_k = double(s["melt_line_t0_k"]);
		c.fusion_p0 = double(s["melt_line_p0_pa"]);
		c.fusion_a1 = double(a[0]);
		c.fusion_c1 = double(cx[0]);
		c.fusion_a2 = a.size() > 1 ? double(a[1]) : 0.0;
		c.fusion_c2 = a.size() > 1 ? double(cx[1]) : 1.0;
		c.valid = true;
		return c;
	}
	const double v_s = LAPhaseEosFn::phase_volume(c.solid, c.melt_c, c.p_ref);
	const double v_l = LAPhaseEosFn::phase_volume(c.liquid, c.melt_c, c.p_ref);
	ERR_FAIL_COND_V_MSG(!(v_s > 0.0) || !(v_l > 0.0), c, "LASubstances(\"" + p_id
			+ "\"): a phase at the melting point has no measured volume, so the melting curve has no slope.");
	c.fusion_p0 = c.p_ref;
	c.fusion_a1 = (c.melt_c + pc("KELVIN_OFFSET")) * (v_l - v_s) / l_fus;
	c.valid = true;
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
	// Pitzer 1955's definition where the reference equation gives none: omega = -1 - log10(p_sat / pc) at
	// T = 0.7 Tc, on the row's own vapour curve. A row with no vapour curve there is no fluid.
	const double p_07 = LASubstances::saturation_p_at(p_id, 0.7 * f.tc_k - pc("KELVIN_OFFSET"));
	if (!s.has("acentric_factor") && !(p_07 > 0.0)) {
		return f;
	}
	const double omega = s.has("acentric_factor") ? double(s["acentric_factor"]) : -1.0 - std::log10(p_07 / p_c);
	const double r = pc("GAS_CONSTANT_J_MOL_K");
	f.a_c = pc("PR_OMEGA_A") * r * r * f.tc_k * f.tc_k / p_c;
	f.b = pc("PR_OMEGA_B") * r * f.tc_k / p_c;
	f.kappa = pc("PR_KAPPA_0") + pc("PR_KAPPA_1") * omega - pc("PR_KAPPA_2") * omega * omega;
	f.valid = true;
	return f;
}

// The melting line at p, C. Kernel twin la_fusion_c in enthalpy.glsli.
double fusion_c(const LACondensedEos &p_c, double p_p_pa) {
	const double k = pc("KELVIN_OFFSET");
	const double t = la_melt_line::temperature_k(p_c.fusion_kind, p_c.melt_c + k, p_c.p_ref, p_c.fusion_t0_k,
			p_c.fusion_p0, p_c.fusion_a1, p_c.fusion_c1, p_c.fusion_a2, p_c.fusion_c2, p_p_pa);
	ERR_FAIL_COND_V_MSG(std::isnan(t), NAN, "LAPhaseEos: the melting line did not converge at "
			+ String::num_scientific(p_p_pa) + " Pa.");
	return t - k;
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
	d["b4"] = p_e.has_k ? bm_b4(p_e) : NAN;
	d["linear_density"] = p_e.linear_density;
	d["f_lo"] = p_e.f_lo;
	d["f_hi"] = p_e.f_hi;
	return d;
}

} // namespace

const LACondensedEos &LAPhaseEosFn::condensed(const String &p_id) {
	static HashMap<String, LACondensedEos> cache;
	static std::mutex lock;
	const std::lock_guard<std::mutex> guard(lock);
	if (!cache.has(p_id)) {
		cache.insert(p_id, build_condensed(p_id));
	}
	return cache[p_id];
}

double LAPhaseEosFn::vapour_z(const LAFluidEos &p_f, double p_t_k, double p_p_pa) {
	if (!p_f.valid) {
		return LA_NAN;
	}
	const double u = 1.0 + p_f.kappa * (1.0 - sqrt(p_t_k / p_f.tc_k));
	const double rt = pc("GAS_CONSTANT_J_MOL_K") * p_t_k;
	const double a = p_f.a_c * u * u * p_p_pa / (rt * rt);
	const double b = p_f.b * p_p_pa / rt;
	const double c2 = -(1.0 - b);
	const double c1 = a - 3.0 * b * b - 2.0 * b;
	const double c0 = -(a * b - b * b - b * b * b);
	double z = 1.0;
	for (int i = 0; i < PR_Z_STEPS; ++i) {
		const double f = ((z + c2) * z + c1) * z + c0;
		const double d = (3.0 * z + 2.0 * c2) * z + c1;
		const double step = f / d;
		z -= step;
		if (abs(step) <= 4.0 * std::numeric_limits<double>::epsilon() * z) {
			return z;
		}
	}
	return LA_NAN;
}

const LAFluidEos &LAPhaseEosFn::fluid(const String &p_id) {
	static HashMap<String, LAFluidEos> cache;
	static std::mutex lock;
	const std::lock_guard<std::mutex> guard(lock);
	if (!cache.has(p_id)) {
		cache.insert(p_id, build_fluid(p_id));
	}
	return cache[p_id];
}

const LAAnchor &LAPhaseEosFn::anchor(const String &p_id) {
	static HashMap<String, LAAnchor> cache;
	static std::mutex lock;
	const std::lock_guard<std::mutex> guard(lock);
	if (!cache.has(p_id)) {
		LAAnchor a;
		a.t_c = pc("STANDARD_STATE_T_C");
		const double p = pc("STANDARD_STATE_P_PA");
		const double boil = LASubstances::boil_c_at(p_id, p);
		if (LASubstances::sublimes_at(p_id, p)) {
			a.phase = a.t_c < LASubstances::sublimation_c_at(p_id, p) ? 0 : 2;
		} else {
			const double melt = LASubstances::melt_c_at(p_id, p, 0.0);
			const bool solid_there = std::isfinite(melt) ? a.t_c <= melt : !std::isfinite(boil);
			a.phase = solid_there ? 0 : ((!std::isfinite(boil) || a.t_c <= boil) ? 1 : 2);
		}
		cache.insert(p_id, a);
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
	if (!p_c.valid) {
		return NAN;
	}
	if (p_c.iapws) {
		return la_water::iapws_melting_ih_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	return fusion_c(p_c, p_p_pa);
}

// LA_APPROX: linear_melt_lever
double LAPhaseEosFn::melt_fraction(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double solidus = solidus_c(p_c, p_p_pa);
	if (!(p_t_c > solidus)) {
		return 0.0;
	}
	return p_t_c < solidus + p_c.width ? (p_t_c - solidus) / p_c.width : 1.0;
}

// m^3/kg at (T, p): the reference volume carried by the phase's expansivity, then squeezed by its
// Birch-Murnaghan isotherm at every pressure, tension included. 0, with a named error, where the phase
// is not named or the state asks for a coefficient the table does not measure.
double LAPhaseEosFn::phase_volume(const LAPhaseEos &p_e, double p_t_c, double p_p_pa) {
	if (!(p_e.rho > 0.0)) {
		return 0.0;
	}
	const double dp = p_p_pa - pc("STANDARD_PRESSURE_PA");
	double v = 0.0;
	if (p_e.kell) {
		v = 1.0 / water_liquid_density(p_t_c);
	} else {
		const double dt = p_t_c - p_e.t_ref_c;
		ERR_FAIL_COND_V_MSG(dt != 0.0 && !p_e.has_alpha, NAN, "LAPhaseEos: a phase with no measured expansivity is "
				"asked for its volume off its reference temperature.");
		const double al = dt != 0.0 ? phase_alpha_p(p_e, p_p_pa) : 0.0;
		v = p_e.linear_density ? 1.0 / (p_e.rho * (1.0 - al * dt)) : (1.0 + al * dt) / p_e.rho;
	}
	return v * std::pow(1.0 + 2.0 * bm_strain(p_e, dp), -1.5);
}

// K_T = -V dP/dV = (1 + 2f) dP/df / 3 at the pressure's own strain; NaN where unmeasured.
double LAPhaseEosFn::phase_k_t(const LAPhaseEos &p_e, double p_p_pa) {
	ERR_FAIL_COND_V_MSG(!p_e.has_k, NAN, "LAPhaseEos: a phase with no measured bulk modulus is asked for it.");
	const double f = bm_strain(p_e, p_p_pa - pc("STANDARD_PRESSURE_PA"));
	return p_e.k * std::pow(1.0 + 2.0 * f, 2.5) * la_bm::slope(f, p_e.kp, bm_b4(p_e));
}

double LAPhaseEosFn::isothermal_modulus(double p_k_s, double p_alpha, double p_rho, double p_cp, double p_t_c) {
	return p_k_s / (1.0 + p_alpha * p_alpha * p_k_s * (p_t_c + pc("KELVIN_OFFSET")) / (p_rho * p_cp));
}

double LAPhaseEosFn::condensed_volume(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	if (!p_c.valid) {
		return 0.0;
	}
	// Past its critical point water is one fluid, Peng-Robinson's.
	if (p_c.iapws && p_t_c >= pc("WATER_CRITICAL_T_C")) {
		return pr_molar_volume(fluid("h2o"), p_t_c + pc("KELVIN_OFFSET"), p_p_pa) / pc("MOLAR_MASS_WATER_KG_MOL");
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
	ERR_FAIL_COND_V_MSG(!(v_l > 0.0), NAN, "LAPhaseEos: a melt the table names no liquid for.");
	return (1.0 - phi) * v_s + phi * v_l;
}

bool LAPhaseEosFn::representable(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double dp = p_p_pa - pc("STANDARD_PRESSURE_PA");
	auto reaches = [&](const LAPhaseEos &e) {
		return e.has_k && dp >= bm_pressure(e, e.f_lo) && (std::isinf(e.f_hi) || dp <= bm_pressure(e, e.f_hi));
	};
	const double phi = (p_c.solid.rho > 0.0) ? melt_fraction(p_c, p_t_c, p_p_pa) : 1.0;
	return (phi >= 1.0 || reaches(p_c.solid)) && (phi <= 0.0 || reaches(p_c.liquid));
}

// Each phase's own expansivity at this state, weighted by the volume it fills; the melting step is not one.
double LAPhaseEosFn::condensed_alpha(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	auto phase_alpha = [&](const LAPhaseEos &e) {
		if (e.kell) {
			const double dt = 1.0e-3;
			return std::log(water_liquid_density(p_t_c - dt) / water_liquid_density(p_t_c + dt)) / (2.0 * dt);
		}
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
	return ((phi < 1.0 ? (1.0 - phi) * v_s * phase_alpha(p_c.solid) : 0.0)
				   + (phi > 0.0 ? phi * v_l * phase_alpha(p_c.liquid) : 0.0))
			/ v;
}

double LAPhaseEosFn::condensed_compressibility(const LACondensedEos &p_c, double p_t_c, double p_p_pa) {
	const double phi = (p_c.solid.rho > 0.0) ? melt_fraction(p_c, p_t_c, p_p_pa) : 1.0;
	auto part = [&](const LAPhaseEos &e, double w) {
		if (!(w > 0.0)) {
			return 0.0;
		}
		return w * phase_volume(e, p_t_c, p_p_pa) / phase_k_t(e, p_p_pa);
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
		return room > s_b ? a_gas_rt / (room - s_b) - s_a * s_a / (room * room + 2.0 * s_b * room - s_b * s_b) : LA_NAN;
	}
	// No gas at all: condensed phases that overfill the cell are squeezed into it; a room they leave is
	// vacuum.
	if (a_gas_rt <= 0.0) {
		return b_vol > vol ? p_ref + (b_vol - vol) / c_comp : 0.0;
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
