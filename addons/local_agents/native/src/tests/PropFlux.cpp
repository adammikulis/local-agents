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

constexpr uint32_t kNx = 5;
constexpr uint32_t kNy = 5;
constexpr uint32_t kNz = 5;
constexpr float kEdgeM = 200.0f;
constexpr uint32_t kWords = 16384;

// flux.glsl's own pass tags, and active_levels.glsli's "no second group".
constexpr uint32_t kPassFlux = 0;
constexpr uint32_t kPassFace = 7;
constexpr uint32_t kActNoGroup = ~0u;

struct Push {
	uint32_t cell_count;
	uint32_t pass_id;
	uint32_t mode;
	uint32_t law;
	uint32_t band_count;
	uint32_t flags;
	float dt_s;
	float repose_tan;
	float density;
	float max_fill;
	float fluid_rho;
	float fluid_visc;
	float grain_d;
	float sun_x;
	float sun_y;
	float sun_z;
	float rho_water;
	float mu_water;
	float rho_air;
	float mu_air;
	float sub_cap_j_m3k;
	uint32_t total_count;
	float xuv_w_m2;
	uint32_t level;
	uint32_t substep_k;
	uint32_t substep_n;
	uint32_t act_group;
	uint32_t act_group2;
	float phi_datum;
	float grav_self;
};

struct Row {
	uint32_t mode;
	uint32_t law;
	uint32_t flags;
};

// The rows the transport table actually carries: what rides the flow, what mixes through it, what
// conducts, and the drift closures each of those can be given.
const Row kRows[] = {
	{ MODE_ADVECT, LAW_NONE, 0u },
	{ MODE_BOTH, LAW_EDDY, 0u },
	{ MODE_BOTH, LAW_EDDY, TF_FRACTION },
	{ MODE_DIFFUSE, LAW_EDDY, TF_DILUTE },
	{ MODE_CONDUCT, LAW_NONE, TF_ENERGY },
	{ MODE_ADVECT, LAW_SHALLOW, TF_SETTLE },
	{ MODE_ADVECT, LAW_DARCY, 0u },
	{ MODE_ADVECT, LAW_FILM, 0u },
	{ MODE_SEPARATE, LAW_OHMIC, 0u },
	{ MODE_POTENTIAL, LAW_NONE, 0u },
	{ MODE_ADVECT, LAW_NONE, TF_WATER },
};

Lattice lattice() {
	return Lattice::box(kNx, kNy, kNz, kEdgeM, 0.0f, 0.0f, 0.0f);
}

Push base_push(uint32_t cells) {
	Push p{};
	p.cell_count = cells;
	p.total_count = cells;
	p.band_count = 1;
	p.dt_s = 0.5f;
	p.repose_tan = 0.6f;
	p.density = 2900.0f;
	p.max_fill = 25000.0f;
	p.fluid_rho = 997.0f;
	p.fluid_visc = 1.0e-3f;
	p.grain_d = 1.0e-4f;
	p.sun_x = 1361.0f;
	p.rho_water = 997.0f;
	p.mu_water = 1.0e-3f;
	p.rho_air = 1.225f;
	p.mu_air = 1.8e-5f;
	p.xuv_w_m2 = 1.0e-3f;
	p.substep_n = 1;
	p.act_group2 = kActNoGroup;
	p.grav_self = 1.0f;
	return p;
}

// A cell of moist air over rock, every buffer the row's closures read given a value in its own range.
// `spread` 0 makes every cell identical, which is the state a face must carry nothing across.
void load_world(Rig &rig, const Lattice &lat, Rng &rng, float spread, float g_mag) {
	const uint32_t n = lat.cells();
	const uint32_t f = lat.faces();
	auto vary = [&](float mid, float rel) {
		return mid * (1.0f + spread * rel * (rng.unit() * 2.0f - 1.0f));
	};
	std::vector<float> v(n, 0.0f);
	auto put_all = [&](uint32_t binding, float mid, float rel) {
		for (uint32_t i = 0; i < n; ++i) { v[i] = vary(mid, rel); }
		rig.put(binding, v);
	};

	rig.put(LA_BIND_NBR, lat.nbr);
	rig.put(LA_BIND_FACE_PARTNER, lat.partner);
	rig.put(LA_BIND_SLOT_OFF, lat.slot_off);
	rig.put(LA_BIND_CELL_EDGE, lat.cell_edge);
	// The box edge is a shut wall here: a face onto space has no partner to be antisymmetric with.
	rig.put(LA_BIND_GHOST, std::vector<int32_t>(f, -1));
	rig.put(LA_BIND_RIM_GHOST, std::vector<int32_t>(n, -1));
	rig.zero(LA_BIND_RIM_W);

	std::vector<float> grav(size_t(n) * 3u, 0.0f);
	for (uint32_t i = 0; i < n; ++i) { grav[i * 3u + 1u] = -g_mag; }
	rig.put(LA_BIND_G_REST, grav);

	put_all(LA_BIND_TEMP, 288.0f, 0.15f);
	put_all(LA_BIND_TEMP_LITH, 290.0f, 0.15f);
	put_all(LA_BIND_PRESSURE, 101325.0f, 0.3f);
	put_all(LA_BIND_RHO_BULK, 1.225f, 0.4f);
	put_all(LA_BIND_GAS_R, 287.0f, 0.05f);
	put_all(LA_BIND_GAS_GAMMA, 1.4f, 0.05f);
	put_all(LA_BIND_K_COND, 2.2e9f, 0.2f);
	put_all(LA_BIND_CAP_SENSIBLE, 1.0e3f, 0.3f);
	put_all(LA_BIND_CAP_LITH, 2.0e6f, 0.3f);
	put_all(LA_BIND_N2, 32.0f, 0.2f);
	put_all(LA_BIND_O2, 8.0f, 0.2f);
	put_all(LA_BIND_CO2, 0.02f, 0.5f);
	put_all(LA_BIND_CH4, 1.0e-4f, 0.5f);
	put_all(LA_BIND_CO, 1.0e-5f, 0.5f);
	put_all(LA_BIND_H2, 1.0e-5f, 0.5f);
	put_all(LA_BIND_SO2, 1.0e-6f, 0.5f);
	put_all(LA_BIND_H2S, 1.0e-6f, 0.5f);
	put_all(LA_BIND_H2O, 0.5f, 0.6f);
	put_all(LA_BIND_H2O_LIQUID, 0.2f, 0.5f);
	put_all(LA_BIND_H2O_SOLID, 0.1f, 0.5f);
	put_all(LA_BIND_H2O_VAPOUR, 0.7f, 0.2f);
	put_all(LA_BIND_SILICATE, 10.0f, 0.5f);
	put_all(LA_BIND_SILICATE_MELT, 0.1f, 0.8f);
	put_all(LA_BIND_BIOMASS, 0.0f, 0.0f);
	put_all(LA_BIND_POROSITY, 0.2f, 0.5f);
	put_all(LA_BIND_GRAIN, 2.0e-4f, 0.5f);
	put_all(LA_BIND_CEMENT, 0.1f, 0.5f);
	put_all(LA_BIND_LATTICE_FRAC, 0.0f, 0.0f);
	put_all(LA_BIND_CHARGE, 0.0f, 0.0f);
	put_all(LA_BIND_GROUND_D, 0.0f, 0.0f);
	put_all(LA_BIND_GRAV_PHI, 0.0f, 0.0f);
	put_all(LA_BIND_GRAV_REF, -1.0e6f, 0.05f);
	put_all(LA_BIND_RAD_W_M3, 1.0e-6f, 0.5f);
	put_all(LA_BIND_FLUX_O3, 1.0e-8f, 0.5f);
	put_all(LA_BIND_FLUX_AMOUNT, 20.0f, 0.7f);
	put_all(LA_BIND_FLUX_ENERGY, 2.0e5f, 0.4f);
	put_all(LA_BIND_FLUX_H_CARRIED, 5.0e4f, 0.4f);
	put_all(LA_BIND_FLUX_RESIST, 0.2f, 0.8f);
	put_all(LA_BIND_FLUX_DRIVE, 288.0f, 0.2f);
	put_all(LA_BIND_FLUX_AUX, 2.0f, 0.5f);
	put_all(LA_BIND_FLUX_FRAC, 0.5f, 0.8f);
	put_all(LA_BIND_FLUX_RAD_TABLE, 0.0f, 0.0f);
	rig.zero(LA_BIND_SOLID);
	rig.zero(LA_BIND_FLUX_BND_AMT);
	rig.zero(LA_BIND_FLUX_BND_H);
	rig.zero(LA_BIND_FLUX_BND_Q);
	rig.zero(LA_BIND_FLUX_SEND);
	rig.zero(LA_BIND_FLUX_SW_KEEP);
	rig.zero(LA_BIND_FLUX_SW_SRC);
	rig.zero(LA_BIND_FLUX_SW_ABSORBED);
	rig.zero(LA_BIND_FLUX_LW_EMIS);
	rig.zero(LA_BIND_RAD_ABSORBED);

	// The motion: momentum and the velocity derived from it must agree, or the face states read one
	// cell moving and the crossing books another.
	std::vector<float> vx(n), vy(n), vz(n), mx(n), my(n), mz(n), sp(n);
	const std::vector<float> rho = rig.get(LA_BIND_RHO_BULK, n);
	for (uint32_t i = 0; i < n; ++i) {
		vx[i] = spread * rng.range(-8.0f, 8.0f);
		vy[i] = spread * rng.range(-3.0f, 3.0f);
		vz[i] = spread * rng.range(-8.0f, 8.0f);
		mx[i] = rho[i] * vx[i];
		my[i] = rho[i] * vy[i];
		mz[i] = rho[i] * vz[i];
		sp[i] = std::sqrt(vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
	}
	rig.put(LA_BIND_VEL_X, vx);
	rig.put(LA_BIND_VEL_Y, vy);
	rig.put(LA_BIND_VEL_Z, vz);
	rig.put(LA_BIND_MOM_X, mx);
	rig.put(LA_BIND_MOM_Y, my);
	rig.put(LA_BIND_MOM_Z, mz);
	rig.put(LA_BIND_SPEED, sp);
	rig.zero(LA_BIND_BODYF_X);
	rig.zero(LA_BIND_BODYF_Y);
	rig.zero(LA_BIND_BODYF_Z);

	// EVERY CELL AWAKE AND LISTED, on one temporal level: the whole box steps together.
	rig.zero(LA_BIND_TLEVEL);
	rig.zero(LA_BIND_ACT_QUIET);
	rig.fill(LA_BIND_ACT_CLAIM, uint32_t(2)); // active_levels.glsli CLAIM_LISTED
	rig.zero(LA_BIND_LEVEL_ARGS);
	rig.zero(LA_BIND_LEVEL_IDX);
	rig.zero(LA_BIND_LEVEL_PEAK);
	rig.zero(LA_BIND_ACTIVE_ARGS);
	rig.zero(LA_BIND_ACTIVE_IDX);
	rig.zero(LA_BIND_ACT_QUEUE);
	rig.zero(LA_BIND_ACT_WAKE);
	rig.zero(LA_BIND_ACT_WAKE_ARGS);
}

void run_row(Rig &rig, const Lattice &lat, const Row &row) {
	Push p = base_push(lat.cells());
	p.mode = row.mode;
	p.law = row.law;
	p.flags = row.flags;
	p.pass_id = kPassFace;
	rig.run(&p, sizeof(p), lat.cells());
	p.pass_id = kPassFlux;
	rig.run(&p, sizeof(p), lat.cells());
}

// THE INTERFACE VELOCITY IS ONE NUMBER. Both cells solve the same acoustic interface, in the same
// canonical orientation, so one side's reading is the exact negation of the other's.
bool prop_face_velocity_antisymmetric(Case &c) {
	std::string err;
	Rig rig(c.dev, "flux", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	const Lattice lat = lattice();
	Rng rng(c.seed);
	rng.stream(41);
	uint32_t moving = 0;
	for (const Row &row : kRows) {
		load_world(rig, lat, rng, 1.0f, 9.80665f);
		run_row(rig, lat, row);
		const std::vector<float> u = rig.get(LA_BIND_FLUX_FACE_U, lat.faces());
		const std::vector<float> uw = rig.get(LA_BIND_FLUX_FACE_UW, lat.faces());
		for (uint32_t f = 0; f < lat.faces(); ++f) {
			const int32_t back = lat.partner[f];
			if (back < 0) { continue; }
			c.examined += 1;
			if (u[f] != 0.0f) { ++moving; }
			const double mine = double(shifted(u[f], c.mutate));
			if (mine != -double(u[uint32_t(back)])
					|| double(shifted(uw[f], c.mutate)) != -double(uw[uint32_t(back)])) {
				char buf[192];
				std::snprintf(buf, sizeof(buf),
						"mode %u law %u face %u/%d: the two sides of a face read different interface "
						"velocities",
						row.mode, row.law, f, back);
				c.why = buf;
				return false;
			}
		}
	}
	// A box in which nothing moved would pass this by carrying zeros.
	if (moving == 0) {
		c.why = "no face carried an interface velocity, so nothing was compared";
		return false;
	}
	return c.examined > 0;
}

// A CROSSING TAKES FROM ONE CELL WHAT IT GIVES THE OTHER. Per row, per face: matter, the enthalpy it
// carries and the charge it carries, each the exact negation across the pair.
bool prop_crossings_are_antisymmetric(Case &c) {
	std::string err;
	Rig rig(c.dev, "flux", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	const Lattice lat = lattice();
	Rng rng(c.seed);
	rng.stream(42);
	uint32_t carrying = 0;
	for (const Row &row : kRows) {
		load_world(rig, lat, rng, 1.0f, 9.80665f);
		run_row(rig, lat, row);
		const std::vector<float> amt = rig.get(LA_BIND_FLUX_X_AMT, lat.faces());
		const std::vector<float> h = rig.get(LA_BIND_FLUX_X_H, lat.faces());
		const std::vector<float> q = rig.get(LA_BIND_FLUX_X_Q, lat.faces());
		for (uint32_t f = 0; f < lat.faces(); ++f) {
			const int32_t back = lat.partner[f];
			if (back < 0) { continue; }
			const uint32_t b = uint32_t(back);
			c.examined += 1;
			if (amt[f] != 0.0f) { ++carrying; }
			if (double(shifted(amt[f], c.mutate)) != -double(amt[b])
					|| double(shifted(h[f], c.mutate)) != -double(h[b])
					|| double(shifted(q[f], c.mutate)) != -double(q[b])) {
				char buf[192];
				std::snprintf(buf, sizeof(buf),
						"mode %u law %u flags %u: a crossing does not remove from the donor what it "
						"adds to the receiver",
						row.mode, row.law, row.flags);
				c.why = buf;
				return false;
			}
		}
	}
	if (carrying == 0) {
		c.why = "no row moved anything, so the books were never asked to close";
		return false;
	}
	return c.examined > 0;
}

// EQUAL STATES ON BOTH SIDES AND NO BODY FORCE: nothing drives a crossing, so nothing crosses.
bool prop_equal_states_carry_nothing(Case &c) {
	std::string err;
	Rig rig(c.dev, "flux", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	const Lattice lat = lattice();
	Rng rng(c.seed);
	rng.stream(43);
	for (const Row &row : kRows) {
		load_world(rig, lat, rng, 0.0f, 0.0f);
		run_row(rig, lat, row);
		const std::vector<float> amt = rig.get(LA_BIND_FLUX_X_AMT, lat.faces());
		const std::vector<float> h = rig.get(LA_BIND_FLUX_X_H, lat.faces());
		const std::vector<float> u = rig.get(LA_BIND_FLUX_FACE_U, lat.faces());
		for (uint32_t f = 0; f < lat.faces(); ++f) {
			if (lat.partner[f] < 0) { continue; }
			c.examined += 1;
			const double zero = double(shifted(0.0f, c.mutate));
			if (double(amt[f]) != zero || double(h[f]) != zero || double(u[f]) != zero) {
				char buf[192];
				std::snprintf(buf, sizeof(buf),
						"mode %u law %u flags %u face %u: a face between two cells in the same state "
						"carried something",
						row.mode, row.law, row.flags, f);
				c.why = buf;
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_flux_properties(std::vector<Property> &out) {
	out.push_back({ "flux.glsl", "flux_face_velocity_is_antisymmetric",
			prop_face_velocity_antisymmetric });
	out.push_back({ "flux.glsl", "flux_crossings_are_antisymmetric", prop_crossings_are_antisymmetric });
	out.push_back({ "flux.glsl", "flux_equal_states_carry_nothing", prop_equal_states_carry_nothing });
}

} // namespace lasim
