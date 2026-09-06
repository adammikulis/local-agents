#include "LAAcousticSolve.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cmath>
#include <vector>

using namespace godot;

Dictionary LAAcousticSolve::solve(const PackedInt32Array &p_slot_off, const PackedInt32Array &p_nbr,
		const PackedFloat32Array &p_comp, const PackedFloat32Array &p_cond,
		const PackedFloat32Array &p_rhs, const PackedFloat32Array &p_p, double p_dt_s,
		double p_tol_rel, int p_max_iter) {
	Dictionary out;
	const int cc = p_comp.size();
	const PackedInt32Array &slot_off = p_slot_off;
	const PackedInt32Array &nbr = p_nbr;
	if (!(p_dt_s > 0.0) || cc <= 0 || p_rhs.size() < cc || p_p.size() < cc
			|| slot_off.size() < cc * 7) {
		return out;
	}
	const double dt2 = p_dt_s * p_dt_s;
	// The operator in CSR: one row per interior cell, the face conductance the predictor wrote.
	std::vector<int> row_off(cc + 1, 0);
	for (int c = 0; c < cc; c++) {
		row_off[c + 1] = row_off[c] + (slot_off[c * 7 + 6] - slot_off[c * 7]);
	}
	if (p_cond.size() < row_off[cc]) {
		return out;
	}
	std::vector<int> col(row_off[cc]);
	std::vector<double> w(row_off[cc], 0.0);
	std::vector<double> diag(cc, 0.0);
	for (int c = 0; c < cc; c++) {
		int k = row_off[c];
		double acc = double(p_comp[c]);
		for (int f = slot_off[c * 7]; f < slot_off[c * 7 + 6]; f++, k++) {
			const int m = nbr[f];
			const double a = dt2 * double(p_cond[f]);
			// A face onto vacuum, onto a ghost tail cell or onto a wall holds the neighbour at zero,
			// so it lands on the diagonal alone. Its conductance is zero where nothing crosses.
			col[k] = (m >= 0 && m < cc) ? m : -1;
			w[k] = a;
			acc += a;
		}
		diag[c] = acc;
	}
	std::vector<double> p(cc), rhs(cc), r(cc), z(cc), d(cc), q(cc);
	double rhs_max = 0.0;
	int broken = -1;
	for (int c = 0; c < cc; c++) {
		const bool live = diag[c] > 0.0;
		p[c] = live ? double(p_p[c]) : 0.0;
		rhs[c] = live ? double(p_rhs[c]) : 0.0;
		if (live && !std::isfinite(rhs[c] + p[c] + diag[c])) {
			broken = c;
			break;
		}
		rhs_max = std::max(rhs_max, std::abs(rhs[c]));
	}
	// A ROW THAT IS NOT A NUMBER IS NOT A ROW THAT FAILED TO CONVERGE. The state handed to the solve
	// is broken; saying so names the cell instead of reporting a residual nobody can act on.
	if (broken >= 0) {
		out["nonfinite_cell"] = broken;
		return out;
	}
	auto apply = [&](const std::vector<double> &x, std::vector<double> &y) {
		for (int c = 0; c < cc; c++) {
			if (!(diag[c] > 0.0)) {
				y[c] = 0.0;
				continue;
			}
			double acc = diag[c] * x[c];
			for (int k = row_off[c]; k < row_off[c + 1]; k++) {
				if (col[k] >= 0 && diag[col[k]] > 0.0) {
					acc -= w[k] * x[col[k]];
				}
			}
			y[c] = acc;
		}
	};
	auto residual_rel = [&]() {
		apply(p, q);
		double worst = 0.0;
		for (int c = 0; c < cc; c++) {
			worst = std::max(worst, std::abs(q[c] - rhs[c]));
		}
		return rhs_max > 0.0 ? worst / rhs_max : 0.0;
	};
	apply(p, q);
	double rz = 0.0;
	for (int c = 0; c < cc; c++) {
		r[c] = rhs[c] - q[c];
		z[c] = diag[c] > 0.0 ? r[c] / diag[c] : 0.0;
		d[c] = z[c];
		rz += r[c] * z[c];
	}
	int it = 0;
	double rel = residual_rel();
	while (rel > p_tol_rel && it < p_max_iter && rz > 0.0) {
		apply(d, q);
		double dq = 0.0;
		for (int c = 0; c < cc; c++) {
			dq += d[c] * q[c];
		}
		if (!(dq > 0.0)) {
			break;
		}
		const double alpha = rz / dq;
		for (int c = 0; c < cc; c++) {
			p[c] += alpha * d[c];
			r[c] -= alpha * q[c];
		}
		double rz_next = 0.0;
		for (int c = 0; c < cc; c++) {
			z[c] = diag[c] > 0.0 ? r[c] / diag[c] : 0.0;
			rz_next += r[c] * z[c];
		}
		const double beta = rz_next / rz;
		rz = rz_next;
		for (int c = 0; c < cc; c++) {
			d[c] = z[c] + beta * d[c];
		}
		it++;
		if (it % 8 == 0) {
			rel = residual_rel();
		}
	}
	rel = residual_rel();
	PackedFloat32Array p_out;
	p_out.resize(cc);
	float *pw = p_out.ptrw();
	for (int c = 0; c < cc; c++) {
		pw[c] = float(p[c]);
	}
	out["p"] = p_out;
	out["residual_rel"] = rel;
	out["iterations"] = it;
	return out;
}

Dictionary LAAcousticSolve::solve_device(RenderingDevice *p_rd, const RID &p_slot_off,
		const RID &p_nbr, int p_cell_count, const RID &p_comp, const RID &p_cond, const RID &p_rhs,
		const RID &p_p, double p_dt_s, double p_tol_rel, int p_max_iter) {
	Dictionary out;
	if (!p_rd || p_cell_count <= 0) {
		return out;
	}
	const PackedInt32Array slot_off = p_rd->buffer_get_data(p_slot_off).to_int32_array();
	const PackedInt32Array nbr = p_rd->buffer_get_data(p_nbr).to_int32_array();
	PackedFloat32Array comp = p_rd->buffer_get_data(p_comp).to_float32_array();
	comp.resize(p_cell_count);
	const PackedFloat32Array cond = p_rd->buffer_get_data(p_cond).to_float32_array();
	const PackedFloat32Array rhs = p_rd->buffer_get_data(p_rhs).to_float32_array();
	const PackedFloat32Array warm = p_rd->buffer_get_data(p_p).to_float32_array();
	Dictionary r = solve(slot_off, nbr, comp, cond, rhs, warm, p_dt_s, p_tol_rel, p_max_iter);
	if (r.is_empty()) {
		return out;
	}
	const PackedByteArray bytes = PackedFloat32Array(r["p"]).to_byte_array();
	p_rd->buffer_update(p_p, 0, bytes.size(), bytes);
	out["residual_rel"] = r["residual_rel"];
	out["iterations"] = r["iterations"];
	return out;
}

void LAAcousticSolve::_bind_methods() {
	ClassDB::bind_static_method("LAAcousticSolve",
			D_METHOD("solve", "slot_off", "nbr", "comp", "cond", "rhs", "p", "dt_s", "tol_rel",
					"max_iter"),
			&LAAcousticSolve::solve);
	ClassDB::bind_static_method("LAAcousticSolve",
			D_METHOD("solve_device", "rd", "slot_off", "nbr", "cell_count", "comp", "cond", "rhs", "p",
					"dt_s", "tol_rel", "max_iter"),
			&LAAcousticSolve::solve_device);
}
