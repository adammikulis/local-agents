#include "LAWaterCurves.hpp"

#include "LAPhysicalRead.hpp"

#include <cmath>

namespace {

double pc(const char *p_name) {
	return godot::la_physical(p_name);
}

// Wagner & Pruss 2002, J. Phys. Chem. Ref. Data 31:387, eq. 2.5.
constexpr double PSAT_A1 = -7.85951783;
constexpr double PSAT_A2 = 1.84408259;
constexpr double PSAT_A3 = -11.7866497;
constexpr double PSAT_A4 = 22.6807411;
constexpr double PSAT_A5 = -15.9618719;
constexpr double PSAT_A6 = 1.80122502;
// IAPWS 2011, revised release R14-08, J. Phys. Chem. Ref. Data 40:043103: sublimation over ice Ih from
// 50 K to the triple point.
constexpr double SUBL_A1 = -0.212144006e2;
constexpr double SUBL_A2 = 0.273203819e2;
constexpr double SUBL_A3 = -0.610598130e1;
constexpr double SUBL_B1 = 0.333333333e-2;
constexpr double SUBL_B2 = 0.120666667e1;
constexpr double SUBL_B3 = 0.170333333e1;
constexpr double SUBL_MIN_T_C = -223.15;
// IAPWS 2011, R14-08: the melting curve of ice Ih, and the ice Ih/III/liquid triple point it ends at.
constexpr double MELT_IH_A1 = 0.119539337e7;
constexpr double MELT_IH_A2 = 0.808183159e5;
constexpr double MELT_IH_A3 = 0.333826860e4;
constexpr double MELT_IH_B1 = 0.300000e1;
constexpr double MELT_IH_B2 = 0.257500e2;
constexpr double MELT_IH_B3 = 0.103750e3;
constexpr double ICE_IH_MIN_MELT_T_C = -21.985;
constexpr double ICE_IH_MAX_MELT_P_PA = 2.08566e8;

// Each boundary is inverted by Newton on its own analytic derivative from a seed built out of the same
// equation, so no second curve enters and this is the only knob the solve has.
// The walk stops when the iterate stops moving: the float beside it holds nothing more, so every
// further evaluation of the series is spent for nothing.
constexpr int NEWTON_STEPS = 6;

double clamp_to(double p_x, double p_lo, double p_hi) {
	return p_x < p_lo ? p_lo : (p_x > p_hi ? p_hi : p_x);
}

double critical_t_k() {
	return pc("WATER_CRITICAL_T_C") + pc("KELVIN_OFFSET");
}

double triple_t_k() {
	return pc("WATER_TRIPLE_T_C") + pc("KELVIN_OFFSET");
}

// sum a_i theta^n_i of the saturation equation, and its derivative in theta.
double psat_series(double p_th) {
	return PSAT_A1 * p_th + PSAT_A2 * std::pow(p_th, 1.5) + PSAT_A3 * std::pow(p_th, 3.0)
			+ PSAT_A4 * std::pow(p_th, 3.5) + PSAT_A5 * std::pow(p_th, 4.0)
			+ PSAT_A6 * std::pow(p_th, 7.5);
}

double psat_series_d(double p_th) {
	return PSAT_A1 + 1.5 * PSAT_A2 * std::pow(p_th, 0.5) + 3.0 * PSAT_A3 * std::pow(p_th, 2.0)
			+ 3.5 * PSAT_A4 * std::pow(p_th, 2.5) + 4.0 * PSAT_A5 * std::pow(p_th, 3.0)
			+ 7.5 * PSAT_A6 * std::pow(p_th, 6.5);
}

// sum a_i theta^b_i of the sublimation equation, and the theta-derivative of theta^-1 times it.
double subl_series(double p_th) {
	return SUBL_A1 * std::pow(p_th, SUBL_B1) + SUBL_A2 * std::pow(p_th, SUBL_B2)
			+ SUBL_A3 * std::pow(p_th, SUBL_B3);
}

double subl_series_d(double p_th) {
	return SUBL_A1 * (SUBL_B1 - 1.0) * std::pow(p_th, SUBL_B1 - 2.0)
			+ SUBL_A2 * (SUBL_B2 - 1.0) * std::pow(p_th, SUBL_B2 - 2.0)
			+ SUBL_A3 * (SUBL_B3 - 1.0) * std::pow(p_th, SUBL_B3 - 2.0);
}

// sum a_i (1 - theta^b_i) of the ice Ih melting equation, and its derivative in theta.
double melt_series(double p_th) {
	return MELT_IH_A1 * (1.0 - std::pow(p_th, MELT_IH_B1))
			+ MELT_IH_A2 * (1.0 - std::pow(p_th, MELT_IH_B2))
			+ MELT_IH_A3 * (1.0 - std::pow(p_th, MELT_IH_B3));
}

double melt_series_d(double p_th) {
	return -(MELT_IH_A1 * MELT_IH_B1 * std::pow(p_th, MELT_IH_B1 - 1.0)
			+ MELT_IH_A2 * MELT_IH_B2 * std::pow(p_th, MELT_IH_B2 - 1.0)
			+ MELT_IH_A3 * MELT_IH_B3 * std::pow(p_th, MELT_IH_B3 - 1.0));
}

} // namespace

namespace la_water {

// Every coefficient the three equations use, as scalar properties of water. scripts/dump_substances.gd
// publishes them, so scripts/check_physical_constants.sh holds each kernel copy to the built table.
void declare_iapws(godot::Dictionary &p_row) {
	p_row["iapws"] = true;
	p_row["iapws_psat_a1"] = PSAT_A1;
	p_row["iapws_psat_a2"] = PSAT_A2;
	p_row["iapws_psat_a3"] = PSAT_A3;
	p_row["iapws_psat_a4"] = PSAT_A4;
	p_row["iapws_psat_a5"] = PSAT_A5;
	p_row["iapws_psat_a6"] = PSAT_A6;
	p_row["iapws_subl_a1"] = SUBL_A1;
	p_row["iapws_subl_a2"] = SUBL_A2;
	p_row["iapws_subl_a3"] = SUBL_A3;
	p_row["iapws_subl_b1"] = SUBL_B1;
	p_row["iapws_subl_b2"] = SUBL_B2;
	p_row["iapws_subl_b3"] = SUBL_B3;
	p_row["iapws_subl_min_t_c"] = SUBL_MIN_T_C;
	p_row["iapws_melt_ih_a1"] = MELT_IH_A1;
	p_row["iapws_melt_ih_a2"] = MELT_IH_A2;
	p_row["iapws_melt_ih_a3"] = MELT_IH_A3;
	p_row["iapws_melt_ih_b1"] = MELT_IH_B1;
	p_row["iapws_melt_ih_b2"] = MELT_IH_B2;
	p_row["iapws_melt_ih_b3"] = MELT_IH_B3;
	p_row["ice_ih_min_melt_t_c"] = ICE_IH_MIN_MELT_T_C;
	p_row["ice_ih_max_melt_p_pa"] = ICE_IH_MAX_MELT_P_PA;
}

// The IAPWS-95 saturation-pressure equation: ln(p/p_c) = (T_c/T) sum a_i theta^n_i, theta = 1 - T/T_c.
double iapws_saturation_p_pa(double p_t_k) {
	const double tc = critical_t_k();
	const double t_k = p_t_k > 1.0 ? p_t_k : 1.0;
	const double th = t_k < tc ? 1.0 - t_k / tc : 0.0;
	return pc("WATER_CRITICAL_P_PA") * std::exp(tc / t_k * psat_series(th));
}

// d ln p_sat / dT, 1/K.
double iapws_saturation_dln_dt(double p_t_k) {
	const double tc = critical_t_k();
	const double t_k = p_t_k > 1.0 ? p_t_k : 1.0;
	const double th = t_k < tc ? 1.0 - t_k / tc : 0.0;
	return -tc * psat_series(th) / (t_k * t_k) - psat_series_d(th) / t_k;
}

// The saturation curve read the other way. Seeded on the chord of the curve's own two ends in
// (1/T, ln p), where the liquid-vapour boundary is nearly straight; the curve ends at the triple point
// below and at the critical point above, where the two phases are one.
double iapws_saturation_t_k(double p_p_pa) {
	const double tc = critical_t_k();
	const double t3 = triple_t_k();
	const double p3 = pc("WATER_TRIPLE_P_PA");
	const double p_crit = pc("WATER_CRITICAL_P_PA");
	if (p_p_pa >= p_crit) {
		return tc;
	}
	if (p_p_pa <= p3) {
		return t3;
	}
	const double f = std::log(p_p_pa / p3) / std::log(p_crit / p3);
	double t_k = 1.0 / (1.0 / t3 + f * (1.0 / tc - 1.0 / t3));
	const double target = std::log(p_p_pa);
	for (int i = 0; i < NEWTON_STEPS; i++) {
		const double d = iapws_saturation_dln_dt(t_k);
		if (!(d > 0.0)) {
			break;
		}
		const double prev = t_k;
		t_k = clamp_to(t_k - (std::log(iapws_saturation_p_pa(t_k)) - target) / d, t3, tc);
		if (t_k == prev) {
			break;
		}
	}
	return t_k;
}

// The sublimation-pressure equation over ice Ih: ln(p/p_t) = theta^-1 sum a_i theta^b_i, theta = T/T_t.
double iapws_sublimation_p_pa(double p_t_k) {
	const double th = (p_t_k > 1.0 ? p_t_k : 1.0) / triple_t_k();
	return pc("WATER_TRIPLE_P_PA") * std::exp(subl_series(th) / th);
}

// d ln p_subl / dT, 1/K.
double iapws_sublimation_dln_dt(double p_t_k) {
	const double t3 = triple_t_k();
	return subl_series_d((p_t_k > 1.0 ? p_t_k : 1.0) / t3) / t3;
}

// The frost point: the sublimation curve read as a temperature, over the equation's own range, seeded
// on the chord between its two ends in (1/T, ln p). The solid-vapour boundary ends at the triple point.
double iapws_sublimation_t_k(double p_p_pa) {
	const double t3 = triple_t_k();
	const double p3 = pc("WATER_TRIPLE_P_PA");
	const double t_lo = SUBL_MIN_T_C + pc("KELVIN_OFFSET");
	if (p_p_pa >= p3) {
		return t3;
	}
	const double p_lo = iapws_sublimation_p_pa(t_lo);
	if (p_p_pa <= p_lo) {
		return t_lo;
	}
	const double f = std::log(p_p_pa / p_lo) / std::log(p3 / p_lo);
	double t_k = 1.0 / (1.0 / t_lo + f * (1.0 / t3 - 1.0 / t_lo));
	const double target = std::log(p_p_pa);
	for (int i = 0; i < NEWTON_STEPS; i++) {
		const double d = iapws_sublimation_dln_dt(t_k);
		if (!(d > 0.0)) {
			break;
		}
		const double prev = t_k;
		t_k = clamp_to(t_k - (std::log(iapws_sublimation_p_pa(t_k)) - target) / d, t_lo, t3);
		if (t_k == prev) {
			break;
		}
	}
	return t_k;
}

// The melting-pressure equation for ice Ih: p/p_t = 1 + sum a_i (1 - theta^b_i), theta = T/T_t.
double iapws_melting_ih_p_pa(double p_t_k) {
	return pc("WATER_TRIPLE_P_PA") * (1.0 + melt_series(p_t_k / triple_t_k()));
}

// Its slope, Pa/K. Negative: ice Ih is less dense than the water it melts to, so load melts it.
double iapws_melting_ih_pa_per_k(double p_t_k) {
	const double t3 = triple_t_k();
	return pc("WATER_TRIPLE_P_PA") * melt_series_d(p_t_k / t3) / t3;
}

// The melting curve read as a temperature, seeded on its own slope at the triple point. Below the
// triple-point pressure ice has no liquid to melt to, so the curve ends there.
// LA_APPROX: ice_ih_only_solid
double iapws_melting_ih_t_k(double p_p_pa) {
	const double t3 = triple_t_k();
	const double p3 = pc("WATER_TRIPLE_P_PA");
	const double t_min = ICE_IH_MIN_MELT_T_C + pc("KELVIN_OFFSET");
	if (p_p_pa >= ICE_IH_MAX_MELT_P_PA) {
		return t_min;
	}
	if (p_p_pa <= p3) {
		return t3;
	}
	double t_k = t3 + (p_p_pa - p3) / iapws_melting_ih_pa_per_k(t3);
	for (int i = 0; i < NEWTON_STEPS; i++) {
		const double d = iapws_melting_ih_pa_per_k(t_k);
		if (!(d < 0.0)) {
			break;
		}
		const double prev = t_k;
		t_k = clamp_to(t_k - (iapws_melting_ih_p_pa(t_k) - p_p_pa) / d, t_min, t3);
		if (t_k == prev) {
			break;
		}
	}
	return t_k;
}

} // namespace la_water
