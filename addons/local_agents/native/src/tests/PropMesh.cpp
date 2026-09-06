#include "Lattice.hpp"
#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "Generated.hpp"

namespace lasim {
namespace {

constexpr uint32_t kN = 4;
constexpr float kEdgeM = 512.0f;
constexpr uint32_t kWords = 65536;
constexpr uint32_t kDraws = 4;
// Far enough below the box that every cell's own radial is +y to a part in ten thousand.
constexpr float kBodyRadiusM = 6.5e6f;
constexpr float kFullMolM3 = 5.5e4f;
constexpr uint32_t kRingMax = 16;

struct Push {
	uint32_t cell_count;
	float centre_x;
	float centre_y;
	float centre_z;
	float full_amount;
	uint32_t max_verts;
	float r_step_m;
	uint32_t mode;
};

struct World {
	Lattice lat = Lattice::graded_x(kN, kN, kN, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<float> h2o;
	std::vector<float> fill;
	float centre[3] = { 0.0f, 0.0f, 0.0f };
	float r_step = 0.0f;
};

// One float32 step at the body's radius: the resolution every height in this mesh has.
float r_step_at(float r) {
	return std::ldexp(1.0f, int(std::floor(std::log2(std::fmax(r, 1.0f)))) - 23);
}

// A water table at `level_m` in y: every cell full under it, empty over it, and one cell of each column
// part full. `level_m` <= 0 leaves the box dry.
World draw(Rig &rig, float level_m) {
	World w;
	const uint32_t n = w.lat.cells();
	w.centre[0] = 0.5f * float(kN) * kEdgeM;
	w.centre[1] = -kBodyRadiusM;
	w.centre[2] = 0.5f * float(kN) * kEdgeM;
	w.r_step = r_step_at(kBodyRadiusM);
	w.h2o.assign(n, 0.0f);
	w.fill.assign(n, 0.0f);
	std::vector<float> ground(n, 0.0f);
	for (uint32_t c = 0; c < n; ++c) {
		const float e = w.lat.cell_edge[c];
		const float bottom = w.lat.pos[c * 3u + 1u] - 0.5f * e;
		const float f = level_m <= 0.0f ? 0.0f : std::fmin(std::fmax((level_m - bottom) / e, 0.0f), 1.0f);
		w.fill[c] = f;
		w.h2o[c] = f * kFullMolM3;
		ground[c] = 0.5f * e;   // the ground at the cell's own floor, so the water stands on it
	}
	rig.put(LA_BIND_NBR, w.lat.nbr);
	rig.put(LA_BIND_FACE_PARTNER, w.lat.partner);
	rig.put(LA_BIND_SLOT_OFF, w.lat.slot_off);
	rig.put(LA_BIND_CELL_EDGE, w.lat.cell_edge);
	rig.put(LA_BIND_POS, w.lat.pos);
	rig.put(LA_BIND_VERT_UP, w.lat.vert_up);
	rig.put(LA_BIND_VERT_DOWN, w.lat.vert_down);
	rig.put(LA_BIND_GROUND_D, ground);
	rig.put(LA_BIND_H2O, w.h2o);
	rig.fill(LA_BIND_H2O_LIQUID, 1.0f);
	rig.zero(LA_BIND_SOLID);
	return w;
}

// The three dispatches in order: the slots are cleared, a vertex placed per surface cell, the vertices
// joined off the slots the placing wrote.
void extract(Rig &rig, const World &w) {
	Push p{};
	p.cell_count = w.lat.cells();
	p.centre_x = w.centre[0];
	p.centre_y = w.centre[1];
	p.centre_z = w.centre[2];
	p.full_amount = kFullMolM3;
	p.max_verts = w.lat.cells();
	p.r_step_m = w.r_step;
	for (uint32_t mode : { 1u, 0u, 2u }) {
		p.mode = mode;
		rig.run(&p, sizeof(p), w.lat.cells());
	}
}

// Which cell of `c`'s own column carries the free surface, by the same walk the kernel makes.
int32_t column_surface(const World &w, const std::vector<int32_t> &slot, int32_t c) {
	if (c < 0) {
		return -1;
	}
	int32_t at = c;
	for (uint32_t k = 0; k < 64u; ++k) {
		if (slot[size_t(at)] >= 0) {
			return at;
		}
		const int32_t u = w.lat.vert_up[size_t(at)];
		if (u < 0) {
			break;
		}
		at = u;
	}
	at = w.lat.vert_down[size_t(c)];
	for (uint32_t k = 0; k < 64u && at >= 0; ++k) {
		if (slot[size_t(at)] >= 0) {
			return at;
		}
		at = w.lat.vert_down[size_t(at)];
	}
	return -1;
}

// THE SHEET DOES NOT OPEN ALONG A SEAM: two columns that stand side by side and both carry a free
// surface are joined by a triangle, whichever levels their cells are at. The lattice carries a 2:1
// boundary, so a coarse column stands beside four fine ones and has to reach every one of them.
bool prop_mesh_joins_neighbouring_columns(Case &c) {
	std::string err;
	Rig rig(c.dev, "mesh_extract", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(91);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const float level = rng.range(0.35f, 0.85f) * float(kN) * kEdgeM;
		const World w = draw(rig, level);
		extract(rig, w);
		const uint32_t n = w.lat.cells();
		const std::vector<uint32_t> counts = rig.get_u(LA_BIND_MESH_COUNT, 4);
		const uint32_t nv = counts[0], ni = counts[1];
		if (nv == 0u || ni == 0u) {
			c.why = "the detector extracted no surface from a box holding water";
			return false;
		}
		const std::vector<float> slot_f = rig.get(LA_BIND_MESH_SLOT, n);
		std::vector<int32_t> slot(n, -1);
		for (uint32_t g = 0; g < n; ++g) {
			slot[g] = int32_t(reinterpret_cast<const int32_t *>(slot_f.data())[g]);
		}
		const std::vector<uint32_t> idx = rig.get_u(LA_BIND_MESH_INDEX, ni);
		// Which vertex pairs a triangle joins.
		std::vector<uint8_t> joined(size_t(nv) * nv, 0u);
		for (uint32_t t = 0; t + 2u < ni; t += 3u) {
			const uint32_t a = idx[t], b = idx[t + 1u], e = idx[t + 2u];
			if (a >= nv || b >= nv || e >= nv) {
				c.why = "a triangle names a vertex slot nobody claimed";
				return false;
			}
			joined[size_t(a) * nv + b] = 1u;
			joined[size_t(b) * nv + a] = 1u;
			joined[size_t(b) * nv + e] = 1u;
			joined[size_t(e) * nv + b] = 1u;
			joined[size_t(a) * nv + e] = 1u;
			joined[size_t(e) * nv + a] = 1u;
		}
		uint32_t pairs = 0, met = 0;
		for (uint32_t g = 0; g < n; ++g) {
			if (slot[g] < 0) {
				continue;
			}
			// The lateral slots are the two that are not the vertical; the body is far below in -y.
			for (uint32_t ax : { 0u, 2u }) {
				for (uint32_t h = 0; h < 2u; ++h) {
					const uint32_t dd = ax * 2u + h;
					for (uint32_t f = w.lat.slot_off[g * 7u + dd]; f < w.lat.slot_off[g * 7u + dd + 1u];
							++f) {
						const int32_t s = column_surface(w, slot, w.lat.nbr[f]);
						if (s < 0 || s == int32_t(g)) {
							continue;
						}
						pairs += 1;
						met += joined[size_t(slot[g]) * nv + size_t(slot[size_t(s)])] ? 1u : 0u;
					}
				}
			}
		}
		c.examined += pairs;
		if (pairs == 0u) {
			c.why = "no two columns of this box stand beside each other, so nothing was examined";
			return false;
		}
		if (double(met) != double(shifted(float(pairs), c.mutate))) {
			c.why = "two columns standing side by side, both carrying a free surface, are not joined";
			return false;
		}
	}
	return c.examined > 0;
}

// A BOX WITH NO WATER CARRIES NO WATER SURFACE. The detector reads the field it stands on, so a dry box
// extracts no vertex and no triangle rather than a sheet at the cells' own floors.
bool prop_mesh_draws_no_surface_without_water(Case &c) {
	std::string err;
	Rig rig(c.dev, "mesh_extract", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rig, 0.0f);
		extract(rig, w);
		const std::vector<uint32_t> counts = rig.get_u(LA_BIND_MESH_COUNT, 4);
		c.examined += 2;
		if (double(counts[0]) != double(shifted(0.0f, c.mutate))
				|| double(counts[1]) != double(shifted(0.0f, c.mutate)) * 3.0) {
			c.why = "the detector drew a water surface over a box holding no water";
			return false;
		}
	}
	return c.examined > 0;
}

} // namespace

void add_mesh_properties(std::vector<Property> &out) {
	out.push_back({ "mesh_extract.glsl", "mesh_joins_neighbouring_columns",
			prop_mesh_joins_neighbouring_columns });
	out.push_back({ "mesh_extract.glsl", "mesh_draws_no_surface_without_water",
			prop_mesh_draws_no_surface_without_water });
}

} // namespace lasim
