#[compute]
#version 450

#include "neighbours.glsli"
#include "cellvol.glsli"


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FungIn  { float fung_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FungOut { float fung_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Temp  { float temp[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Vapor { float vapor[]; };
// remaining bindings keep their numbers so no other kernel or pass has to move.
layout(set = 0, binding = 8, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float precip;
	float pad3;
	float pad4;
	float pad5;
} params;

// Substrate thresholds + rates. Declared here and owned here (see the header).
const float DETRITUS_MIN = 0.05;
// FUNGUS_MIN is not read by this kernel — its consumer is LAMaterialFieldChannels3D.FUNGUS_PRESENT, the
// "this cell has a live colony" threshold the SIM_REPORT fungus_cells gauge counts against. Kept here so the
const float FUNGUS_MIN = 0.02;
const float FUNGUS_MAX = 3.0;
const float MOIST_MIN = 0.02;
const float MOIST_REF = 0.06;
const float VAPOR_MOIST = 1.0;
const float RAIN_MOIST = 0.5;
const float DETRITUS_DAMP = 0.15;
// Thermal death of a mesophilic fungus. Real mesophiles top out around 40-45 C (thermophiles reach 60, which
// this single generic decomposer channel does not model). A property of the organism, not of matter.
const float TEMP_WARM = 42.0;
// Growth stops when the water in and around the mycelium turns to ice, so this IS the freezing point of
// water and is bound to the authority rather than left free. It is exactly the kind of constant that was
const float TEMP_COLD = 0.0;    // LAPhysical.WATER_FREEZE_C
// FIRE: THIS KERNEL NO LONGER READS IT, AND `const float FIRE_MIN = 0.02;` IS DELETED WITH THE TWO TESTS
const float GROW_RATE = 0.06;
const float SPREAD = 0.02;
const float DECAY = 0.02;
const float DRY_DECAY = 0.06;

bool spreads_at(uint c) {
	float moist_c = VAPOR_MOIST * vapor[c] + RAIN_MOIST * params.precip;
	float tc = temp[c];
	return tc <= TEMP_WARM && tc >= TEMP_COLD && moist_c >= MOIST_MIN;
}

// How many of cell `c`'s six neighbours are OPEN — the divisor both ends of a spore transfer agree on.
int open_neighbours(uint c) {
	uint b = c * 6u;
	int n = 0;
	for (int d = 0; d < 6; ++d) {
		int m = nbr[b + uint(d)];
		if (m >= 0 && solid[m] == 0.0) { n += 1; }
	}
	return n;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	if (solid[i] != 0.0) {
		fung_out[i] = fung_in[i];
		return;
	}

	float d = detritus[i];
	float g = fung_in[i];
	// Moisture: air humidity + active rain + the dampness of the rotting matter itself.
	float moist = VAPOR_MOIST * vapor[i] + RAIN_MOIST * params.precip + DETRITUS_DAMP * clamp(d, 0.0, 1.0);
	float t = temp[i];
	bool scorched = t > TEMP_WARM;
	bool frozen = t < TEMP_COLD;
	bool dry = moist < MOIST_MIN;
	bool favourable = d > DETRITUS_MIN && !scorched && !frozen && !dry;
	float gnew = g;
	float det_delta = 0.0;      // net change to THIS cell's detritus; applied once at the end.

	if (favourable) {
		float mfac = clamp(moist / MOIST_REF, 0.0, 1.0);
		float want = GROW_RATE * d * mfac;
		float headroom = max(0.0, FUNGUS_MAX - gnew);
		float grown = min(min(want, headroom), max(0.0, d));
		gnew += grown;
		det_delta -= grown;
	}

	if (spreads_at(i)) {
		gnew -= SPREAD * float(open_neighbours(i)) * g;
	}
	for (int dd = 0; dd < 6; dd++) {
		int nb = nbr[i * N_SLOTS + uint(dd)];
		if (nb >= 0 && solid[nb] == 0.0 && spreads_at(uint(nb))) {
			gnew += SPREAD * fung_in[uint(nb)] * vol_ratio(uint(nb), i);
		}
	}


	// 3) DEATH / DECAY — dies back fast where hot/frozen/dry or the food is exhausted. DEAD MYCELIUM IS
	// DESTROYED the dead fungus outright, with no product anywhere — which is why the decay leg leaked in the
	float died = ((scorched || frozen || dry || d <= DETRITUS_MIN) ? DRY_DECAY : DECAY) * max(0.0, gnew);
	gnew -= died;
	det_delta += died;

	detritus[i] = max(0.0, d + det_delta);
	fung_out[i] = max(0.0, gnew);
}
