#[compute]
#version 450

// CUBED-SPHERE FIRE / COMBUSTION — sphere port of fire3d.glsl (box). GATHER form (each cell sums the ember
// heat thrown by its BURNING neighbours) so this single dispatch is order-independent: read the fire[]
// snapshot (fire_in), write own temp/fuel/o2/co2 in place, write next fire state to fire_out (ping-pong).
//
// The ONLY change vs the box is neighbour addressing — the combustion REACTION (PHASE: wet/suffocation
// extinguish, burn → consume fuel+O₂, emit CO₂, pin BURN_TEMP, burn to ash; ignite at IGNITE_TEMP) is kept
// VERBATIM. Neighbour remap (box idx±offset → INDEX TABLE nbr[idx*6 + d]; slot 0 = inward/radial-DOWN,
// 1-4 = LATERAL, 5 = outward/radial-UP; -1 = boundary → skipped):
//   * EMBER SPREAD — the box's 4 lateral neighbours (±x, ±z) become the 4 LATERAL slots (1-4), gathered
//     SYMMETRICALLY. The box biased each lateral ember DOWNWIND (ember(fire, toward) with toward = the
//     neighbour's world wind blowing at this cell). On the cubed sphere the lateral neighbours point in
//     VARYING world directions, so a world-axis wind vector cannot be mechanically projected onto them
//     (identical reasoning to the o2/scent transport sphere ports, which drop the same advective term). The
//     directional bias is therefore DROPPED — each lateral burning neighbour contributes the symmetric base
//     creep ember(fire, 0) = EMBER_HEAT·fire. Consequently vel_x/vel_z are no longer read and their box
//     bindings (6,7) are removed; O2/CO2 shift down to 6/7.
//   * PLUME (fire rises) — the box threw a fixed upward plume from the cell BELOW (its -layer neighbour, since
//     +layer = up). On the sphere the cell below is slot 0, so the plume term reads slot 0 with EMBER_UP:
//     embers rise INTO this cell from the burning cell radially beneath it, i.e. fire climbs toward slot 5,
//     exactly as the box had fire climb toward +layer. The outward-radial (slot 5) neighbour contributes NO
//     ember here, matching the box (the cell above never threw ember downward).
// Constants copied EXACTLY from MaterialCombustion3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer FireIn  { float fire_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer FireOut { float fire_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Fuel    { float fuel[]; };
layout(set = 0, binding = 3, std430) restrict buffer Temp    { float temp[]; };
layout(set = 0, binding = 4, std430) restrict buffer Water   { float water[]; };
layout(set = 0, binding = 5, std430) restrict buffer Solid   { float solid[]; };
layout(set = 0, binding = 6, std430) restrict buffer O2      { float o2[]; };
layout(set = 0, binding = 7, std430) restrict buffer CO2     { float co2[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialCombustion3D.gd exactly.
const float IGNITE_TEMP = 450.0;
const float BURN_TEMP = 640.0;
const float FUEL_MIN = 0.02;
const float FIRE_MIN = 0.02;
const float FIRE_START = 0.4;
const float FIRE_GROW = 0.3;
const float BURN_RATE = 0.12;
const float WET_MAX = 0.05;
const float EMBER_HEAT = 12.0;
const float EMBER_WIND_GAIN = 5.0;
const float EMBER_MAX = 70.0;
const float EMBER_UP = 8.0;
// Oxygen coupling — MUST match MaterialCombustion3D.gd. Burning consumes O₂; below O2_MIN a cell can't
// ignite / a burning cell suffocates (so a sealed cave's fire draws down trapped O₂ and dies).
const float O2_MIN = 0.35;
const float BURN_O2_RATE = 0.06;
// CO₂ emission — MUST match MaterialCombustion3D.gd. A burning cell emits CO₂ (fuel + O₂ → CO₂) deterministic
// ∝ fire, so it stays bit-exact CPU vs GPU. LAMaterialGas3D transports/settles it; plants fix it back to O₂.
const float CO2_PER_BURN = 0.06;

// Ember one burning neighbour contributes (base creep + downwind boost, × emitter intensity, capped). On the
// sphere `toward` is always 0 (see header — world-wind bias dropped on the varying-direction lateral slots),
// but the function is kept identical to the box so the reaction math is provably unchanged for toward = 0.
float ember(float neighbour_fire, float toward) {
	float w = EMBER_HEAT + EMBER_WIND_GAIN * max(0.0, toward);
	return min(EMBER_MAX, w) * clamp(neighbour_fire, 0.0, 1.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		fire_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;

	// 1) EMBER GATHER from burning neighbours (symmetric lateral creep + upward plume from below).
	float e = 0.0;
	// 4 LATERAL slots (1-4): symmetric spread — no world-wind directional bias on the sphere (toward = 0).
	for (int d = 0; d < 4; d++) {
		int n = nbr[base + 1u + uint(d)];
		if (n >= 0 && solid[n] == 0.0 && fire_in[n] > FIRE_MIN) {
			e += ember(fire_in[n], 0.0);
		}
	}
	// PLUME: the burning cell radially BELOW (slot 0) throws a fixed upward plume → fire climbs toward slot 5.
	int nd = nbr[base + 0u];
	if (nd >= 0 && solid[nd] == 0.0 && fire_in[nd] > FIRE_MIN) {
		e += EMBER_UP * clamp(fire_in[nd], 0.0, 1.0);
	}
	if (e > 0.0) {
		temp[g] += e;
	}

	// 2) PHASE — extinguish / burn / ignite. VERBATIM from the box (no neighbour reads).
	float f = fire_in[g];
	float fuel_i = fuel[g];
	float fnew = 0.0;
	if (water[g] > WET_MAX || o2[g] < O2_MIN) {
		fnew = 0.0;                                   // wet firebreak OR suffocated (O₂ < O2_MIN)
	} else if (f > FIRE_MIN) {
		if (fuel_i > 0.0) {
			fuel[g] = max(0.0, fuel_i - BURN_RATE * clamp(f, 0.0, 1.0));
			o2[g] = max(0.0, o2[g] - BURN_O2_RATE * clamp(f, 0.0, 1.0));  // burning draws down local O₂
			co2[g] += CO2_PER_BURN * clamp(f, 0.0, 1.0);                 // and emits CO₂ (fuel + O₂ → CO₂)
			if (temp[g] < BURN_TEMP) { temp[g] = BURN_TEMP; }
			fnew = (fuel[g] <= 0.0) ? 0.0 : min(1.0, f + FIRE_GROW);
		} else {
			fnew = 0.0;
		}
	} else if (fuel_i > FUEL_MIN && temp[g] >= IGNITE_TEMP) {
		fnew = FIRE_START;                            // IGNITION from any heat source
	}
	fire_out[g] = fnew;
}
