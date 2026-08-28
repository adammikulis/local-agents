#include "LAGridGeometry.hpp"
#include "LAGravitySolve.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <cstdint>
#include <vector>

using namespace godot;

Dictionary LAGravitySolve::solve(Object *p_grid, const PackedFloat32Array &p_density,
		const PackedFloat32Array &p_phi, const PackedByteArray &p_flag_bytes, double p_g_si,
		double p_tol_rel, int p_max_iter, const PackedFloat32Array &p_moments) {
	Dictionary out;
	if (!p_grid || p_moments.size() < 4) {
		return out;
	}
	const int cc = int(p_grid->get("cell_count"));
	const PackedInt32Array slot_off = p_grid->get("slot_off");
	const PackedInt32Array nbr = p_grid->get("neighbours");
	const PackedByteArray levels = p_grid->get("levels");
	const double base = double(p_grid->get("cell_size"));
	if (cc <= 0 || p_density.size() < cc || p_phi.size() < cc || p_flag_bytes.size() < cc * 4
			|| slot_off.size() < cc * 7) {
		return out;
	}
	// Edges once, then the operator in CSR: interior rows only; a ring cell keeps its seeded value.
	std::vector<float> edge(cc);
	for (int c = 0; c < cc; c++) {
		edge[c] = float(base * std::pow(0.5, double(c < levels.size() ? levels[c] : 0)));
	}
	const uint32_t *flags = reinterpret_cast<const uint32_t *>(p_flag_bytes.ptr());
	std::vector<char> ring(cc);
	for (int c = 0; c < cc; c++) {
		ring[c] = (flags[c] & 1u) != 0u ? 1 : 0;
	}
	std::vector<int> row_off(cc + 1, 0);
	for (int c = 0; c < cc; c++) {
		row_off[c + 1] = row_off[c] + (slot_off[c * 7 + 6] - slot_off[c * 7]);
	}
	std::vector<int> col(row_off[cc]);
	std::vector<float> w(row_off[cc]);
	std::vector<double> diag(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		int k = row_off[c];
		for (int f = slot_off[c * 7]; f < slot_off[c * 7 + 6]; f++, k++) {
			const int m = nbr[f];
			col[k] = m;
			if (m < 0 || m >= cc) {
				w[k] = 0.0f;
				continue;
			}
			const float s = std::min(edge[c], edge[m]);
			w[k] = s * s / (0.5f * (edge[c] + edge[m]));
			diag[c] += double(w[k]);
		}
	}
	// The monopole reference in double, phi the DEVIATION from it: sum_f w (dphi_nb - dphi_c) = src - sum_f w (ref_nb - ref_c) on
	// the interior, dphi = 0 on the ring. L phi = -sum_f w (phi_nb - phi_c) is SPD there.
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(p_grid);
	const double total = double(p_moments[0]);
	const Vector3 com(p_moments[1], p_moments[2], p_moments[3]);
	std::vector<double> ref(cc, 0.0);
	if (total > 0.0 && cw.size() >= cc) {
		for (int c = 0; c < cc; c++) {
			const double r = std::max(std::hypot(cw[c * 3] - double(com.x), cw[c * 3 + 1] - double(com.y), cw[c * 3 + 2] - double(com.z)), double(edge[c]));
			ref[c] = -p_g_si * total / r;
		}
	}
	const double four_pi_g = 4.0 * std::acos(-1.0) * p_g_si;
	std::vector<double> phi(cc), rhs(cc, 0.0), src(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		phi[c] = ring[c] ? 0.0 : double(p_phi[c]);
		const double v = double(edge[c]) * double(edge[c]) * double(edge[c]);
		src[c] = four_pi_g * double(p_density[c]) * v;
	}
	double src_max = 0.0;
	for (int c = 0; c < cc; c++) {
		if (ring[c]) {
			continue;
		}
		double b = -src[c];
		for (int k = row_off[c]; k < row_off[c + 1]; k++) {
			const int m = col[k];
			if (m >= 0) {
				b += double(w[k]) * (ref[m] - ref[c]);
			}
		}
		rhs[c] = b;
		const double v = double(edge[c]) * double(edge[c]) * double(edge[c]);
		src_max = std::max(src_max, std::abs(src[c]) / v);
	}
	auto apply = [&](const std::vector<double> &x, std::vector<double> &y) {
		for (int c = 0; c < cc; c++) {
			if (ring[c]) {
				y[c] = 0.0;
				continue;
			}
			double acc = diag[c] * x[c];
			for (int k = row_off[c]; k < row_off[c + 1]; k++) {
				const int m = col[k];
				if (m >= 0 && !ring[m]) {
					acc -= double(w[k]) * x[m];
				}
			}
			y[c] = acc;
		}
	};
	auto residual_rel = [&]() {
		double worst = 0.0;
		for (int c = 0; c < cc; c++) {
			if (ring[c]) {
				continue;
			}
			double acc = -diag[c] * (phi[c] + ref[c]);
			for (int k = row_off[c]; k < row_off[c + 1]; k++) {
				const int m = col[k];
				if (m >= 0) {
					acc += double(w[k]) * (phi[m] + ref[m]);
				}
			}
			const double v = double(edge[c]) * double(edge[c]) * double(edge[c]);
			worst = std::max(worst, std::abs(acc - src[c]) / v);
		}
		return src_max > 0.0 ? worst / src_max : 0.0;
	};
	// Jacobi-preconditioned conjugate gradient from the warm start.
	std::vector<double> r(cc), z(cc), p(cc), q(cc);
	apply(phi, q);
	for (int c = 0; c < cc; c++) {
		r[c] = ring[c] ? 0.0 : rhs[c] - q[c];
		z[c] = ring[c] || diag[c] <= 0.0 ? 0.0 : r[c] / diag[c];
		p[c] = z[c];
	}
	double rz = 0.0;
	for (int c = 0; c < cc; c++) {
		rz += r[c] * z[c];
	}
	int it = 0;
	double rel = residual_rel();
	while (rel > p_tol_rel && it < p_max_iter && rz > 0.0) {
		apply(p, q);
		double pq = 0.0;
		for (int c = 0; c < cc; c++) {
			pq += p[c] * q[c];
		}
		if (!(pq > 0.0)) {
			break;
		}
		const double alpha = rz / pq;
		for (int c = 0; c < cc; c++) {
			phi[c] += alpha * p[c];
			r[c] -= alpha * q[c];
		}
		double rz_next = 0.0;
		for (int c = 0; c < cc; c++) {
			z[c] = ring[c] || diag[c] <= 0.0 ? 0.0 : r[c] / diag[c];
			rz_next += r[c] * z[c];
		}
		const double beta = rz_next / rz;
		rz = rz_next;
		for (int c = 0; c < cc; c++) {
			p[c] = z[c] + beta * p[c];
		}
		it++;
		if (it % 8 == 0) {
			rel = residual_rel();
		}
	}
	rel = residual_rel();
	PackedFloat32Array phi_out;
	phi_out.resize(cc);
	float *pw = phi_out.ptrw();
	for (int c = 0; c < cc; c++) {
		pw[c] = float(phi[c]);
	}
	out["phi"] = phi_out;
	out["residual_rel"] = rel;
	out["iterations"] = it;
	return out;
}

Dictionary LAGravitySolve::solve_device(RenderingDevice *p_rd, Object *p_grid, const RID &p_density,
		const RID &p_phi, const RID &p_flags, const RID &p_moments, double p_g_si, double p_tol_rel,
		int p_max_iter) {
	Dictionary out;
	if (!p_rd || !p_grid) {
		return out;
	}
	const PackedFloat32Array density = p_rd->buffer_get_data(p_density).to_float32_array();
	const PackedFloat32Array phi = p_rd->buffer_get_data(p_phi).to_float32_array();
	const PackedByteArray flags = p_rd->buffer_get_data(p_flags);
	const PackedFloat32Array moments = p_rd->buffer_get_data(p_moments).to_float32_array();
	Dictionary r = solve(p_grid, density, phi, flags, p_g_si, p_tol_rel, p_max_iter, moments);
	if (r.is_empty()) {
		return out;
	}
	const PackedByteArray bytes = PackedFloat32Array(r["phi"]).to_byte_array();
	p_rd->buffer_update(p_phi, 0, bytes.size(), bytes);
	out["residual_rel"] = r["residual_rel"];
	out["iterations"] = r["iterations"];
	return out;
}

// The full potential per cell in double: the device's deviation plus the monopole reference the solve
// stated it against, from the same double centres.
PackedFloat64Array LAGravitySolve::phi_abs(Object *p_grid, const PackedFloat32Array &p_dev,
		const PackedFloat32Array &p_moments, double p_g_si) {
	PackedFloat64Array out;
	if (!p_grid || p_moments.size() < 4) {
		return out;
	}
	const PackedFloat64Array cw = LAGridGeometry::centres_f64(p_grid);
	const PackedFloat32Array edge = p_grid->call("cell_edges");
	const int cc = p_dev.size();
	if (cw.size() != cc * 3 || edge.size() < cc) {
		return out;
	}
	const double total = double(p_moments[0]);
	const double cx = p_moments[1], cy = p_moments[2], cz = p_moments[3];
	out.resize(cc);
	double *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		const double r = std::max(std::hypot(cw[c * 3] - cx, cw[c * 3 + 1] - cy, cw[c * 3 + 2] - cz), double(edge[c]));
		w[c] = double(p_dev[c]) + (total > 0.0 ? -p_g_si * total / r : 0.0);
	}
	return out;
}

void LAGravitySolve::_bind_methods() {
	ClassDB::bind_static_method("LAGravitySolve", D_METHOD("phi_abs", "grid", "dev", "moments", "g_si"), &LAGravitySolve::phi_abs);
	ClassDB::bind_static_method("LAGravitySolve",
			D_METHOD("solve_device", "rd", "grid", "density", "phi", "flags", "moments", "g_si", "tol_rel", "max_iter"),
			&LAGravitySolve::solve_device);
	ClassDB::bind_static_method("LAGravitySolve",
			D_METHOD("solve", "grid", "density", "phi", "flag_bytes", "g_si", "tol_rel", "max_iter", "moments"),
			&LAGravitySolve::solve);
}
