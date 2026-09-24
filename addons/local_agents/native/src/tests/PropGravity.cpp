#include "Channels.hpp"
#include "Lattice.hpp"
#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace lasim {
namespace {

constexpr uint32_t kN = 10; // cells on a side
constexpr float kEdgeM = 400.0f;
constexpr uint32_t kWords = 16384;
constexpr uint32_t kDraws = 4;
constexpr double kU = 5.9604645e-8;
constexpr float kG = 6.67430e-11f; // CODATA gravitational constant, m^3 kg^-1 s^-2

// gravity_poisson.glsl's own mode tags and PART_STRIDE.
constexpr uint32_t kModeFlags = 0;
constexpr uint32_t kModeDensity = 1;
constexpr uint32_t kModeMoments = 2;
constexpr uint32_t kModeSeed = 3;
constexpr uint32_t kModeGradient = 5;
constexpr uint32_t kFlagBoundary = 1;

struct Push {
	uint32_t cell_count;
	uint32_t mode;
	uint32_t colour;
	uint32_t groups;
	float g_si;
	float base_edge;
	float ox;
	float oy;
	float oz;
	float r_datum;
	// chunk.glsli: the whole dispatch in one submit.
	uint32_t chunk_stride = 1;
	uint32_t chunk_phase = 0;
};

struct World {
	Lattice lat = Lattice::box(kN, kN, kN, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<std::vector<float>> channel;
	std::vector<float> mol_mass;
	float r_datum = 0.0f;
	float sphere_r = 0.0f;
	float centre[3] = { 0.0f, 0.0f, 0.0f };
};

// A UNIFORM SPHERE of one mineral at the box centre, and empty space around it.
World draw(Rng &rng) {
	World w;
	const uint32_t n = w.lat.cells();
	w.channel.assign(kChannelSlots, std::vector<float>(n, 0.0f));
	w.mol_mass.assign(kChannelSlots, 0.0f);
	for (uint32_t i = 0; i < kChannelSlots; ++i) { w.mol_mass[i] = rng.range(0.002f, 0.3f); }
	const float half = 0.5f * float(kN) * kEdgeM;
	w.centre[0] = half;
	w.centre[1] = half;
	w.centre[2] = half;
	w.sphere_r = 2.5f * kEdgeM;
	const uint32_t which = rng.below(kChannelSlots);
	const float amount = rng.decades(1.0e2f, 1.0e5f);
	for (uint32_t c = 0; c < n; ++c) {
		const float dx = w.lat.pos[c * 3u] - w.centre[0];
		const float dy = w.lat.pos[c * 3u + 1u] - w.centre[1];
		const float dz = w.lat.pos[c * 3u + 2u] - w.centre[2];
		if (std::sqrt(dx * dx + dy * dy + dz * dz) <= w.sphere_r) { w.channel[which][c] = amount; }
	}
	w.r_datum = rng.decades(1.0e3f, 1.0e7f);
	return w;
}

void load(Rig &rig, const World &w) {
	rig.put(LA_BIND_NBR, w.lat.nbr);
	rig.put(LA_BIND_FACE_PARTNER, w.lat.partner);
	rig.put(LA_BIND_SLOT_OFF, w.lat.slot_off);
	rig.put(LA_BIND_CELL_EDGE, w.lat.cell_edge);
	rig.put(LA_BIND_POS, w.lat.pos);
	rig.put(LA_BIND_VERT_UP, w.lat.vert_up);
	rig.put(LA_BIND_VERT_DOWN, w.lat.vert_down);
	rig.put(LA_BIND_GRAV_PROPS, w.mol_mass);
	for (uint32_t i = 0; i < kChannelSlots; ++i) { rig.put(kChannelBinding[i], w.channel[i]); }
	// The deviation from the reference is zero everywhere: the reference alone is what is asserted.
	rig.zero(LA_BIND_GRAV_PHI);
	rig.zero(LA_BIND_GRAV_MOMENTS);
	rig.zero(LA_BIND_GRAV_PARTIALS);
}

Push base_push(const World &w, Rig &rig) {
	Push p{};
	p.cell_count = w.lat.cells();
	p.groups = rig.groups_for(w.lat.cells());
	p.g_si = kG;
	p.base_edge = kEdgeM;
	p.ox = 0.0f;
	p.oy = 0.0f;
	p.oz = 0.0f;
	p.r_datum = w.r_datum;
	return p;
}

void step(Rig &rig, Push p, uint32_t mode, uint32_t threads) {
	p.mode = mode;
	rig.run(&p, sizeof(p), threads);
}

// A cell's colour must differ from every cell it shares a face with, or one relaxation sweep reads a
// potential the same sweep is writing.
bool prop_colours_never_touch(Case &c) {
	std::string err;
	Rig rig(c.dev, "gravity_poisson", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(31);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rng);
		load(rig, w);
		const Push p = base_push(w, rig);
		step(rig, p, kModeFlags, w.lat.cells());
		const std::vector<uint32_t> flag = rig.get_u(LA_BIND_GRAV_CELLFLAG, w.lat.cells());
		for (uint32_t cell = 0; cell < w.lat.cells(); ++cell) {
			for (uint32_t s = 0; s < 6u; ++s) {
				const int32_t nb = w.lat.step(cell, s);
				if (nb < 0) { continue; }
				const uint32_t mine = (flag[cell] >> 1u) & 3u;
				const uint32_t theirs = c.mutate ? mine : ((flag[uint32_t(nb)] >> 1u) & 3u);
				c.examined += 1;
				if (mine == theirs) {
					c.why = "two cells that share a face carry the same relaxation colour";
					return false;
				}
			}
		}
	}
	return c.examined > 0;
}

// The mass the solve sources is the mass the box holds, and its centre is where that mass is.
bool prop_moments_are_the_boxs_mass(Case &c) {
	std::string err;
	Rig rig(c.dev, "gravity_poisson", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(32);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rng);
		load(rig, w);
		const Push p = base_push(w, rig);
		step(rig, p, kModeFlags, w.lat.cells());
		step(rig, p, kModeDensity, w.lat.cells());
		step(rig, p, kModeMoments, 64);
		const std::vector<float> mom = rig.get(LA_BIND_GRAV_MOMENTS, 8);
		const double vol = double(kEdgeM) * double(kEdgeM) * double(kEdgeM);
		double mass = 0.0;
		double com[3] = { 0.0, 0.0, 0.0 };
		for (uint32_t cell = 0; cell < w.lat.cells(); ++cell) {
			double rho = 0.0;
			for (uint32_t i = 0; i < kChannelSlots; ++i) {
				rho += std::fmax(double(w.channel[i][cell]), 0.0) * double(w.mol_mass[i]);
			}
			const double m = rho * vol;
			mass += m;
			for (uint32_t k = 0; k < 3u; ++k) { com[k] += m * double(w.lat.pos[cell * 3u + k]); }
		}
		if (!(mass > 0.0)) {
			c.why = "the draw put no mass in the box, so the moments were never asked anything";
			return false;
		}
		for (uint32_t k = 0; k < 3u; ++k) { com[k] /= mass; }
		// The kernel folds the per-cell masses in float32 through a workgroup tree and then across the
		// groups; the depth is six halvings per stage.
		const double bound = 2.0 * (6.0 + 6.0 + 2.0) * kU * mass;
		c.examined += 1;
		if (!(std::fabs(double(shifted(mom[0], c.mutate)) - mass) <= bound)) {
			c.why = "the mass the gravity solve sources is not the mass the box holds";
			return false;
		}
		const double span = double(kN) * double(kEdgeM);
		for (uint32_t k = 0; k < 3u; ++k) {
			c.examined += 1;
			if (!(std::fabs(double(shifted(mom[1 + k], c.mutate)) - com[k]) <= bound / mass * span)) {
				c.why = "the centre of mass the solve states is not where the mass is";
				return false;
			}
		}
	}
	return c.examined > 0;
}

// The seeded reference is the monopole potential of the mass the box holds, stated against the datum.
bool prop_reference_is_the_monopole(Case &c) {
	std::string err;
	Rig rig(c.dev, "gravity_poisson", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(33);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rng);
		load(rig, w);
		const Push p = base_push(w, rig);
		step(rig, p, kModeFlags, w.lat.cells());
		step(rig, p, kModeDensity, w.lat.cells());
		step(rig, p, kModeMoments, 64);
		step(rig, p, kModeSeed, w.lat.cells());
		const std::vector<float> mom = rig.get(LA_BIND_GRAV_MOMENTS, 8);
		const std::vector<float> ref = rig.get(LA_BIND_GRAV_REF, w.lat.cells());
		const double total = double(mom[0]);
		for (uint32_t cell = 0; cell < w.lat.cells(); ++cell) {
			double r2 = 0.0;
			for (uint32_t k = 0; k < 3u; ++k) {
				const double q = double(w.lat.pos[cell * 3u + k]) - double(mom[1 + k]);
				r2 += q * q;
			}
			const double r = std::fmax(std::sqrt(r2), double(kEdgeM));
			const double datum = std::fmax(double(w.r_datum), double(kEdgeM));
			const double want = -double(kG) * total * (1.0 / r - 1.0 / datum);
			const double scale = double(kG) * total * (1.0 / r + 1.0 / datum);
			c.examined += 1;
			if (!(std::fabs(double(shifted(ref[cell], c.mutate)) - want) <= 8.0 * kU * scale)) {
				c.why = "the seeded reference is not the monopole potential of the mass the box holds";
				return false;
			}
		}
	}
	return c.examined > 0;
}

// OUTSIDE A UNIFORM SPHERE the field is G M / r^2 inward, which is what the seeded reference's own
// gradient must return, to the second-order bound of the central difference that takes it.
bool prop_field_outside_a_sphere(Case &c) {
	std::string err;
	Rig rig(c.dev, "gravity_poisson", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(34);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = draw(rng);
		load(rig, w);
		const Push p = base_push(w, rig);
		step(rig, p, kModeFlags, w.lat.cells());
		step(rig, p, kModeDensity, w.lat.cells());
		step(rig, p, kModeMoments, 64);
		step(rig, p, kModeSeed, w.lat.cells());
		step(rig, p, kModeGradient, w.lat.cells());
		const std::vector<float> mom = rig.get(LA_BIND_GRAV_MOMENTS, 8);
		const std::vector<uint32_t> flag = rig.get_u(LA_BIND_GRAV_CELLFLAG, w.lat.cells());
		const std::vector<float> g = rig.get(LA_BIND_GRAVITY, size_t(w.lat.cells()) * 3u);
		const double total = double(mom[0]);
		const double h = double(kEdgeM);
		for (uint32_t cell = 0; cell < w.lat.cells(); ++cell) {
			// A boundary cell's derivative is one-sided, which is a different bound; the shell theorem
			// speaks only outside the sphere, and only two cells out is the difference stencil clear of it.
			if ((flag[cell] & kFlagBoundary) != 0u) { continue; }
			double rv[3];
			double r2 = 0.0;
			for (uint32_t k = 0; k < 3u; ++k) {
				rv[k] = double(w.lat.pos[cell * 3u + k]) - double(mom[1 + k]);
				r2 += rv[k] * rv[k];
			}
			const double r = std::sqrt(r2);
			if (r < double(w.sphere_r) + 2.0 * h) { continue; }
			// Central difference of -GM/r over 2h departs by at most (h^2/6)|d3phi/dx3| per component,
			// and |d3phi/dx3| <= 6 G M / r^4.
			const double bound = std::sqrt(3.0) * double(kG) * total * h * h / (r2 * r2)
					+ 16.0 * kU * double(kG) * total / r2;
			double err2 = 0.0;
			for (uint32_t k = 0; k < 3u; ++k) {
				const double want = -double(kG) * total * rv[k] / (r2 * r);
				const double diff = double(shifted(g[cell * 3u + k], c.mutate)) - want;
				err2 += diff * diff;
			}
			c.examined += 1;
			if (!(std::sqrt(err2) <= bound)) {
				c.why = "the field outside the sphere is not G M / r^2 toward its centre";
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_gravity_properties(std::vector<Property> &out) {
	out.push_back({ "gravity_poisson.glsl", "gravity_colours_never_touch", prop_colours_never_touch });
	out.push_back({ "gravity_poisson.glsl", "gravity_moments_are_the_boxs_mass",
			prop_moments_are_the_boxs_mass });
	out.push_back({ "gravity_poisson.glsl", "gravity_reference_is_the_monopole",
			prop_reference_is_the_monopole });
	out.push_back({ "gravity_poisson.glsl", "gravity_field_outside_a_sphere_is_inverse_square",
			prop_field_outside_a_sphere });
}

} // namespace lasim
