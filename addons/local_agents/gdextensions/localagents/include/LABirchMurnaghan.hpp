#ifndef LOCAL_AGENTS_LA_BIRCH_MURNAGHAN_HPP
#define LOCAL_AGENTS_LA_BIRCH_MURNAGHAN_HPP

// Birch-Murnaghan in Eulerian strain f = ((V0/V)^(2/3) - 1)/2 (Birch 1947, Phys. Rev. 71:809; fourth order,
// Birch 1978, JGR 83:1257): P = 3 K0 f (1 + 2f)^(5/2) (1 + a f + b4 f^2), a = 3/2 (K0' - 4). Plain C++, so
// the extension and the native property tests read one declaration.

#include <cmath>
#include <limits>

namespace la_bm {

// b4 = 3/2 (K0 K0'' + (K0' - 4)(K0' - 3) + 35/9) where K0'' is declared; zero at third order.
inline double b4(double p_k0, double p_kp, double p_kpp, bool p_fourth) {
	return p_fourth ? 1.5 * (p_k0 * p_kpp + (p_kp - 4.0) * (p_kp - 3.0) + 35.0 / 9.0) : 0.0;
}

// The form over any number type with +, * and scalar products; `u52` is (1 + 2f)^(5/2) in that type.
template <typename N>
N pressure_of(const N &p_f, const N &p_u52, double p_k0, double p_kp, double p_b4) {
	return (3.0 * p_k0) * (p_f * p_u52 * (N(1.0) + (1.5 * (p_kp - 4.0)) * p_f + p_b4 * (p_f * p_f)));
}

inline double pressure(double p_f, double p_k0, double p_kp, double p_b4) {
	return pressure_of<double>(p_f, std::pow(1.0 + 2.0 * p_f, 2.5), p_k0, p_kp, p_b4);
}

// dP/df / (3 K0 (1 + 2f)^(3/2)) = 1 + (2a + 7) f + (9a + 3 b4) f^2 + 11 b4 f^3.
inline double slope(double p_f, double p_kp, double p_b4) {
	const double a = 1.5 * (p_kp - 4.0);
	return 1.0 + p_f * ((2.0 * a + 7.0) + p_f * ((9.0 * a + 3.0 * p_b4) + p_f * 11.0 * p_b4));
}

// The strain interval about f = 0 over which P(f) rises: between the nearest real zeros of dP/df on either
// side, the lower end no further than f = -1/2, where V/V0 is infinite. +inf where P rises for every f > 0.
inline void bracket(double p_kp, double p_b4, double &r_lo, double &r_hi) {
	const double a = 1.5 * (p_kp - 4.0);
	const double c0 = 1.0;
	const double c1 = 2.0 * a + 7.0;
	const double c2 = 9.0 * a + 3.0 * p_b4;
	const double c3 = 11.0 * p_b4;
	r_lo = -0.5;
	r_hi = std::numeric_limits<double>::infinity();
	auto keep = [&](double r) {
		if (!std::isfinite(r)) {
			return;
		}
		if (r > 0.0 && r < r_hi) {
			r_hi = r;
		} else if (r < 0.0 && r > r_lo) {
			r_lo = r;
		}
	};
	if (c3 != 0.0) {
		// Depressed cubic t^3 + p t + q = 0, f = t - c2 / (3 c3).
		const double b = c2 / c3;
		const double c = c1 / c3;
		const double d = c0 / c3;
		const double p = c - b * b / 3.0;
		const double q = 2.0 * b * b * b / 27.0 - b * c / 3.0 + d;
		const double disc = q * q / 4.0 + p * p * p / 27.0;
		const double shift = -b / 3.0;
		if (disc > 0.0) {
			const double s = std::sqrt(disc);
			keep(std::cbrt(-q / 2.0 + s) + std::cbrt(-q / 2.0 - s) + shift);
		} else {
			const double r = std::sqrt(-p / 3.0);
			const double phi = std::acos(std::fmax(-1.0, std::fmin(1.0, -q / (2.0 * r * r * r))));
			for (int k = 0; k < 3; k++) {
				keep(2.0 * r * std::cos((phi + 2.0 * M_PI * double(k)) / 3.0) + shift);
			}
		}
	} else if (c2 != 0.0) {
		const double disc = c1 * c1 - 4.0 * c2 * c0;
		if (disc >= 0.0) {
			keep((-c1 + std::sqrt(disc)) / (2.0 * c2));
			keep((-c1 - std::sqrt(disc)) / (2.0 * c2));
		}
	} else if (c1 != 0.0) {
		keep(-c0 / c1);
	}
}

} // namespace la_bm

#endif
