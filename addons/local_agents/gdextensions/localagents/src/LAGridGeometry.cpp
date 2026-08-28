#include "LAGridGeometry.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include "LAPhysicalRead.hpp"
#include "LAScriptCall.hpp"
#include "LAFieldStateCache.hpp"
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include "LATerrainLattice.hpp"
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <vector>

using namespace godot;

namespace {

int total_cells(Object *p_grid) {
	return int(p_grid->get("cell_count")) + int(p_grid->get("ghost_rows"));
}

double edge_of(double p_base, int p_level) {
	return p_base * std::pow(0.5, double(p_level));
}

const int MAXL = LAGridGeometry::MAX_LEVEL;
const uint32_t FULL = 1u << MAXL;

// LAVoxelGrid.SLOT_STEP, in the same order: the opposite of d is d ^ 1.
const int SLOT_DX[6] = { -1, 1, 0, 0, 0, 0 };
const int SLOT_DY[6] = { 0, 0, -1, 1, 0, 0 };
const int SLOT_DZ[6] = { 0, 0, 0, 0, -1, 1 };

uint32_t spread3(uint32_t v) {
	v &= 0x3ff;
	v = (v | (v << 16)) & 0x030000ff;
	v = (v | (v << 8)) & 0x0300f00f;
	v = (v | (v << 4)) & 0x030c30c3;
	v = (v | (v << 2)) & 0x09249249;
	return v;
}

// Full-depth Morton code of a point at resolution 2^MAXL inside one base cell.
uint32_t morton3(uint32_t x, uint32_t y, uint32_t z) {
	return spread3(x) | (spread3(y) << 1) | (spread3(z) << 2);
}

// A leaf: which base cell, its level, its local lattice coordinates at that level, and the Morton
// code of its lowest corner at full depth. Leaves of one base are kept sorted by that code.
struct Leaf {
	int base;
	int level;
	int lx, ly, lz;
	uint32_t code;
};

uint32_t leaf_code(const Leaf &l) {
	const uint32_t sh = uint32_t(MAXL - l.level);
	return morton3(uint32_t(l.lx) << sh, uint32_t(l.ly) << sh, uint32_t(l.lz) << sh);
}

struct Lattice {
	int nx, ny, nz;
	std::vector<std::vector<Leaf>> leaves;   // per base, sorted by code

	int index(int x, int y, int z) const { return x + nx * (y + ny * z); }
	bool in_bounds(int x, int y, int z) const {
		return x >= 0 && x < nx && y >= 0 && y < ny && z >= 0 && z < nz;
	}
	int base_step(int b, int d) const {
		const int x = (b % nx) + SLOT_DX[d];
		const int y = ((b / nx) % ny) + SLOT_DY[d];
		const int z = (b / (nx * ny)) + SLOT_DZ[d];
		return in_bounds(x, y, z) ? index(x, y, z) : -1;
	}
	bool edge_base(int b) const {
		const int x = b % nx, y = (b / nx) % ny, z = b / (nx * ny);
		return x == 0 || y == 0 || z == 0 || x == nx - 1 || y == ny - 1 || z == nz - 1;
	}
	// A leaf whose cube touches the box face.
	bool edge_leaf(const Leaf &l) const {
		const int x = l.base % nx, y = (l.base / nx) % ny, z = l.base / (nx * ny);
		const int last = (1 << l.level) - 1;
		return (x == 0 && l.lx == 0) || (y == 0 && l.ly == 0) || (z == 0 && l.lz == 0)
				|| (x == nx - 1 && l.lx == last) || (y == ny - 1 && l.ly == last) || (z == nz - 1 && l.lz == last);
	}
	// The leaf of base b holding the full-depth point (fx, fy, fz): the last whose code is not past it.
	int find(int b, uint32_t fx, uint32_t fy, uint32_t fz) const {
		const uint32_t m = morton3(fx, fy, fz);
		const std::vector<Leaf> &v = leaves[b];
		int lo = 0, hi = int(v.size()) - 1;
		while (lo < hi) {
			const int mid = (lo + hi + 1) / 2;
			if (v[mid].code <= m) {
				lo = mid;
			} else {
				hi = mid - 1;
			}
		}
		return lo;
	}
	// Full-depth coordinates (px, py, pz) of a point in base b, stepped by `step` along axis `axis`;
	// returns the base it lands in (or -1) and rewrites the coordinate.
	int step_point(int b, int axis, int step, int64_t &px, int64_t &py, int64_t &pz) const {
		int64_t *c = axis == 0 ? &px : (axis == 1 ? &py : &pz);
		*c += step;
		if (*c >= 0 && *c < int64_t(FULL)) {
			return b;
		}
		const int d = axis * 2 + (step > 0 ? 1 : 0);
		const int b2 = base_step(b, d);
		if (b2 < 0) {
			return -1;
		}
		*c = step > 0 ? *c - int64_t(FULL) : *c + int64_t(FULL);
		return b2;
	}
	void split(int b, int i) {
		Leaf l = leaves[b][i];
		std::vector<Leaf> kids;
		for (int o = 0; o < 8; o++) {
			Leaf k;
			k.base = b;
			k.level = l.level + 1;
			k.lx = l.lx * 2 + (o & 1);
			k.ly = l.ly * 2 + ((o >> 1) & 1);
			k.lz = l.lz * 2 + ((o >> 2) & 1);
			k.code = leaf_code(k);
			kids.push_back(k);
		}
		leaves[b].erase(leaves[b].begin() + i);
		leaves[b].insert(leaves[b].begin() + i, kids.begin(), kids.end());
	}
};

// Full-depth centre of a leaf.
void leaf_centre_full(const Leaf &l, int64_t &px, int64_t &py, int64_t &pz) {
	const int64_t w = int64_t(1) << (MAXL - l.level);
	px = int64_t(l.lx) * w + w / 2;
	py = int64_t(l.ly) * w + w / 2;
	pz = int64_t(l.lz) * w + w / 2;
}

// The leaves across face d of leaf (b, i): one when the neighbour is as coarse or coarser, four when it
// is finer. Probes the four subface centres one full-depth unit past the face.
void faces_across(const Lattice &lat, int b, int i, int d, std::vector<int> &out_base,
		std::vector<int> &out_leaf) {
	out_base.clear();
	out_leaf.clear();
	const Leaf &l = lat.leaves[b][i];
	const int axis = d >> 1;
	const int64_t w = int64_t(1) << (MAXL - l.level);
	const int64_t q = w / 4 > 0 ? w / 4 : 0;
	int64_t cx, cy, cz;
	leaf_centre_full(l, cx, cy, cz);
	int64_t base[3] = { cx, cy, cz };
	// Onto the face plane, one unit past it.
	base[axis] += (d & 1) ? w / 2 : -(w / 2 + 1);
	const int u = (axis + 1) % 3, v = (axis + 2) % 3;
	int last_b = -2, last_leaf = -2;
	for (int s = 0; s < 4; s++) {
		int64_t p[3] = { base[0], base[1], base[2] };
		p[u] += (s & 1) ? q : -q;
		p[v] += (s & 2) ? q : -q;
		int64_t px = p[0], py = p[1], pz = p[2];
		int b2 = b;
		// The probe may have crossed the base cell along the face axis only.
		for (int a = 0; a < 3 && b2 >= 0; a++) {
			int64_t *c = a == 0 ? &px : (a == 1 ? &py : &pz);
			if (*c < 0) {
				b2 = lat.base_step(b2, a * 2);
				*c += int64_t(FULL);
			} else if (*c >= int64_t(FULL)) {
				b2 = lat.base_step(b2, a * 2 + 1);
				*c -= int64_t(FULL);
			}
		}
		if (b2 < 0) {
			out_base.push_back(-1);
			out_leaf.push_back(-1);
			return;
		}
		const int j = lat.find(b2, uint32_t(px), uint32_t(py), uint32_t(pz));
		if (b2 == last_b && j == last_leaf) {
			continue;
		}
		last_b = b2;
		last_leaf = j;
		out_base.push_back(b2);
		out_leaf.push_back(j);
	}
}

// Refine every leaf `want` asks for, then balance to 2:1 across every face.
void refine_lattice(Lattice &lat, const std::function<bool(const Leaf &)> &want) {
	for (int b = 0; b < int(lat.leaves.size()); b++) {
		for (int i = 0; i < int(lat.leaves[b].size());) {
			if (lat.leaves[b][i].level < MAXL && want(lat.leaves[b][i])) {
				lat.split(b, i);
			} else {
				i++;
			}
		}
	}
	bool changed = true;
	std::vector<int> nb, nl;
	while (changed) {
		changed = false;
		for (int b = 0; b < int(lat.leaves.size()); b++) {
			for (int i = 0; i < int(lat.leaves[b].size());) {
				const int lv = lat.leaves[b][i].level;
				bool split = false;
				for (int d = 0; d < 6 && !split; d++) {
					faces_across(lat, b, i, d, nb, nl);
					for (size_t k = 0; k < nb.size(); k++) {
						if (nb[k] >= 0 && lat.leaves[nb[k]][nl[k]].level > lv + 1) {
							split = true;
							break;
						}
					}
				}
				if (split && lv < MAXL) {
					lat.split(b, i);
					changed = true;
				} else {
					i++;
				}
			}
		}
	}
}

Dictionary emit(const Lattice &lat) {
	Dictionary out;
	const int base_count = int(lat.leaves.size());
	PackedInt32Array base_head, base_leaves, cell_base, cell_local, cell_morton;
	PackedByteArray levels;
	base_head.resize(base_count);
	base_leaves.resize(base_count);
	int n = 0;
	for (int b = 0; b < base_count; b++) {
		base_head.set(b, n);
		base_leaves.set(b, int(lat.leaves[b].size()));
		n += int(lat.leaves[b].size());
	}
	cell_base.resize(n);
	cell_local.resize(n * 3);
	cell_morton.resize(n);
	levels.resize(n);
	int top = 0;
	for (int b = 0; b < base_count; b++) {
		for (int i = 0; i < int(lat.leaves[b].size()); i++) {
			const Leaf &l = lat.leaves[b][i];
			const int c = base_head[b] + i;
			cell_base.set(c, b);
			cell_local.set(c * 3, l.lx);
			cell_local.set(c * 3 + 1, l.ly);
			cell_local.set(c * 3 + 2, l.lz);
			cell_morton.set(c, int32_t(l.code));
			levels.set(c, uint8_t(l.level));
			top = MAX(top, l.level);
		}
	}
	PackedInt32Array slot_off, neighbours, partners;
	slot_off.resize(n * 7);
	std::vector<int> nb, nl;
	int at = 0;
	for (int b = 0; b < base_count; b++) {
		for (int i = 0; i < int(lat.leaves[b].size()); i++) {
			const int c = base_head[b] + i;
			for (int d = 0; d < 6; d++) {
				slot_off.set(c * 7 + d, at);
				faces_across(lat, b, i, d, nb, nl);
				for (size_t k = 0; k < nb.size(); k++) {
					neighbours.append(nb[k] < 0 ? -1 : base_head[nb[k]] + nl[k]);
					at++;
				}
			}
			slot_off.set(c * 7 + 6, at);
		}
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
	out["max_level"] = top;
	out["levels"] = levels;
	out["cell_base"] = cell_base;
	out["cell_local"] = cell_local;
	out["cell_morton"] = cell_morton;
	out["base_head"] = base_head;
	out["base_leaves"] = base_leaves;
	out["slot_off"] = slot_off;
	out["neighbours"] = neighbours;
	out["partners"] = partners;
	return out;
}

Lattice uniform(const Vector3i &p_dims) {
	Lattice lat;
	lat.nx = MAX(p_dims.x, 1);
	lat.ny = MAX(p_dims.y, 1);
	lat.nz = MAX(p_dims.z, 1);
	lat.leaves.resize(size_t(lat.nx) * lat.ny * lat.nz);
	for (int b = 0; b < int(lat.leaves.size()); b++) {
		Leaf l;
		l.base = b;
		l.level = 0;
		l.lx = l.ly = l.lz = 0;
		l.code = 0;
		lat.leaves[b].push_back(l);
	}
	return lat;
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

Dictionary LAGridGeometry::build(const Vector3i &p_dims, const PackedByteArray &p_mask) {
	Lattice lat = uniform(p_dims);
	const bool use = p_mask.size() == int(lat.leaves.size());
	if (use) {
		refine_lattice(lat, [&](const Leaf &l) { return l.level == 0 && p_mask[l.base] != 0; });
	}
	return emit(lat);
}

namespace {

// One terrain sample per base cell at its centre, and the relief the terrain spans: the band test's inputs.
struct SurfaceSamples {
	std::vector<double> rs;
	double relief = 0.0;
};

SurfaceSamples sample_surface(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
		const Vector3 &p_centre, Object *p_terrain, double p_target_edge_m) {
	SurfaceSamples out;
	const int nx = MAX(p_dims.x, 1), ny = MAX(p_dims.y, 1), nz = MAX(p_dims.z, 1);
	const int base_count = nx * ny * nz;
	out.rs.assign(base_count, NAN);
	if (!p_terrain || !p_terrain->has_method("surface_radius")) {
		return out;
	}
	if (p_terrain->has_method("max_surface_radius") && p_terrain->has_method("planet_radius")) {
		out.relief = std::abs(double(p_terrain->call("max_surface_radius")) - double(p_terrain->call("planet_radius")));
	}
	std::vector<Vector3> dir(base_count);
	for (int b = 0; b < base_count; b++) {
		const Vector3 bo(float(b % nx) + 0.5f, float((b / nx) % ny) + 0.5f, float(b / (nx * ny)) + 0.5f);
		const Vector3 rel = p_origin + bo * float(p_cell_size) - p_centre;
		const double r = double(rel.length());
		dir[b] = r > 0.0 ? rel / float(r) : Vector3(0, 1, 0);
	}
	// Bisection along every direction at once between the terrain's lowest and highest surface: the
	// generator's signed distance, batched, instead of a ray march per direction.
	// The surface along each direction: a bisection on the terrain's lattice between its lowest and
	// highest surface, no ray march.
	if (p_terrain->has_method("min_surface_radius") && p_terrain->has_method("max_surface_radius")) {
		const double r_lo0 = double(p_terrain->call("min_surface_radius"));
		const double r_hi0 = double(p_terrain->call("max_surface_radius"));
		// The same lattice the solid mask reads, sized by the box.
		const double extent = p_cell_size * MAX(MAX(nx, ny), nz);
		const LATerrainLattice &lat = LATerrainLattice::build(p_terrain, p_origin, extent, LATerrainLattice::lod_for(extent), 32, p_centre, r_lo0, r_hi0);
		if (lat.valid()) {
			for (int b = 0; b < base_count; b++) {
				double lo = r_lo0, hi = r_hi0;
				for (int i = 0; i < 24; i++) {
					const double mid = 0.5 * (lo + hi);
					if (lat.sample(p_centre + dir[b] * float(mid)) < 0.0) {
						lo = mid;
					} else {
						hi = mid;
					}
				}
				out.rs[b] = 0.5 * (lo + hi);
			}
			return out;
		}
	}
	for (int b = 0; b < base_count; b++) {
		out.rs[b] = double(p_terrain->call("surface_radius", dir[b]));
	}
	return out;
}

Dictionary build_graded_sampled(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
		const Vector3 &p_centre, const SurfaceSamples &p_s, double p_below_m, double p_above_m,
		double p_target_edge_m, const Vector3 &p_focus_min, const Vector3 &p_focus_max,
		double p_focus_edge_m) {
	Lattice lat = uniform(p_dims);
	const bool can = p_cell_size > 0.0 && p_target_edge_m > 0.0 && int(p_s.rs.size()) == int(lat.leaves.size());
	if (can) {
		const std::vector<double> &rs_base = p_s.rs;
		const double relief = p_s.relief;
		refine_lattice(lat, [&](const Leaf &l) {
			if (lat.edge_leaf(l)) {
				return false;   // THE BOX FACE STAYS COARSEST: an exterior and a torus are 1:1 on a face
			}
			const double edge = edge_of(p_cell_size, l.level);
			const int b = l.base;
			const Vector3 bo(float(b % lat.nx), float((b / lat.nx) % lat.ny), float(b / (lat.nx * lat.ny)));
			const Vector3 lo(float(l.lx) + 0.5f, float(l.ly) + 0.5f, float(l.lz) + 0.5f);
			const Vector3 p = p_origin + (bo + lo * float(std::pow(0.5, double(l.level)))) * float(p_cell_size);
			// A FOCUS BOX is resolved to its own edge: a slab recorded from this world is resolved by it.
			if (p_focus_edge_m > 0.0 && edge > p_focus_edge_m) {
				const float h = float(0.5 * edge);
				if (p.x + h > p_focus_min.x && p.x - h < p_focus_max.x && p.y + h > p_focus_min.y
						&& p.y - h < p_focus_max.y && p.z + h > p_focus_min.z && p.z - h < p_focus_max.z) {
					return true;
				}
			}
			if (!(edge > p_target_edge_m)) {
				return false;
			}
			// A cell counts when its own CUBE reaches the band, not just its centre.
			const double pad = 0.5 * std::sqrt(3.0) * edge;
			const Vector3 rel = p - p_centre;
			const double r = double(rel.length());
			if (!(r > 0.0)) {
				return false;
			}
			const double rs = rs_base[l.base];
			if (!std::isfinite(rs)) {
				return false;
			}
			return r >= rs - p_below_m - pad - relief && r <= rs + p_above_m + pad + relief;
		});
	}
	return emit(lat);
}

} // namespace

Dictionary LAGridGeometry::build_graded(const Vector3i &p_dims, const Vector3 &p_origin,
		double p_cell_size, const Vector3 &p_centre, Object *p_terrain, double p_below_m,
		double p_above_m, double p_target_edge_m, const Vector3 &p_focus_min, const Vector3 &p_focus_max,
		double p_focus_edge_m) {
	return build_graded_sampled(p_dims, p_origin, p_cell_size, p_centre,
			sample_surface(p_dims, p_origin, p_cell_size, p_centre, p_terrain, p_target_edge_m), p_below_m,
			p_above_m, p_target_edge_m, p_focus_min, p_focus_max, p_focus_edge_m);
}

Dictionary LAGridGeometry::build_to_budget(const Vector3i &p_dims, const Vector3 &p_origin,
		double p_cell_size, const Vector3 &p_centre, Object *p_terrain, double p_below_m,
		double p_above_m, double p_target_edge_m, int p_budget, const Vector3 &p_focus_min,
		const Vector3 &p_focus_max, double p_focus_edge_m) {
	// COARSE TO FINE: each halving of the target is tried only after the coarser grid fit, so the first
	// grid that would not fit is never built.
	Dictionary best = build(p_dims, PackedByteArray());
	best["target_edge_m"] = p_cell_size;
	const SurfaceSamples samples = sample_surface(p_dims, p_origin, p_cell_size, p_centre, p_terrain, p_target_edge_m);
	double target = 0.5 * p_cell_size;
	while (p_target_edge_m > 0.0 && p_budget > 0 && target > 0.0) {
		Dictionary next = build_graded_sampled(p_dims, p_origin, p_cell_size, p_centre, samples,
				p_below_m, p_above_m, target, p_focus_min, p_focus_max, p_focus_edge_m);
		if (int(next.get("cell_count", 0)) > p_budget) {
			break;
		}
		next["target_edge_m"] = target;
		best = next;
		if (target <= p_target_edge_m) {
			break;   // the band's finest cells are at or under the edge asked for
		}
		target *= 0.5;
	}
	return best;
}

double LAGridGeometry::target_edge_m(double p_mass_kg, double p_radius_m, double p_t_c,
		double p_cells_per_h) {
	if (!(p_mass_kg > 0.0) || !(p_radius_m > 0.0) || !(p_cells_per_h > 0.0)) {
		return 0.0;
	}
	const double g = la_physical("GRAVITATIONAL_CONSTANT") * p_mass_kg / (p_radius_m * p_radius_m);
	const double h = la_physical("DRY_AIR_GAS_CONSTANT_J_KGK") * (p_t_c + la_physical("KELVIN_OFFSET")) / g;
	return h / p_cells_per_h;
}

int LAGridGeometry::cell_budget() {
	Ref<FileAccess> f = FileAccess::open("res://docs/CELL_BUDGET", FileAccess::READ);
	if (f.is_null()) {
		return -1;
	}
	while (!f->eof_reached()) {
		const String line = f->get_line().strip_edges();
		if (line.is_valid_int()) {
			return int(line.to_int());
		}
	}
	return -1;
}

int LAGridGeometry::wrap_partner(Object *p_grid, int p_c, int p_d) {
	if (!p_grid || p_c < 0 || p_d < 0 || p_d > 5) {
		return -1;
	}
	const int dims[3] = { int(p_grid->get("nx")), int(p_grid->get("ny")), int(p_grid->get("nz")) };
	const PackedInt32Array cell_base = p_grid->get("cell_base");
	const PackedInt32Array base_head = p_grid->get("base_head");
	if (p_c >= cell_base.size()) {
		return -1;
	}
	const int b = cell_base[p_c];
	int v[3] = { b % dims[0], (b / dims[0]) % dims[1], b / (dims[0] * dims[1]) };
	const int axis = p_d >> 1;
	v[axis] = (p_d & 1) == 0 ? dims[axis] - 1 : 0;
	return base_head[v[0] + dims[0] * (v[1] + dims[1] * v[2])];
}

double LAGridGeometry::face_distance(Object *p_grid, int p_c, int p_f) {
	if (!p_grid) {
		return 0.0;
	}
	const PackedByteArray levels = p_grid->get("levels");
	const PackedInt32Array nbr = p_grid->get("neighbours");
	const double base = double(p_grid->get("cell_size"));
	const double e = edge_of(base, p_c >= 0 && p_c < levels.size() ? int(levels[p_c]) : 0);
	const int m = p_f >= 0 && p_f < nbr.size() ? nbr[p_f] : -1;
	if (m < 0) {
		return e;
	}
	return 0.5 * (e + edge_of(base, m < levels.size() ? int(levels[m]) : 0));
}

Dictionary LAGridGeometry::refine_field_grid(Object *p_grid, Object *p_terrain, const Vector3 &p_centre,
		double p_body_radius, double p_below_m, double p_above_m, double p_target_edge_m,
		const String &p_focus_spec, const String &p_cache_key) {
	Dictionary out;
	if (!p_grid) {
		return out;
	}
	const int budget = cell_budget();
	if (budget <= 0) {
		UtilityFunctions::push_error("LAGridGeometry: docs/CELL_BUDGET declares no budget, so the grid stays coarse.");
		return out;
	}
	Vector3 f_min, f_max;
	double f_edge = 0.0;
	if (!p_focus_spec.is_empty()) {
		Array args;
		args.append(p_focus_spec);
		const Variant parsed = la_call_gd("res://addons/local_agents/sim/material/FieldSlice3D.gd", "parse", args);
		Object *box = parsed;
		if (box && String(box->get("error")).is_empty()) {
			const AABB a = box->call("world_aabb", p_centre, p_body_radius);
			f_min = a.position;
			f_max = a.position + a.size;
			f_edge = double(box->get("cell_size"));
		}
	}
	// The key: the terrain and box (the mask cache's own key), the band, the extension, the focus.
	Array kargs;
	kargs.append(p_terrain && p_terrain->has_method("generator_options") ? Variant(p_terrain->call("generator_options")) : Variant(Dictionary()));
	kargs.append(p_grid);
	const String mask_key = la_call_gd("res://addons/local_agents/sim/material/MaterialFieldCache3D.gd", "key", kargs);
	Ref<FileAccess> hf = FileAccess::open("res://addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH", FileAccess::READ);
	const String ext_hash = hf.is_valid() ? hf->get_as_text() : String();
	const String key = String(mask_key + String("|grid|") + String::num(p_target_edge_m, 3) + String("|")
			+ String::num(p_below_m, 3) + String("|") + String::num(p_above_m, 3) + String("|") + ext_hash
			+ String("|") + p_focus_spec + String("|") + String::num(f_edge, 3) + String("|") + p_cache_key).sha256_text();
	Dictionary g = LAFieldStateCache::load_blob(key);
	if (g.is_empty()) {
		const Vector3i dims(int(p_grid->get("nx")), int(p_grid->get("ny")), int(p_grid->get("nz")));
		g = build_to_budget(dims, p_grid->get("origin"), double(p_grid->get("cell_size")), p_centre,
				p_terrain, p_below_m, p_above_m, p_target_edge_m, budget, f_min, f_max, f_edge);
		LAFieldStateCache::save_blob(key, g);
	}
	return g;
}

int LAGridGeometry::cell_at(Object *p_grid, const Vector3 &p_point) {
	if (!p_grid) {
		return -1;
	}
	const int nx = int(p_grid->get("nx"));
	const int ny = int(p_grid->get("ny"));
	const int nz = int(p_grid->get("nz"));
	const double edge = double(p_grid->get("cell_size"));
	const Vector3 origin = p_grid->get("origin");
	if (!(edge > 0.0)) {
		return -1;
	}
	const Vector3 local = (p_point - origin) / float(edge);
	const int x = int(std::floor(local.x)), y = int(std::floor(local.y)), z = int(std::floor(local.z));
	if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz) {
		return -1;
	}
	const int b = x + nx * (y + ny * z);
	const PackedInt32Array base_head = p_grid->get("base_head");
	const PackedInt32Array base_leaves = p_grid->get("base_leaves");
	const PackedInt32Array codes = p_grid->get("cell_morton");
	if (b >= base_head.size() || b >= base_leaves.size()) {
		return -1;
	}
	auto full = [&](double f) {
		const double v = std::floor((f - std::floor(f)) * double(FULL));
		return uint32_t(std::min(std::max(v, 0.0), double(FULL - 1)));
	};
	const uint32_t m = morton3(full(local.x), full(local.y), full(local.z));
	int lo = base_head[b], hi = base_head[b] + base_leaves[b] - 1;
	while (lo < hi) {
		const int mid = (lo + hi + 1) / 2;
		if (uint32_t(codes[mid]) <= m) {
			lo = mid;
		} else {
			hi = mid - 1;
		}
	}
	return lo;
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
	const PackedInt32Array cell_local = p_grid->get("cell_local");
	const PackedByteArray levels = p_grid->get("levels");
	const int n = total_cells(p_grid);
	out.resize(n);
	Vector3 *w = out.ptrw();
	for (int c = 0; c < n; c++) {
		const int b = c < cell_base.size() ? cell_base[c] : 0;
		const Vector3 bo(float(b % nx), float((b / nx) % ny), float(b / (nx * ny)));
		const int lv = c < levels.size() ? int(levels[c]) : 0;
		Vector3 lo(0.5f, 0.5f, 0.5f);
		if (c * 3 + 2 < cell_local.size()) {
			lo = Vector3(float(cell_local[c * 3]) + 0.5f, float(cell_local[c * 3 + 1]) + 0.5f,
					float(cell_local[c * 3 + 2]) + 0.5f) * float(std::pow(0.5, double(lv)));
		}
		w[c] = origin + (bo + lo) * float(edge);
	}
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
			D_METHOD("build_graded", "dims", "origin", "cell_size", "centre", "terrain", "below_m",
					"above_m", "target_edge_m", "focus_min", "focus_max", "focus_edge_m"),
			&LAGridGeometry::build_graded);
	ClassDB::bind_static_method("LAGridGeometry",
			D_METHOD("build_to_budget", "dims", "origin", "cell_size", "centre", "terrain", "below_m",
					"above_m", "target_edge_m", "budget", "focus_min", "focus_max", "focus_edge_m"),
			&LAGridGeometry::build_to_budget);
	ClassDB::bind_static_method("LAGridGeometry",
			D_METHOD("target_edge_m", "mass_kg", "radius_m", "t_c", "cells_per_h"),
			&LAGridGeometry::target_edge_m);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("cell_budget"), &LAGridGeometry::cell_budget);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("wrap_partner", "grid", "c", "d"),
			&LAGridGeometry::wrap_partner);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("face_distance", "grid", "c", "f"),
			&LAGridGeometry::face_distance);
	ClassDB::bind_static_method("LAGridGeometry",
			D_METHOD("refine_field_grid", "grid", "terrain", "centre", "body_radius", "below_m", "above_m",
					"target_edge_m", "focus_spec", "cache_key"),
			&LAGridGeometry::refine_field_grid);
	ClassDB::bind_static_method("LAGridGeometry", D_METHOD("cell_at", "grid", "point"),
			&LAGridGeometry::cell_at);
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
