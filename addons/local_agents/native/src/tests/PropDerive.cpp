#include "Channels.hpp"
#include "Lattice.hpp"
#include "Property.hpp"
#include "Rig.hpp"
#include "Rng.hpp"

#include "LABirchMurnaghan.hpp"
#include "LAMeltingLine.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace lasim {
namespace {

constexpr uint32_t kN = 4;
constexpr float kEdgeM = 500.0f;
constexpr uint32_t kWords = 8192;
constexpr uint32_t kDraws = 4;

// state_derive.glsl's per-channel substance table: PROP_STRIDE words per channel, then the detection
// thresholds. scripts/check_kernel_properties.sh holds these to the kernel's own declarations.
constexpr uint32_t kPropStride = 79;
constexpr uint32_t kPropM = 0;
constexpr uint32_t kPropMolPerKg = 1;
constexpr uint32_t kPropEntry = 2;
constexpr uint32_t kPropLambda = 3;
constexpr uint32_t kPropFull = 4;
constexpr uint32_t kPropLithic = 5;
constexpr uint32_t kPropRadGroup = 6;
constexpr uint32_t kPropCondensed = 7;
// The solid's and the melt's equation-of-state blocks.
constexpr uint32_t kPropSolid = 8;
constexpr uint32_t kPropLiquid = 17;
constexpr uint32_t kPhFull = 0;
constexpr uint32_t kPhAlpha = 1;
constexpr uint32_t kPhBulk = 2;
constexpr uint32_t kPhKp = 3;
constexpr uint32_t kPhB4 = 4;
constexpr uint32_t kPhTref = 5;
constexpr uint32_t kPhLinear = 6;
constexpr uint32_t kPhFLo = 7;
constexpr uint32_t kPhFHi = 8;
// The channel's own phase ladder, from PROP_LADDER: every condensed channel melts where its row says.
constexpr uint32_t kPropLadder = 26;
constexpr uint32_t kThCSol = 0;
constexpr uint32_t kThCLiq = 1;
constexpr uint32_t kThCGas = 2;
constexpr uint32_t kThLineA1 = 3;
constexpr uint32_t kThLineP0 = 4;
constexpr uint32_t kThFusionT0 = 5;
constexpr uint32_t kThFusionT1 = 6;
constexpr uint32_t kThLFus = 13;
constexpr uint32_t kThNu = 19;
constexpr uint32_t kThHasFusion = 20;
constexpr uint32_t kThNEl = 23;
constexpr uint32_t kThElN = 24;
constexpr uint32_t kThLineKind = 44;
constexpr uint32_t kThLineT0 = 45;
constexpr uint32_t kThLineC1 = 46;
constexpr uint32_t kThLineA2 = 47;
constexpr uint32_t kThLineC2 = 48;
constexpr uint32_t kThAnchorPhase = 49;
constexpr uint32_t kThAnchorT = 50;
constexpr uint32_t kThLinePref = 51;
constexpr uint32_t kThCritT = 11;
constexpr uint32_t kThCritP = 12;
constexpr uint32_t kThPrKappa = 52;
constexpr uint32_t kDetSlots = 5;

// What check_derive_fixed_point.sh declares a second pass may move: float32 on the pressure, and the
// ladder's own last bit on the temperature.
constexpr double kTolK = 1.0e-3;
constexpr double kTolPRel = 1.0e-5;
// The ladder settles the room and the pressure to LA_STATE_TOL, and every enthalpy on the way is
// float32; the round trip carries both.
constexpr double kTolEnthalpyRel = 1.0e-4;
// The latent step is read off two branch extrapolations, each carrying the ladder's own float32.
constexpr double kTolLatentRel = 3.0e-4;

struct Push {
	uint32_t cell_count;
	float dt_s;
	float omega_x;
	float omega_y;
	float omega_z;
	float centre_x;
	float centre_y;
	float centre_z;
	float fresh_grain_m;
	float lith_rate_per_pa;
	float lith_pressure_pa;
	float fresh_h_per_c;
	float fresh_o_per_c;
	float rad_w_kg_1;
	float rad_w_kg_2;
	float rad_w_kg_3;
	float rad_w_kg_4;
	float sea_radius_m;
	float grav_self;
	uint32_t lithify;
	uint32_t detect;
	uint32_t restate;
	uint32_t args_slot;
	uint32_t act_base;
};

// Everything the derive states about a cell, from its matter and its energy.
const uint32_t kDerived[] = { LA_BIND_TEMP, LA_BIND_TEMP_LITH, LA_BIND_PRESSURE, LA_BIND_P_FLUID,
	LA_BIND_RHO_BULK, LA_BIND_CONDUCTIVITY, LA_BIND_CONDUCTIVITY_LITH, LA_BIND_CAP_SENSIBLE,
	LA_BIND_CAP_LITH, LA_BIND_LATTICE_FRAC, LA_BIND_H_H2O, LA_BIND_H_H2O_VAP, LA_BIND_H_SILICATE,
	LA_BIND_H_SENSIBLE, LA_BIND_KE_J_M3, LA_BIND_PE_J_M3, LA_BIND_K_COND, LA_BIND_GAS_R,
	LA_BIND_GAS_GAMMA, LA_BIND_LITHIC_FRAC, LA_BIND_LITHIC_KG, LA_BIND_H2O_SOLID, LA_BIND_H2O_LIQUID,
	LA_BIND_H2O_VAPOUR, LA_BIND_SILICATE_MELT, LA_BIND_LIQUID, LA_BIND_VEL_X, LA_BIND_VEL_Y,
	LA_BIND_VEL_Z, LA_BIND_SPEED, LA_BIND_E_J_M3, LA_BIND_E_LITH_J_M3, LA_BIND_RAD_W_M3,
	LA_BIND_G_REST, LA_BIND_BODYF_X, LA_BIND_BODYF_Y, LA_BIND_BODYF_Z, LA_BIND_LAT, LA_BIND_ALT,
	LA_BIND_ORG_HC, LA_BIND_ORG_OC, LA_BIND_ORG_FRESH };

struct World {
	Lattice lat = Lattice::box(kN, kN, kN, kEdgeM, 0.0f, 0.0f, 0.0f);
	std::vector<float> props;
	std::vector<float> energy;
	std::vector<float> pressure;
	float sea_radius = 0.0f;
};

// A melting line of `kind` rising from the row's melting point at one atmosphere, over the span the table's
// lines cover: flat Clapeyron, Simon, and both reduced forms.
void draw_line(Rng &rng, std::vector<float> &p, uint32_t t, uint32_t kind) {
	const float p_ref = 101325.0f;
	p[t + kThLineKind] = float(kind);
	p[t + kThLinePref] = p_ref;
	p[t + kThLineP0] = p_ref;
	p[t + kThLineT0] = p[t + kThFusionT0] + 273.15f;
	p[t + kThLineA1] = 0.0f;
	p[t + kThLineC1] = 1.0f;
	p[t + kThLineA2] = 0.0f;
	p[t + kThLineC2] = 1.0f;
	if (kind == 1) {
		p[t + kThLineA1] = rng.decades(1.0e8f, 1.0e10f);
		p[t + kThLineC1] = rng.range(1.5f, 2.5f);
	} else if (kind >= 2) {
		p[t + kThLineA1] = rng.decades(1.0e3f, 1.0e5f);
		p[t + kThLineC1] = rng.range(1.0f, 2.0f);
		p[t + kThLineA2] = rng.chance(0.5f) ? rng.decades(1.0e2f, 1.0e4f) : 0.0f;
		p[t + kThLineC2] = 2.0f;
	}
}

// A substance table shaped like a real one — a molar mass, a heat capacity, a mixture entry, a fullness
// — with every row's numbers drawn rather than quoted: the properties below hold for any of them.
std::vector<float> draw_props(Rng &rng) {
	std::vector<float> p(kChannelSlots * kPropStride + kDetSlots, 0.0f);
	for (uint32_t i = 0; i < kChannelSlots; ++i) {
		const uint32_t b = i * kPropStride;
		const float m = rng.range(0.002f, 0.3f);
		const bool condensed = rng.chance(0.5f);
		// Fullness is the substance's own density over its molar mass, so a mole takes the volume its
		// density says it does: a table drawn any other way describes no matter.
		const float rho = condensed ? rng.range(500.0f, 8.0e3f) : rng.range(0.05f, 5.0f);
		p[b + kPropM] = m;
		p[b + kPropMolPerKg] = condensed ? 0.0f : 1.0f / m;
		// Three heat buffers, the ones transport carries; every channel's ENTHALPY is its own ladder's.
		p[b + kPropEntry] = i == 0 ? 0.0f : (i == 1 ? 1.0f : 2.0f);
		p[b + kPropLambda] = rng.decades(0.02f, 5.0f);
		p[b + kPropFull] = rho / m;
		const float alpha = rng.decades(1.0e-5f, 3.0e-4f);
		const float bulk = rng.decades(1.0e9f, 2.0e11f);
		const float tref = rng.range(0.0f, 25.0f);
		// A density linear in T only where it stays positive over the drawn temperatures.
		const bool linear = alpha < 1.0e-4f && rng.chance(0.5f);
		p[b + kPropLithic] = (condensed && rng.chance(0.5f)) ? 1.0f : 0.0f;
		p[b + kPropRadGroup] = float(rng.below(5));
		p[b + kPropCondensed] = condensed ? 1.0f : 0.0f;
		// The span the measured rows cover, halite to orthoenstatite.
		const float kp = rng.range(3.3f, 8.7f);
		// Fourth order half the time, K'' within the span the measured melts cover, -K'/K0 to +K'/K0.
		const double b4 = rng.chance(0.5f)
				? la_bm::b4(bulk, kp, double(rng.range(-1.0f, 1.0f)) * kp / bulk, true) : 0.0;
		double f_lo = 0.0;
		double f_hi = 0.0;
		la_bm::bracket(kp, b4, f_lo, f_hi);
		// Solid and melt alike, so neither the melting curve nor the volume jumps across it.
		for (uint32_t blk : { kPropSolid, kPropLiquid }) {
			p[b + blk + kPhFull] = condensed ? rho / m : 0.0f;
			p[b + blk + kPhAlpha] = alpha;
			p[b + blk + kPhBulk] = bulk;
			p[b + blk + kPhKp] = kp;
			p[b + blk + kPhB4] = float(b4);
			p[b + blk + kPhTref] = tref;
			p[b + blk + kPhLinear] = linear ? 1.0f : 0.0f;
			p[b + blk + kPhFLo] = float(f_lo);
			p[b + blk + kPhFHi] = float(f_hi);
		}
		// A LADDER PER CHANNEL. A condensed phase melts: a solidus, a liquidus at or above it, and the
		// fusion enthalpy it costs to cross. Neither solid nor melt is compressed here, so the melting
		// curve has no Clapeyron slope and the plateau stands at one temperature.
		const uint32_t t = b + kPropLadder;
		// A gas is a Peng-Robinson fluid over the span the table's gases cover, hydrogen to water: its
		// critical point and its kappa.
		if (!condensed) {
			p[t + kThCritT] = rng.range(33.0f, 650.0f) - 273.15f;
			p[t + kThCritP] = rng.decades(1.2e6f, 2.3e7f);
			p[t + kThPrKappa] = rng.range(0.03f, 0.9f);
		}
		p[t + kThCSol] = rng.range(400.0f, 4200.0f);
		p[t + kThCLiq] = rng.range(400.0f, 4200.0f);
		p[t + kThCGas] = rng.range(400.0f, 4200.0f);
		// Every ladder integrates from its standard state, here the solid at a drawn temperature.
		p[t + kThAnchorPhase] = 0.0f;
		p[t + kThAnchorT] = rng.range(0.0f, 50.0f);
		p[t + kThNu] = 1.0f;
		p[t + kThNEl] = 1.0f;
		p[t + kThElN] = 1.0f;
		if (condensed) {
			p[t + kThFusionT0] = rng.range(-40.0f, 1600.0f);
			p[t + kThFusionT1] = p[t + kThFusionT0] + (rng.chance(0.5f) ? 0.0f : rng.range(1.0f, 300.0f));
			p[t + kThLFus] = rng.decades(1.0e4f, 5.0e5f);
			p[t + kThHasFusion] = 1.0f;
			draw_line(rng, p, t, rng.below(4));
		}
	}
	for (uint32_t k = 0; k < kDetSlots; ++k) {
		p[kChannelSlots * kPropStride + k] = rng.decades(1.0e-3f, 1.0e3f);
	}
	return p;
}

World load(Rig &rig, Rng &rng) {
	World w;
	const uint32_t n = w.lat.cells();
	rig.put(LA_BIND_NBR, w.lat.nbr);
	rig.put(LA_BIND_FACE_PARTNER, w.lat.partner);
	rig.put(LA_BIND_SLOT_OFF, w.lat.slot_off);
	rig.put(LA_BIND_CELL_EDGE, w.lat.cell_edge);
	rig.put(LA_BIND_POS, w.lat.pos);
	rig.put(LA_BIND_VERT_UP, w.lat.vert_up);
	rig.put(LA_BIND_VERT_DOWN, w.lat.vert_down);

	w.props = draw_props(rng);
	rig.put(LA_BIND_DERIVE_PROPS, w.props);

	std::vector<float> v(n, 0.0f);
	auto put = [&](uint32_t binding, float lo, float hi) {
		for (uint32_t i = 0; i < n; ++i) { v[i] = rng.decades(lo, hi); }
		rig.put(binding, v);
		return v;
	};
	// Every channel holds something, so no cell is empty and the dead pool has a composition. A CELL IS
	// NOT MORE THAN FULL: the amounts are scaled so the volume fractions they stand for sum under one,
	// which is the only state the world has.
	std::vector<std::vector<float>> amount(kChannelSlots, std::vector<float>(n, 0.0f));
	for (uint32_t i = 0; i < kChannelSlots; ++i) {
		for (uint32_t g = 0; g < n; ++g) { amount[i][g] = rng.decades(1.0e-2f, 1.0e2f); }
	}
	for (uint32_t g = 0; g < n; ++g) {
		float vf = 0.0f;
		for (uint32_t i = 0; i < kChannelSlots; ++i) {
			vf += amount[i][g] / w.props[i * kPropStride + kPropFull];
		}
		const float fill = rng.range(0.05f, 0.95f);
		if (vf > 0.0f) {
			for (uint32_t i = 0; i < kChannelSlots; ++i) { amount[i][g] *= fill / vf; }
		}
	}
	for (uint32_t i = 0; i < kChannelSlots; ++i) { rig.put(kChannelBinding[i], amount[i]); }
	// THE STATE IS DRAWN AS A STATE: a temperature the planet has, and the energy that mixture holds at
	// it, never an energy picked apart from the matter that carries it.
	w.energy.assign(n, 0.0f);
	const float vol = kEdgeM * kEdgeM * kEdgeM;
	for (uint32_t g = 0; g < n; ++g) {
		float mc = 0.0f;
		for (uint32_t i = 0; i < kChannelSlots; ++i) {
			mc += amount[i][g] * w.props[i * kPropStride + kPropM] * vol
					* w.props[i * kPropStride + kPropLadder + kThCSol];
		}
		// The sensible heat above the standard state the ladders are integrated from.
		w.energy[g] = mc * rng.range(-120.0f, 3000.0f) / vol;
	}
	rig.put(LA_BIND_E_J_M3, w.energy);
	w.pressure = put(LA_BIND_PRESSURE, 1.0e2f, 1.0e9f);
	rig.put(LA_BIND_P_FLUID, w.pressure);
	put(LA_BIND_TEMP, 200.0f, 400.0f);
	put(LA_BIND_TEMP_LITH, 200.0f, 400.0f);
	put(LA_BIND_GRAIN, 1.0e-5f, 1.0e-2f);
	put(LA_BIND_MOM_X, 0.1f, 10.0f);
	put(LA_BIND_MOM_Y, 0.1f, 10.0f);
	put(LA_BIND_MOM_Z, 0.1f, 10.0f);
	put(LA_BIND_GRAV_REF, 1.0e4f, 1.0e6f);
	rig.zero(LA_BIND_GRAV_PHI);
	// NO LATTICE: the cell's matter is all fluid, so the reservoir the round trip reads is the whole cell.
	rig.zero(LA_BIND_CEMENT);
	rig.zero(LA_BIND_SOLID);
	rig.zero(LA_BIND_REGOLITH);
	rig.zero(LA_BIND_E_LITH_J_M3);
	rig.zero(LA_BIND_LEVEL_IDX);
	rig.zero(LA_BIND_LEVEL_ARGS);

	// A body that spins and carries a sea shell, so latitude and altitude are geometry and not absences.
	std::vector<float> grav(size_t(n) * 3u, 0.0f);
	for (uint32_t i = 0; i < n; ++i) { grav[i * 3u + 1u] = -9.80665f; }
	rig.put(LA_BIND_GRAVITY, grav);
	w.sea_radius = 0.4f * float(kN) * kEdgeM;
	return w;
}

Push push_for(const World &w) {
	Push p{};
	p.cell_count = w.lat.cells();
	p.dt_s = 1.0f;
	p.omega_y = 7.2921159e-5f; // one sidereal rotation, rad/s
	const float half = 0.5f * float(kN) * kEdgeM;
	p.centre_x = half;
	p.centre_y = half;
	p.centre_z = half;
	p.fresh_grain_m = 1.0e-4f;
	p.fresh_h_per_c = 1.5f;
	p.fresh_o_per_c = 0.7f;
	p.rad_w_kg_1 = 1.0e-11f;
	p.rad_w_kg_2 = 2.0e-11f;
	p.rad_w_kg_3 = 3.0e-11f;
	p.rad_w_kg_4 = 4.0e-11f;
	p.sea_radius_m = w.sea_radius;
	p.grav_self = 1.0f;
	return p;
}

// ONE STATE PER CELL: the derive solves a temperature at a pressure and states a pressure from that
// temperature, so a second pass over the state it wrote must return the same pair.
bool prop_derive_is_a_fixed_point(Case &c) {
	std::string err;
	Rig rig(c.dev, "state_derive", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(71);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = load(rig, rng);
		const Push p = push_for(w);
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> t1 = rig.get(LA_BIND_TEMP, w.lat.cells());
		const std::vector<float> p1 = rig.get(LA_BIND_PRESSURE, w.lat.cells());
		const std::vector<float> unconv = rig.get(LA_BIND_UNCONVERGED, w.lat.cells());
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> t2 = rig.get(LA_BIND_TEMP, w.lat.cells());
		const std::vector<float> p2 = rig.get(LA_BIND_PRESSURE, w.lat.cells());
		for (uint32_t g = 0; g < w.lat.cells(); ++g) {
			// A cell whose solve did not converge has no state to return to.
			if (unconv[g] != 0.0f || !(p1[g] > 0.0f)) { continue; }
			c.examined += 1;
			char buf[224];
			if (std::fabs(double(shifted(t2[g], c.mutate)) - double(t1[g])) > kTolK) {
				std::snprintf(buf, sizeof(buf),
						"draw %u cell %u: the derive did not return the temperature it wrote "
						"(%.9g then %.9g degC at %.9g Pa)",
						d, g, double(t1[g]), double(t2[g]), double(p1[g]));
				c.why = buf;
				return false;
			}
			if (std::fabs(double(shifted(p2[g], c.mutate)) - double(p1[g]))
					> kTolPRel * std::fabs(double(p1[g]))) {
				std::snprintf(buf, sizeof(buf),
						"draw %u cell %u: the derive did not return the pressure it wrote "
						"(%.9g then %.9g Pa at %.9g degC)",
						d, g, double(p1[g]), double(p2[g]), double(t1[g]));
				c.why = buf;
				return false;
			}
		}
	}
	return c.examined > 0;
}

// FINITE STATE FROM FINITE MATTER, every reading the step downstream reads, and the kernel's own
// non-finite counter agreeing that there is nothing to count.
bool prop_derive_writes_finite_state(Case &c) {
	std::string err;
	Rig rig(c.dev, "state_derive", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(72);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = load(rig, rng);
		const Push p = push_for(w);
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> nf = rig.get(LA_BIND_NONFINITE, w.lat.cells());
		for (uint32_t g = 0; g < w.lat.cells(); ++g) {
			c.examined += 1;
			if (double(shifted(nf[g], c.mutate)) != 0.0) {
				c.why = "the derive counted a non-finite reading over finite matter";
				return false;
			}
		}
		for (uint32_t b : kDerived) {
			const std::vector<float> got = rig.get(b, size_t(w.lat.cells()) * 3u);
			for (uint32_t i = 0; i < w.lat.cells(); ++i) {
				c.examined += 1;
				if (!std::isfinite(c.mutate ? std::nanf("") : got[i])) {
					char buf[160];
					std::snprintf(buf, sizeof(buf),
							"binding %u came back non-finite over finite matter", b);
					c.why = buf;
					return false;
				}
			}
		}
	}
	return c.examined > 0;
}

// THE LADDER INVERTS ITSELF: the temperature solved from the cell's enthalpy restates that enthalpy,
// entry by entry. With no lattice the whole cell is one reservoir, so the four entry enthalpies sum to
// the internal energy handed in plus the flow work over the room the fluid stands in.
bool prop_derive_enthalpy_round_trip(Case &c) {
	std::string err;
	Rig rig(c.dev, "state_derive", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(73);
	for (uint32_t d = 0; d < kDraws; ++d) {
		const World w = load(rig, rng);
		const Push p = push_for(w);
		rig.run(&p, sizeof(p), w.lat.cells());
		const std::vector<float> unconv = rig.get(LA_BIND_UNCONVERGED, w.lat.cells());
		const std::vector<float> rho = rig.get(LA_BIND_RHO_BULK, w.lat.cells());
		const std::vector<float> p_fluid = rig.get(LA_BIND_P_FLUID, w.lat.cells());
		const std::vector<float> lithic = rig.get(LA_BIND_LITHIC_FRAC, w.lat.cells());
		const std::vector<float> h_h2o = rig.get(LA_BIND_H_H2O, w.lat.cells());
		const std::vector<float> h_vap = rig.get(LA_BIND_H_H2O_VAP, w.lat.cells());
		const std::vector<float> h_sil = rig.get(LA_BIND_H_SILICATE, w.lat.cells());
		const std::vector<float> h_sen = rig.get(LA_BIND_H_SENSIBLE, w.lat.cells());
		for (uint32_t g = 0; g < w.lat.cells(); ++g) {
			if (unconv[g] != 0.0f || !(rho[g] > 0.0f)) { continue; }
			const double room_f = 1.0 - double(lithic[g]);
			const double handed = double(w.energy[g]) + double(p_fluid[g]) * room_f;
			const double back = double(h_h2o[g]) + double(h_vap[g]) + double(h_sil[g])
					+ double(h_sen[g]);
			const double scale = std::fabs(double(w.energy[g]))
					+ std::fabs(double(p_fluid[g]) * room_f) + std::fabs(double(h_h2o[g]))
					+ std::fabs(double(h_vap[g])) + std::fabs(double(h_sil[g]))
					+ std::fabs(double(h_sen[g]));
			c.examined += 1;
			if (std::fabs(double(shifted(float(back), c.mutate)) - handed)
					> kTolEnthalpyRel * scale) {
				c.why = "the enthalpy the mixture states at the solved temperature is not the "
						"enthalpy the solve was handed";
				return false;
			}
		}
	}
	return c.examined > 0;
}

// MELTING COSTS ITS LATENT HEAT. One channel alone in a cell, swept in energy across its melting point:
// the enthalpy the cell states at that temperature climbs by exactly the fusion enthalpy of the mass
// present while the temperature stands still. Each branch is read off its own side and extrapolated to
// the melting point, so what is compared is the step between them, not the sweep's own spacing.
bool prop_derive_melting_costs_its_latent_heat(Case &c) {
	std::string err;
	Rig rig(c.dev, "state_derive", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(91);
	const double vol = double(kEdgeM) * double(kEdgeM) * double(kEdgeM);
	for (uint32_t d = 0; d < kDraws; ++d) {
		World w = load(rig, rng);
		const uint32_t n = w.lat.cells();
		// A melting POINT, not an interval: an interval spreads the latent heat over its own width. Channel 0
		// is the water the kernel reads through water's own curves, and channel 1 the silicate melt's
		// entry, so neither is a drawn ladder.
		uint32_t ci = kChannelSlots;
		for (uint32_t i = 2; i < kChannelSlots && ci >= kChannelSlots; ++i) {
			const uint32_t t = i * kPropStride + kPropLadder;
			if (w.props[t + kThHasFusion] > 0.0f && w.props[t + kThFusionT1] == w.props[t + kThFusionT0]) {
				ci = i;
			}
		}
		if (ci >= kChannelSlots) {
			continue;
		}
		const uint32_t base = ci * kPropStride;
		// Half a cell of it and nothing else: one boundary in the world, and the phase it is in stands in
		// vacuum, so the pressure the cell settles at is nothing pushing back.
		rig.put(LA_BIND_DERIVE_PROPS, w.props);
		const double molar = double(w.props[base + kPropM]);
		const double c_sol = double(w.props[base + kPropLadder + kThCSol]);
		const double c_liq = double(w.props[base + kPropLadder + kThCLiq]);
		const double l_fus = double(w.props[base + kPropLadder + kThLFus]);
		// The drawn Clapeyron slope is zero, so the plateau stands here at any pressure.
		const double t0 = double(w.props[base + kPropLadder + kThFusionT0]);
		const double amt = 0.5 * double(w.props[base + kPropFull]);
		std::vector<float> a(n, float(amt));
		std::vector<float> zero(n, 0.0f);
		for (uint32_t i = 0; i < kChannelSlots; ++i) {
			rig.put(kChannelBinding[i], i == ci ? a : zero);
		}
		rig.fill(LA_BIND_PRESSURE, 0.0f);
		rig.fill(LA_BIND_P_FLUID, 0.0f);
		const double m_kg = amt * molar * vol;
		// The sweep: forty kelvin of sensible heat below the plateau to forty above it.
		const double t_ref = double(w.props[base + kPropLadder + kThAnchorT]);
		w.props[base + kPropLadder + kThLineKind] = 0.0f;
		w.props[base + kPropLadder + kThLineA1] = 0.0f;
		rig.put(LA_BIND_DERIVE_PROPS, w.props);
		const double h_lo = m_kg * c_sol * (t0 - t_ref - 40.0);
		const double h_hi = m_kg * (c_sol * (t0 - t_ref) + l_fus + c_liq * 40.0);
		std::vector<float> e(n, 0.0f);
		for (uint32_t g = 0; g < n; ++g) {
			e[g] = float((h_lo + (h_hi - h_lo) * double(g) / double(n - 1)) / vol);
		}
		rig.put(LA_BIND_E_J_M3, e);
		const Push p = push_for(w);
		rig.run(&p, sizeof(p), n);
		const std::vector<float> temp = rig.get(LA_BIND_TEMP, n);
		const std::vector<float> unconv = rig.get(LA_BIND_UNCONVERGED, n);
		const std::vector<float> h_h2o = rig.get(LA_BIND_H_H2O, n);
		const std::vector<float> h_vap = rig.get(LA_BIND_H_H2O_VAP, n);
		const std::vector<float> h_sil = rig.get(LA_BIND_H_SILICATE, n);
		const std::vector<float> h_sen = rig.get(LA_BIND_H_SENSIBLE, n);
		auto enthalpy = [&](uint32_t g) {
			return (double(h_h2o[g]) + double(h_vap[g]) + double(h_sil[g]) + double(h_sen[g])) * vol;
		};
		// One cell clearly in the solid and one clearly in the melt; five kelvin clear of the plateau,
		// so neither reading is a cell the boundary itself is passing through.
		uint32_t g_sol = n;
		uint32_t g_liq = n;
		for (uint32_t g = 0; g < n; ++g) {
			if (unconv[g] != 0.0f) {
				continue;
			}
			if (double(temp[g]) < t0 - 5.0) {
				g_sol = g;
			}
			if (g_liq >= n && double(temp[g]) > t0 + 5.0) {
				g_liq = g;
			}
		}
		if (g_sol >= n || g_liq >= n) {
			continue;
		}
		// Each branch is linear in temperature at its own capacity, so the step between them at the
		// melting point is the whole of what crossing it cost.
		const double h_a = enthalpy(g_sol) + m_kg * c_sol * (t0 - double(temp[g_sol]));
		const double h_b = enthalpy(g_liq) - m_kg * c_liq * (double(temp[g_liq]) - t0);
		const double want = m_kg * l_fus;
		c.examined += 1;
		if (std::fabs(h_b - h_a - double(shifted(float(want), c.mutate))) > kTolLatentRel * want) {
			char buf[192];
			std::snprintf(buf, sizeof(buf),
					"melting the cell cost %.6g J where its fusion enthalpy is %.6g J", h_b - h_a, want);
			c.why = buf;
			return false;
		}
	}
	return c.examined > 0;
}

// A MELTING LINE IS THE ONE LAMeltingLine.hpp DECLARES. One lithic channel locked as a lattice at a drawn
// pressure on its drawn line, energy two kelvin below and two above the header's melting point: the melt
// share the kernel publishes is none below and all above.
bool prop_derive_melts_on_its_line(Case &c) {
	std::string err;
	Rig rig(c.dev, "state_derive", kWords, err);
	if (!rig.ok()) {
		c.why = err;
		return false;
	}
	Rng rng(c.seed);
	rng.stream(97);
	const double vol = double(kEdgeM) * double(kEdgeM) * double(kEdgeM);
	for (uint32_t d = 0; d < kDraws; ++d) {
		World w = load(rig, rng);
		const uint32_t n = w.lat.cells();
		uint32_t ci = kChannelSlots;
		for (uint32_t i = 2; i < kChannelSlots && ci >= kChannelSlots; ++i) {
			const uint32_t t = i * kPropStride + kPropLadder;
			if (w.props[t + kThHasFusion] > 0.0f && w.props[t + kThFusionT1] == w.props[t + kThFusionT0]) {
				ci = i;
			}
		}
		if (ci >= kChannelSlots) {
			continue;
		}
		const uint32_t base = ci * kPropStride;
		const uint32_t t = base + kPropLadder;
		draw_line(rng, w.props, t, 1u + rng.below(3));
		w.props[base + kPropLithic] = 1.0f;
		rig.put(LA_BIND_DERIVE_PROPS, w.props);
		const double p_pa = double(rng.decades(1.0e7f, 2.0e9f));
		const std::vector<float> &q = w.props;
		const double t_m = la_melt_line::temperature_k(int(q[t + kThLineKind]), double(q[t + kThFusionT0]) + 273.15,
				double(q[t + kThLinePref]), double(q[t + kThLineT0]), double(q[t + kThLineP0]), double(q[t + kThLineA1]),
				double(q[t + kThLineC1]), double(q[t + kThLineA2]), double(q[t + kThLineC2]), p_pa) - 273.15;
		if (!std::isfinite(t_m)) {
			c.why = "the header's melting line did not converge on a drawn line";
			return false;
		}
		const double t_ref = double(q[t + kThAnchorT]);
		const double c_sol = double(q[t + kThCSol]);
		const double c_liq = double(q[t + kThCLiq]);
		const double l_fus = double(q[t + kThLFus]);
		const double amt = double(q[base + kPropFull]);
		const double m_kg = amt * double(q[base + kPropM]) * vol;
		std::vector<float> a(n, float(amt));
		std::vector<float> zero(n, 0.0f);
		for (uint32_t i = 0; i < kChannelSlots; ++i) {
			rig.put(kChannelBinding[i], i == ci ? a : zero);
		}
		std::vector<float> e(n, 0.0f);
		for (uint32_t g = 0; g < n; ++g) {
			const bool above = (g & 1u) != 0u;
			const double h = above ? c_sol * (t_m - t_ref) + l_fus + c_liq * 2.0 : c_sol * (t_m - 2.0 - t_ref);
			e[g] = float(m_kg * h / vol);
		}
		rig.put(LA_BIND_E_LITH_J_M3, e);
		rig.fill(LA_BIND_E_J_M3, 0.0f);
		rig.fill(LA_BIND_SOLID, 1.0f);
		rig.fill(LA_BIND_CEMENT, 1.0f);
		rig.fill(LA_BIND_PRESSURE, float(p_pa));
		rig.fill(LA_BIND_P_FLUID, float(p_pa));
		const Push p = push_for(w);
		rig.run(&p, sizeof(p), n);
		const std::vector<float> melt = rig.get(LA_BIND_SILICATE_MELT, n);
		for (uint32_t g = 0; g < n; ++g) {
			const float want = (g & 1u) != 0u ? 1.0f : 0.0f;
			c.examined += 1;
			if (shifted(melt[g], c.mutate) != want) {
				char buf[192];
				std::snprintf(buf, sizeof(buf), "kind %d at %.4g Pa melts %.3g at %s its line's %.3f C",
						int(q[t + kThLineKind]), p_pa, double(melt[g]), want > 0.0f ? "2 K above" : "2 K below", t_m);
				c.why = buf;
				return false;
			}
		}
	}
	return c.examined > 0;
}

} // namespace

void add_derive_properties(std::vector<Property> &out) {
	out.push_back({ "state_derive.glsl", "derive_melts_on_its_line", prop_derive_melts_on_its_line });
	out.push_back({ "state_derive.glsl", "derive_melting_costs_its_latent_heat",
			prop_derive_melting_costs_its_latent_heat });
	out.push_back({ "state_derive.glsl", "derive_is_a_fixed_point", prop_derive_is_a_fixed_point });
	out.push_back({ "state_derive.glsl", "derive_writes_finite_state",
			prop_derive_writes_finite_state });
	out.push_back({ "state_derive.glsl", "derive_enthalpy_round_trip",
			prop_derive_enthalpy_round_trip });
}

} // namespace lasim
