#include "Lattice.hpp"
#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "Generated.hpp"

namespace lasim {
namespace {

constexpr uint32_t kNx = 4;
constexpr uint32_t kNy = 8;
constexpr uint32_t kNz = 4;
constexpr float kEdgeM = 250.0f;
constexpr uint32_t kWords = 8192;
constexpr uint32_t kDraws = 8;
constexpr double kU = 5.9604645e-8;

struct Push {
	uint32_t cell_count;
	float p_top;
	uint32_t max_steps;
	// chunk.glsli: the whole dispatch in one submit.
	uint32_t chunk_stride = 1;
	uint32_t chunk_phase = 0;
};

struct World {
	Lattice lat = Lattice::box(kNx, kNy, kNz, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<float> rho;
	std::vector<float> lithic;   // the lattice's share of rho
	std::vector<float> solid;
	std::vector<float> grav;     // cell*3
	std::vector<float> pressure; // what stands in the cell before the pass
	float p_top = 0.0f;
	float up[3] = { 0.0f, 1.0f, 0.0f };
};

// Rock everywhere, or rock under one open row of fluid at its own pressure.
World draw(Rng &rng, bool open_top) {
	World w;
	const uint32_t n = w.lat.cells();
	w.rho.assign(n, 0.0f);
	w.lithic.assign(n, 0.0f);
	w.solid.assign(n, 1.0f);
	w.grav.assign(size_t(n) * 3u, 0.0f);
	w.pressure.assign(n, 0.0f);
	w.p_top = rng.decades(1.0f, 1.0e5f);
	// One gravity direction for the box; vert_up is the +y relation, so the column the march walks is
	// the lattice's, whatever way the pull leans.
	float gx = rng.range(-1.0f, 1.0f);
	float gy = -rng.range(0.2f, 1.0f);
	float gz = rng.range(-1.0f, 1.0f);
	const float len = std::sqrt(gx * gx + gy * gy + gz * gz);
	gx /= len;
	gy /= len;
	gz /= len;
	w.up[0] = -gx;
	w.up[1] = -gy;
	w.up[2] = -gz;
	for (uint32_t c = 0; c < n; ++c) {
		w.rho[c] = rng.decades(1.0f, 5.0e3f);
		w.lithic[c] = w.rho[c] * rng.range(0.0f, 1.0f);
		const float gm = rng.range(1.0f, 25.0f);
		w.grav[c * 3u] = gx * gm;
		w.grav[c * 3u + 1u] = gy * gm;
		w.grav[c * 3u + 2u] = gz * gm;
	}
	if (open_top) {
		for (uint32_t x = 0; x < kNx; ++x) {
			for (uint32_t z = 0; z < kNz; ++z) {
				const uint32_t c = w.lat.index(x, kNy - 1u, z);
				w.solid[c] = 0.0f;
				w.pressure[c] = rng.decades(1.0e2f, 1.0e7f);
			}
		}
	}
	return w;
}

// The weight per unit area of `rho` kg/m^3 in one cell, Pa: rho g projected onto the step the march takes.
double weight_of(const World &w, uint32_t c, float rho) {
	const double gx = w.grav[c * 3u];
	const double gy = w.grav[c * 3u + 1u];
	const double gz = w.grav[c * 3u + 2u];
	const double gm = std::sqrt(gx * gx + gy * gy + gz * gz);
	if (gm <= 0.0) { return 0.0; }
	const double m = std::fmax(std::fmax(std::fabs(w.up[0]), std::fabs(w.up[1])), std::fabs(w.up[2]));
	return double(rho) * gm * double(kEdgeM) * m;
}

double load_of(const World &w, uint32_t c) {
	return weight_of(w, c, w.rho[c]);
}

void load(Rig &rig, const World &w) {
	rig.put(LA_BIND_VERT_UP, w.lat.vert_up);
	rig.put(LA_BIND_CELL_EDGE, w.lat.cell_edge);
	rig.put(LA_BIND_SOLID, w.solid);
	rig.put(LA_BIND_RHO_BULK, w.rho);
	rig.put(LA_BIND_LITHIC_KG, w.lithic);
	rig.put(LA_BIND_G_REST, w.grav);
	rig.put(LA_BIND_PRESSURE, w.pressure);
}

// THE COLUMN FROM THE TOP FACE: half this cell's own load plus every load standing over it, ending at
// the first open cell's own pressure with what it holds under it -- its lattice whole, its fluid from its
// mean -- or at the box top.
bool prop_column_is_the_integral(Case &c) {
	std::string err;
	Rig rig(c.dev, "pressure", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(21);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const bool open_top = (d % 2u) == 1u;
		const World w = draw(rng, open_top);
		load(rig, w);
		Push p{ w.lat.cells(), w.p_top, kNy + 2u };
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> got = rig.get(LA_BIND_PRESSURE, w.lat.cells());
		for (uint32_t g = 0; g < w.lat.cells(); ++g) {
			if (w.solid[g] == 0.0f) { continue; }
			double acc = 0.5 * load_of(w, g);
			double abs_terms = std::fabs(acc);
			double top = double(w.p_top);
			int32_t a = w.lat.vert_up[g];
			for (uint32_t i = 0; i < p.max_steps && a >= 0; ++i) {
				if (w.solid[uint32_t(a)] == 0.0f) {
					const double under = 0.5 * (load_of(w, uint32_t(a)) + weight_of(w, uint32_t(a), w.lithic[uint32_t(a)]));
					top = double(w.pressure[uint32_t(a)]) + under;
					abs_terms += std::fabs(under);
					break;
				}
				const double l = load_of(w, uint32_t(a));
				acc += l;
				abs_terms += std::fabs(l);
				a = w.lat.vert_up[uint32_t(a)];
			}
			const double want = shifted(float(top + acc), c.mutate);
			const double bound = 2.0 * double(kNy + 2u) * kU * (abs_terms + std::fabs(top));
			c.examined += 1;
			if (!(std::fabs(double(got[g]) - want) <= bound)) {
				c.why = "the column a solid cell stands under is not the integral of rho g over the "
						"matter above it";
				return false;
			}
		}
	}
	return c.examined > 0;
}

// THE PRESSURE SPLIT: an open cell's pressure is the equation of state's, and this pass may not touch it.
bool prop_open_cells_untouched(Case &c) {
	std::string err;
	Rig rig(c.dev, "pressure", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(22);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rng, true);
		load(rig, w);
		Push p{ w.lat.cells(), w.p_top, kNy + 2u };
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> got = rig.get(LA_BIND_PRESSURE, w.lat.cells());
		for (uint32_t g = 0; g < w.lat.cells(); ++g) {
			if (w.solid[g] != 0.0f) { continue; }
			c.examined += 1;
			if (double(got[g]) != double(shifted(w.pressure[g], c.mutate))) {
				c.why = "the lithostatic pass wrote an open cell's pressure, which the equation of "
						"state owns";
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_pressure_properties(std::vector<Property> &out) {
	out.push_back({ "pressure.glsl", "pressure_column_is_the_integral_of_rho_g",
			prop_column_is_the_integral });
	out.push_back({ "pressure.glsl", "pressure_leaves_open_cells_alone", prop_open_cells_untouched });
}

} // namespace lasim
