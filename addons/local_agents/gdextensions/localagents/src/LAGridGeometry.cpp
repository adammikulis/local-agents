#include "LAGridGeometry.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cmath>

using namespace godot;

namespace {

// Cell count plus the ghost tail: the length of every per-cell table.
int total_cells(Object *p_grid) {
	return int(p_grid->get("cell_count")) + int(p_grid->get("ghost_rows"));
}

double edge_of(double p_base, int p_level) {
	return p_base * std::pow(0.5, double(p_level));
}

} // namespace

PackedFloat32Array LAGridGeometry::edges(Object *p_grid) {
	PackedFloat32Array out;
	if (!p_grid) {
		return out;
	}
	const PackedByteArray levels = p_grid->get("levels");
	const double base = double(p_grid->get("cell_size"));
	const int n = total_cells(p_grid);
	out.resize(n);
	float *w = out.ptrw();
	for (int c = 0; c < n; c++) {
		w[c] = float(edge_of(base, c < levels.size() ? int(levels[c]) : 0));
	}
	return out;
}

PackedFloat32Array LAGridGeometry::volumes(Object *p_grid) {
	PackedFloat32Array out = edges(p_grid);
	float *w = out.ptrw();
	for (int c = 0; c < out.size(); c++) {
		const double e = double(w[c]);
		w[c] = float(e * e * e);
	}
	return out;
}

PackedByteArray LAGridGeometry::refine_mask(Object *p_grid, const Vector3 &p_centre, Object *p_terrain,
		double p_below_m, double p_above_m) {
	PackedByteArray out;
	if (!p_grid) {
		return out;
	}
	const int nx = int(p_grid->get("nx"));
	const int ny = int(p_grid->get("ny"));
	const int nz = int(p_grid->get("nz"));
	const double edge = double(p_grid->get("cell_size"));
	const Vector3 origin = p_grid->get("origin");
	const int base_count = nx * ny * nz;
	if (base_count <= 0 || !(edge > 0.0)) {
		return out;
	}
	out.resize(base_count);
	// A cell counts when its own CUBE reaches the band, not just its centre.
	const double pad = 0.5 * std::sqrt(3.0) * edge;
	// RESOLUTION FOLLOWS POSITION, AND STOPS WHERE IT IS ALREADY THERE. `above_m` is the air column the
	// refinement is FOR; a cell no coarser than that column already resolves what stands in it, and
	// splitting it buys nothing and costs eight cells. This keeps a small box uniform and a
	// planet-sized one graded, off one rule and no special case.
	const bool surface = p_above_m > 0.0 && edge > p_above_m && p_terrain
			&& p_terrain->has_method("surface_radius");
	if (!surface) {
		return out;
	}
	uint8_t *w = out.ptrw();
	for (int b = 0; b < base_count; b++) {
		w[b] = 0;
		const int x = b % nx;
		const int y = (b / nx) % ny;
		const int z = b / (nx * ny);
		// THE BOX EDGE STAYS COARSEST: prescribing an exterior and wrapping a torus are 1:1 on a face.
		if (x == 0 || y == 0 || z == 0 || x == nx - 1 || y == ny - 1 || z == nz - 1) {
			continue;
		}
		const Vector3 p = origin + (Vector3(float(x), float(y), float(z)) + Vector3(0.5, 0.5, 0.5))
				* float(edge);
		bool hit = false;
		const Vector3 rel = p - p_centre;
		const double r = double(rel.length());
		if (r > 0.0) {
			const double rs = double(p_terrain->call("surface_radius", rel / float(r)));
			hit = r >= rs - p_below_m - pad && r <= rs + p_above_m + pad;
		}
		w[b] = hit ? 1 : 0;
	}
	return out;
}

namespace {

// LAVoxelGrid.SLOT_STEP, in the same order: the opposite of d is d ^ 1.
const int SLOT_DX[6] = { -1, 1, 0, 0, 0, 0 };
const int SLOT_DY[6] = { 0, 0, -1, 1, 0, 0 };
const int SLOT_DZ[6] = { 0, 0, 0, 0, -1, 1 };

} // namespace

Dictionary LAGridGeometry::build(const Vector3i &p_dims, const PackedByteArray &p_mask) {
	Dictionary out;
	const int nx = MAX(p_dims.x, 1);
	const int ny = MAX(p_dims.y, 1);
	const int nz = MAX(p_dims.z, 1);
	const int base_count = nx * ny * nz;
	const bool use = p_mask.size() == base_count;

	PackedInt32Array base_head;
	PackedByteArray base_split;
	base_head.resize(base_count);
	base_split.resize(base_count);
	int n = 0;
	for (int b = 0; b < base_count; b++) {
		const bool split = use && p_mask[b] != 0;
		base_split.set(b, split ? 1 : 0);
		base_head.set(b, n);
		n += split ? 8 : 1;
	}
	PackedInt32Array cell_base;
	PackedByteArray cell_oct, levels;
	cell_base.resize(n);
	cell_oct.resize(n);
	levels.resize(n);
	for (int b = 0; b < base_count; b++) {
		const int head = base_head[b];
		const int kids = base_split[b] != 0 ? 8 : 1;
		for (int o = 0; o < kids; o++) {
			cell_base.set(head + o, b);
			cell_oct.set(head + o, kids == 8 ? o : 0);
			levels.set(head + o, kids == 8 ? 1 : 0);
		}
	}

	auto index = [&](int x, int y, int z) { return x + nx * (y + ny * z); };
	auto in_bounds = [&](int x, int y, int z) {
		return x >= 0 && x < nx && y >= 0 && y < ny && z >= 0 && z < nz;
	};
	auto base_step = [&](int b, int d) {
		const int x = (b % nx) + SLOT_DX[d];
		const int y = ((b / nx) % ny) + SLOT_DY[d];
		const int z = (b / (nx * ny)) + SLOT_DZ[d];
		return in_bounds(x, y, z) ? index(x, y, z) : -1;
	};
	auto leaf = [&](int b, int o) { return base_head[b] + (base_split[b] != 0 ? o : 0); };

	PackedInt32Array slot_off, neighbours, partners;
	slot_off.resize(n * 7);
	int at = 0;
	for (int c = 0; c < n; c++) {
		const int b = cell_base[c];
		const int lv = int(levels[c]);
		const int o = int(cell_oct[c]);
		for (int d = 0; d < 6; d++) {
			slot_off.set(c * 7 + d, at);
			const int axis = d >> 1;
			if (lv == 0) {
				const int b2 = base_step(b, d);
				if (b2 < 0) {
					neighbours.append(-1);
					at++;
				} else if (base_split[b2] == 0) {
					neighbours.append(base_head[b2]);
					at++;
				} else {
					// The four octants of the neighbour that touch the face this slot crosses.
					const int bit = ((d ^ 1) & 1) == 1 ? 1 : 0;
					for (int oc = 0; oc < 8; oc++) {
						if (((oc >> axis) & 1) == bit) {
							neighbours.append(base_head[b2] + oc);
							at++;
						}
					}
				}
			} else {
				const int bit = (o >> axis) & 1;
				const bool toward_hi = (d & 1) == 1;
				if ((toward_hi && bit == 0) || (!toward_hi && bit == 1)) {
					neighbours.append(base_head[b] + (o ^ (1 << axis)));
				} else {
					const int b3 = base_step(b, d);
					neighbours.append(b3 < 0 ? -1 : leaf(b3, o ^ (1 << axis)));
				}
				at++;
			}
		}
		slot_off.set(c * 7 + 6, at);
	}
	partners.resize(neighbours.size());
	for (int f = 0; f < partners.size(); f++) {
		partners.set(f, -1);
	}
	for (int c = 0; c < n; c++) {
		for (int d = 0; d < 6; d++) {
			const int back = d ^ 1;
			for (int f = slot_off[c * 7 + d]; f < slot_off[c * 7 + d + 1]; f++) {
				const int m = neighbours[f];
				if (m < 0) {
					continue;
				}
				for (int g = slot_off[m * 7 + back]; g < slot_off[m * 7 + back + 1]; g++) {
					if (neighbours[g] == c) {
						partners.set(f, g);
						break;
					}
				}
			}
		}
	}
	out["cell_count"] = n;
	out["levels"] = levels;
	out["cell_base"] = cell_base;
	out["cell_oct"] = cell_oct;
	out["base_head"] = base_head;
	out["base_split"] = base_split;
	out["slot_off"] = slot_off;
	out["neighbours"] = neighbours;
	out["partners"] = partners;
	return out;
}

Dictionary LAGridGeometry::validate(Object *p_grid) {
	Dictionary out;
	if (!p_grid) {
		return out;
	}
	const int cc = int(p_grid->get("cell_count"));
	const PackedInt32Array slot_off = p_grid->get("slot_off");
	const PackedInt32Array nbr = p_grid->get("neighbours");
	const PackedInt32Array partners = p_grid->get("partners");
	const PackedFloat32Array edge = edges(p_grid);
	int reciprocal = 0, non_reciprocal = 0, boundary = 0, ratio_bad = 0, area_bad = 0;
	double ratio_max = 1.0;
	for (int c = 0; c < cc; c++) {
		const double e = double(edge[c]);
		for (int d = 0; d < 6; d++) {
			double area = 0.0;
			for (int f = slot_off[c * 7 + d]; f < slot_off[c * 7 + d + 1]; f++) {
				const int m = nbr[f];
				if (m < 0) {
					boundary++;
					area += e * e;
					continue;
				}
				const int g = partners[f];
				if (g >= 0 && nbr[g] == c) {
					reciprocal++;
				} else {
					non_reciprocal++;
				}
				const double en = double(edge[m]);
				const double r = (e * e * e) / (en * en * en);
				if (std::abs(r - 1.0) > 1.0e-6 && std::abs(r - 8.0) > 1.0e-6
						&& std::abs(r - 0.125) > 1.0e-6) {
					ratio_bad++;
				}
				ratio_max = MAX(ratio_max, MAX(r, 1.0 / r));
				const double s = MIN(e, en);
				area += s * s;
			}
			if (std::abs(area - e * e) > 1.0e-6 * e * e) {
				area_bad++;
			}
		}
	}
	out["ok"] = non_reciprocal == 0 && ratio_bad == 0 && area_bad == 0;
	out["cells"] = cc;
	out["reciprocal"] = reciprocal;
	out["non_reciprocal"] = non_reciprocal;
	out["boundary_faces"] = boundary;
	out["ratio_violations"] = ratio_bad;
	out["area_violations"] = area_bad;
	out["cell_volume"] = cc > 0 ? std::pow(double(edge[0]), 3.0) : 0.0;
	out["volume_ratio"] = ratio_max;
	out["faces"] = nbr.size();
	return out;
}

PackedVector3Array LAGridGeometry::centres(Object *p_grid) {
	PackedVector3Array out;
	if (!p_grid) {
		return out;
	}
	const int nx = int(p_grid->get("nx"));
	const int ny = int(p_grid->get("ny"));
	const double edge = double(p_grid->get("cell_size"));
	const Vector3 origin = p_grid->get("origin");
	const PackedInt32Array cell_base = p_grid->get("cell_base");
	const PackedByteArray cell_oct = p_grid->get("cell_oct");
	const PackedByteArray levels = p_grid->get("levels");
	const int n = total_cells(p_grid);
	out.resize(n);
	Vector3 *w = out.ptrw();
	for (int c = 0; c < n; c++) {
		const int b = c < cell_base.size() ? cell_base[c] : 0;
		const Vector3 base(float((b % nx) + 0.5), float(((b / nx) % ny) + 0.5),
				float((b / (nx * ny)) + 0.5));
		Vector3 p = origin + base * float(edge);
		if (c < levels.size() && levels[c] != 0) {
			const int o = int(cell_oct[c]);
			const Vector3 q(float(o & 1), float((o >> 1) & 1), float((o >> 2) & 1));
			p += (q - Vector3(0.5, 0.5, 0.5)) * float(0.5 * edge);
		}
		w[c] = p;
	}
	return out;
}

Dictionary LAGridGeometry::ghost_rows(Object *p_grid, int p_n) {
	Dictionary out;
	if (!p_grid || p_n <= 0) {
		return out;
	}
	PackedByteArray levels = p_grid->get("levels");
	PackedInt32Array slot_off = p_grid->get("slot_off");
	PackedInt32Array nbr = p_grid->get("neighbours");
	PackedInt32Array partners = p_grid->get("partners");
	const int first = levels.size();
	const int total = first + p_n;
	levels.resize(total);
	slot_off.resize(total * 7);
	int at = nbr.size();
	for (int c = first; c < total; c++) {
		levels.set(c, 0);
		for (int d = 0; d < 6; d++) {
			slot_off.set(c * 7 + d, at + d);
		}
		slot_off.set(c * 7 + 6, at + 6);
		at += 6;
	}
	const int was = nbr.size();
	nbr.resize(at);
	partners.resize(at);
	for (int f = was; f < at; f++) {
		nbr.set(f, -1);
		partners.set(f, -1);
	}
	out["levels"] = levels;
	out["slot_off"] = slot_off;
	out["neighbours"] = nbr;
	out["partners"] = partners;
	return out;
}

double LAGridGeometry::weighted(const PackedFloat32Array &p_arr, const PackedFloat32Array &p_vol,
		const PackedByteArray &p_solid, bool p_mask_open) {
	const int n = p_arr.size();
	if (p_vol.size() < n || (p_mask_open && p_solid.size() < n)) {
		return 0.0;
	}
	double t = 0.0;
	for (int c = 0; c < n; c++) {
		if (!p_mask_open || p_solid[c] == 0) {
			t += double(p_arr[c]) * double(p_vol[c]);
		}
	}
	return t;
}

void LAGridGeometry::_bind_methods() {
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("edges", "grid"), &LAGridGeometry::edges);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("volumes", "grid"), &LAGridGeometry::volumes);
	ClassDB::bind_static_method("LAGridGeometry",
			D_METHOD("refine_mask", "grid", "centre", "terrain", "below_m", "above_m"),
			&LAGridGeometry::refine_mask);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("build", "dims", "mask"),
			&LAGridGeometry::build);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("validate", "grid"),
			&LAGridGeometry::validate);
	ClassDB::bind_static_method("LAGridGeometry",
			D_METHOD("weighted", "arr", "vol", "solid", "mask_open"), &LAGridGeometry::weighted);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("centres", "grid"),
			&LAGridGeometry::centres);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("ghost_rows", "grid", "n"),
			&LAGridGeometry::ghost_rows);
}
