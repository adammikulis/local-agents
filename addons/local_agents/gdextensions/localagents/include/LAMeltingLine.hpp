#ifndef LOCAL_AGENTS_LA_MELTING_LINE_HPP
#define LOCAL_AGENTS_LA_MELTING_LINE_HPP

// A melting line T_m(p), plain C++ so the extension and the native property tests read one declaration.
// Kernel twin la_fusion_c in enthalpy.glsli.
//   0 Clapeyron   T = T_ref + a1 (p - p0), a1 in K/Pa
//   1 Simon       p = p0 + a1 ((T/T0)^c1 - 1)
//   2 reduced     p = p0 (1 + a1 th^c1 + a2 th^c2),                   th = T/T0 - 1
//   3 reduced     p = p0 (1 + a1 ((T/T0)^c1 - 1) + a2 ((T/T0)^c2 - 1))
// Below `p_ref` the line has not begun and the solid meets the liquid at T_ref.

#include <cmath>
#include <limits>

namespace la_melt_line {

// Newton steps; a line that has not converged by then states no temperature.
constexpr int STEPS = 20;

inline double temperature_k(int p_kind, double p_t_ref_k, double p_p_ref, double p_t0, double p_p0, double p_a1,
		double p_c1, double p_a2, double p_c2, double p_p) {
	if (p_p <= p_p_ref) {
		return p_t_ref_k;
	}
	if (p_kind == 0) {
		return p_t_ref_k + p_a1 * (p_p - p_p0);
	}
	if (p_kind == 1) {
		return p_t0 * std::pow((p_p - p_p0) / p_a1 + 1.0, 1.0 / p_c1);
	}
	// x = th (kind 2) or T/T0 - 1 inside the powers (kind 3); y = a1 g1(x) + a2 g2(x), g rising in x.
	const double y = p_p / p_p0 - 1.0;
	auto g = [&](double x, double c) { return p_kind == 2 ? std::pow(x, c) : std::pow(1.0 + x, c) - 1.0; };
	auto dg = [&](double x, double c) { return c * std::pow(p_kind == 2 ? x : 1.0 + x, c - 1.0); };
	double x = p_kind == 2 ? std::pow(y / p_a1, 1.0 / p_c1) : std::pow(1.0 + y / p_a1, 1.0 / p_c1) - 1.0;
	for (int i = 0; i < STEPS; ++i) {
		const double f = p_a1 * g(x, p_c1) + p_a2 * g(x, p_c2) - y;
		const double d = p_a1 * dg(x, p_c1) + p_a2 * dg(x, p_c2);
		const double step = f / d;
		x -= step;
		if (std::abs(step) <= 4.0 * std::numeric_limits<double>::epsilon() * (1.0 + std::abs(x))) {
			return p_t0 * (1.0 + x);
		}
	}
	return std::numeric_limits<double>::quiet_NaN();
}

} // namespace la_melt_line

#endif
