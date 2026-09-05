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

constexpr uint32_t kN = 4;
constexpr float kEdgeM = 300.0f;
constexpr uint32_t kWords = 8192;
constexpr uint32_t kDraws = 6;
constexpr double kU = 5.9604645e-8;
// CODATA vacuum electric permittivity, F/m.
constexpr double kEps0 = 8.8541878128e-12;

struct Push {
	uint32_t cell_count;
	uint32_t n_records;
	uint32_t pad0;
	uint32_t pad1;
	float sun_x;
	float sun_y;
	float sun_z;
	uint32_t pad2;
};

// Every channel the record table may draw on or credit, plus the energy the heat of reaction lands in.
const uint32_t kMoved[] = { LA_BIND_H2O, LA_BIND_O2, LA_BIND_CO2, LA_BIND_FUEL, LA_BIND_DETRITUS,
	LA_BIND_FUNGUS, LA_BIND_FERT, LA_BIND_BIOMASS, LA_BIND_SILICATE, LA_BIND_CARBONATE,
	LA_BIND_SILICA, LA_BIND_N2, LA_BIND_ORG_H, LA_BIND_ORG_O, LA_BIND_E_J_M3 };

struct World {
	Lattice lat = Lattice::box(kN, kN, kN, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<std::vector<float>> moved;
	std::vector<float> col_e;
	std::vector<float> strike;
};

World load(Rig &rig, Rng &rng) {
	World w;
	const uint32_t n = w.lat.cells();
	rig.put(LA_BIND_CELL_EDGE, w.lat.cell_edge);
	rig.put(LA_BIND_VERT_UP, w.lat.vert_up);
	rig.put(LA_BIND_VERT_DOWN, w.lat.vert_down);
	std::vector<float> grav(size_t(n) * 3u, 0.0f);
	for (uint32_t i = 0; i < n; ++i) { grav[i * 3u + 1u] = -9.80665f; }
	rig.put(LA_BIND_GRAVITY, grav);

	std::vector<float> v(n, 0.0f);
	auto put = [&](uint32_t binding, float lo, float hi) {
		for (uint32_t i = 0; i < n; ++i) { v[i] = rng.decades(lo, hi); }
		rig.put(binding, v);
		return v;
	};
	w.moved.reserve(sizeof(kMoved) / sizeof(kMoved[0]));
	for (uint32_t b : kMoved) { w.moved.push_back(put(b, 1.0e-3f, 1.0e4f)); }
	put(LA_BIND_TEMP, 200.0f, 400.0f);
	put(LA_BIND_PRESSURE, 1.0e3f, 1.0e7f);
	put(LA_BIND_GRAIN, 1.0e-5f, 1.0e-2f);
	put(LA_BIND_REGOLITH, 0.5f, 1.0f);
	put(LA_BIND_H2O_SOLID, 0.05f, 0.3f);
	put(LA_BIND_H2O_LIQUID, 0.2f, 0.5f);
	put(LA_BIND_H2O_VAPOUR, 0.2f, 0.5f);
	put(LA_BIND_VEL_X, 0.1f, 10.0f);
	put(LA_BIND_VEL_Y, 0.1f, 10.0f);
	put(LA_BIND_VEL_Z, 0.1f, 10.0f);
	rig.zero(LA_BIND_SOLID);
	rig.zero(LA_BIND_FIRE);
	rig.zero(LA_BIND_ACT_WAKE);
	rig.zero(LA_BIND_ACT_WAKE_ARGS);
	rig.zero(LA_BIND_REACTION_DEFS);
	// The stroke: a field standing in half the cells, none in the rest.
	w.col_e.resize(n);
	w.strike.resize(n);
	for (uint32_t i = 0; i < n; ++i) {
		w.col_e[i] = rng.sign() * rng.decades(1.0e3f, 1.0e6f);
		w.strike[i] = rng.chance(0.5f) ? 1.0f : 0.0f;
	}
	rig.put(LA_BIND_COL_E, w.col_e);
	rig.put(LA_BIND_STRIKE, w.strike);
	return w;
}

Push push_for(const World &w, uint32_t records) {
	Push p{};
	p.cell_count = w.lat.cells();
	p.n_records = records;
	p.sun_x = 1361.0f;
	return p;
}

// AN EMPTY TABLE IS AN EMPTY CHEMISTRY: with no record to fire, no channel and no energy may move.
bool prop_no_records_move_nothing(Case &c) {
	std::string err;
	Rig rig(c.dev, "reactions_sphere3d", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(51);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = load(rig, rng);
		const Push p = push_for(w, 0);
		rig.run(&p, sizeof(p), w.lat.cells());
		for (size_t b = 0; b < w.moved.size(); ++b) {
			const std::vector<float> got = rig.get(kMoved[b], w.lat.cells());
			for (uint32_t i = 0; i < w.lat.cells(); ++i) {
				c.examined += 1;
				if (double(got[i]) != double(shifted(w.moved[b][i], c.mutate))) {
					char buf[160];
					std::snprintf(buf, sizeof(buf),
							"binding %u moved with no reaction record in the table", kMoved[b]);
					c.why = buf;
					return false;
				}
			}
		}
	}
	return c.examined > 0;
}

// THE STROKE'S STORE is the energy density of the field it relaxes, half epsilon-nought E squared, and
// nothing where no strike stands.
bool prop_discharge_is_the_field_energy(Case &c) {
	std::string err;
	Rig rig(c.dev, "reactions_sphere3d", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(52);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = load(rig, rng);
		const Push p = push_for(w, 0);
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> got = rig.get(LA_BIND_DISCHARGE, w.lat.cells());
		for (uint32_t i = 0; i < w.lat.cells(); ++i) {
			const double e = double(w.col_e[i]);
			const double want = w.strike[i] > 0.0f ? 0.5 * kEps0 * e * e : 0.0;
			c.examined += 1;
			if (!std::isfinite(double(got[i]))) {
				c.why = "the stroke's store came back non-finite for a finite field";
				return false;
			}
			if (!(std::fabs(double(shifted(got[i], c.mutate)) - want) <= 4.0 * kU * want)) {
				c.why = "the energy the stroke relaxes is not half epsilon-nought E squared";
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_reaction_properties(std::vector<Property> &out) {
	out.push_back({ "reactions_sphere3d.glsl", "reactions_with_no_records_move_nothing",
			prop_no_records_move_nothing });
	out.push_back({ "reactions_sphere3d.glsl", "reactions_discharge_is_the_field_energy",
			prop_discharge_is_the_field_energy });
}

} // namespace lasim
