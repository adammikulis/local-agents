#include "LAGridGeometry.hpp"
#include "LAGravityPotential.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

// The full potential per cell in double: the device's deviation plus the reference sphere the solve
// stated it against — gravity_ref.glsli's la_gref — from the same double centres.
PackedFloat64Array LAGravityPotential::phi_abs(Object *p_grid, const PackedFloat32Array &p_dev,
		const PackedFloat32Array &p_moments, double p_g_si) {
	PackedFloat64Array out;
	if (!p_grid || p_moments.size() < 8) {
		return out;
	}
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(p_grid);
	const int cc = p_dev.size();
	if (cw.size() != cc * 3) {
		return out;
	}
	const double total = double(p_moments[0]);
	const double cx = p_moments[1], cy = p_moments[2], cz = p_moments[3];
	const double req = std::max(double(p_moments[7]), 1.0e-30);
	out.resize(cc);
	double *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		const double r = std::hypot(cw[c * 3] - cx, cw[c * 3 + 1] - cy, cw[c * 3 + 2] - cz);
		const double ref = r >= req ? -p_g_si * total / std::max(r, 1.0e-30)
									: -p_g_si * total * (3.0 * req * req - r * r) / (2.0 * req * req * req);
		w[c] = double(p_dev[c]) + (total > 0.0 ? ref : 0.0);
	}
	return out;
}

void LAGravityPotential::_bind_methods() {
	ClassDB::bind_static_method("LAGravityPotential",
			D_METHOD("phi_abs", "grid", "dev", "moments", "g_si"), &LAGravityPotential::phi_abs);
}
