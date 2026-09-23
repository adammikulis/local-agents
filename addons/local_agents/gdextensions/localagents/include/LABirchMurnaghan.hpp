#ifndef LOCAL_AGENTS_LA_BIRCH_MURNAGHAN_HPP
#define LOCAL_AGENTS_LA_BIRCH_MURNAGHAN_HPP

// Birch-Murnaghan in Eulerian strain f = ((V0/V)^(2/3) - 1)/2 (Birch 1947, Phys. Rev. 71:809; fourth order,
// Birch 1978, JGR 83:1257): P = 3 K0 f (1 + 2f)^(5/2) (1 + a f + b4 f^2), a = 3/2 (K0' - 4). Plain C++, so
// the extension and the native property tests read one declaration.

#include <cmath>

namespace la_bm {

// b4 = 3/2 (K0 K0'' + (K0' - 4)(K0' - 3) + 35/9) where K0'' is declared; zero at third order.
inline double b4(double p_k0, double p_kp, double p_kpp, bool p_fourth) {
	return p_fourth ? 1.5 * (p_k0 * p_kpp + (p_kp - 4.0) * (p_kp - 3.0) + 35.0 / 9.0) : 0.0;
}

inline double pressure(double p_f, double p_k0, double p_kp, double p_b4) {
	return 3.0 * p_k0 * p_f * std::pow(1.0 + 2.0 * p_f, 2.5) * (1.0 + 1.5 * (p_kp - 4.0) * p_f + p_b4 * p_f * p_f);
}

// dP/df / (3 K0 (1 + 2f)^(3/2)).
inline double slope(double p_f, double p_kp, double p_b4) {
	const double a = 1.5 * (p_kp - 4.0);
	const double u = 1.0 + 2.0 * p_f;
	return (u + 5.0 * p_f) * (1.0 + a * p_f + p_b4 * p_f * p_f) + p_f * u * (a + 2.0 * p_b4 * p_f);
}

// The strain interval about f = 0 over which P(f) rises; past its ends the form is not invertible.
inline void bracket(double p_kp, double p_b4, double &r_lo, double &r_hi) {
	r_lo = -0.45;
	r_hi = 1.5;
	const double step = 1.0e-4;
	for (double f = step; f <= 1.5; f += step) {
		if (slope(f, p_kp, p_b4) <= 0.0) {
			r_hi = f - step;
			break;
		}
	}
	for (double f = -step; f >= -0.45; f -= step) {
		if (slope(f, p_kp, p_b4) <= 0.0) {
			r_lo = f + step;
			break;
		}
	}
}

} // namespace la_bm

#endif
