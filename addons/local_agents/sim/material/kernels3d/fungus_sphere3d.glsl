#[compute]
#version 450

#include "neighbours.glsli"
#include "cellvol.glsli"

// Mycelium growth, spore spread and die-back over the dead organic pool. One invocation per ACTIVE cell.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FungIn  { float fung_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FungOut { float fung_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Temp  { float temp[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Vapor { float vapor[]; };
// 7 is unbound; the gap is deliberate.
layout(set = 0, binding = 8, std430) restrict readonly buffer Solid { float solid[]; };
// The dead pool's other carbon stock. The pool's composition divides by detritus + fuel.
layout(set = 0, binding = 9, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };
// The dead pool's hydrogen and oxygen, at the same bindings reactions_sphere3d.glsl uses. Mycelium eating
// litter takes the litter's OWN C:H:O; mycelium dying hands back fungal tissue, which is CH2O. Without
// these two the exchange would move carbon on its own.
layout(set = 0, binding = 32, std430) restrict buffer OrgH { float org_h[]; };
layout(set = 0, binding = 33, std430) restrict buffer OrgO { float org_o[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float precip;
	float fresh_h_per_c;   // moles of H per mole of C in fungal tissue (CH2O)
	float fresh_o_per_c;
	float pad5;
} params;

// Substrate thresholds + rates.
const float DETRITUS_MIN = 0.05;
// FUNGUS_MIN's consumer is LAMaterialFieldChannels3D.FUNGUS_PRESENT, the live-colony threshold the
// fungus_cells gauge counts against.
const float FUNGUS_MIN = 0.02;
const float FUNGUS_MAX = 3.0;
const float MOIST_MIN = 0.02;
const float MOIST_REF = 0.06;
const float VAPOR_MOIST = 1.0;
const float RAIN_MOIST = 0.5;
const float DETRITUS_DAMP = 0.15;
// Thermal death of a mesophilic fungus, degrees C. A property of the organism, not of matter.
const float TEMP_WARM = 42.0;
// Growth stops when the water in and around the mycelium freezes.
const float TEMP_COLD = 0.0;    // LAPhysical.WATER_FREEZE_C
const float GROW_RATE = 0.06;
const float SPREAD = 0.02;
const float DECAY = 0.02;
const float DRY_DECAY = 0.06;

bool spreads_at(uint c) {
	float moist_c = VAPOR_MOIST * vapor[c] + RAIN_MOIST * params.precip;
	float tc = temp[c];
	return tc <= TEMP_WARM && tc >= TEMP_COLD && moist_c >= MOIST_MIN;
}

// How many of cell `c`'s neighbours are OPEN — the divisor both ends of a spore transfer agree on.
int open_neighbours(uint c) {
	uint b = c * N_SLOTS;
	int n = 0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int m = nbr[b + d];
		if (m >= 0 && solid[m] == 0.0) { n += 1; }
	}
	return n;
}

void main() {
	// A cell absent from the active list has fungus 0 in BOTH ping-pong halves, detritus 0, and zero fungus
	// in every neighbour: growth, spread and decay are all 0.
	uint li = gl_GlobalInvocationID.x;
	if (li >= active_args[3]) {
		return;
	}
	uint i = active_idx[li];
	if (i >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	if (solid[i] != 0.0) {
		fung_out[i] = fung_in[i];
		return;
	}

	float d = detritus[i];
	float g = fung_in[i];
	// The dead pool's own composition, over the carbon it holds in BOTH its stocks.
	float pool = d + fuel[i];
	float comp_h = (pool > 1e-9) ? org_h[i] / pool : params.fresh_h_per_c;
	float comp_o = (pool > 1e-9) ? org_o[i] / pool : params.fresh_o_per_c;
	// Moisture: air humidity + active rain + the dampness of the rotting matter itself.
	float moist = VAPOR_MOIST * vapor[i] + RAIN_MOIST * params.precip + DETRITUS_DAMP * clamp(d, 0.0, 1.0);
	float t = temp[i];
	bool scorched = t > TEMP_WARM;
	bool frozen = t < TEMP_COLD;
	bool dry = moist < MOIST_MIN;
	bool favourable = d > DETRITUS_MIN && !scorched && !frozen && !dry;
	float gnew = g;
	float det_delta = 0.0;      // net change to THIS cell's detritus; applied once at the end.
	float grown_c = 0.0;        // carbon the mycelium took OUT of the dead pool
	float died_c = 0.0;         // ...and carbon dead mycelium handed back to it

	if (favourable) {
		float mfac = clamp(moist / MOIST_REF, 0.0, 1.0);
		float want = GROW_RATE * d * mfac;
		float headroom = max(0.0, FUNGUS_MAX - gnew);
		float grown = min(min(want, headroom), max(0.0, d));
		gnew += grown;
		det_delta -= grown;
		grown_c = grown;
	}

	if (spreads_at(i)) {
		gnew -= SPREAD * float(open_neighbours(i)) * g;
	}
	for (uint dd = 0u; dd < N_SLOTS; dd++) {
		int nb = nbr[i * N_SLOTS + dd];
		if (nb >= 0 && solid[nb] == 0.0 && spreads_at(uint(nb))) {
			gnew += SPREAD * fung_in[uint(nb)] * vol_ratio(uint(nb), i);
		}
	}

	// Die-back, fast where hot / frozen / dry or the food is exhausted. Dead mycelium returns to the pool.
	float died = ((scorched || frozen || dry || d <= DETRITUS_MIN) ? DRY_DECAY : DECAY) * max(0.0, gnew);
	gnew -= died;
	det_delta += died;
	died_c = died;

	detritus[i] = max(0.0, d + det_delta);
	// grown carbon left the pool with its own H and O; died carbon arrives as CH2O.
	org_h[i] = max(0.0, org_h[i] - grown_c * comp_h + died_c * params.fresh_h_per_c);
	org_o[i] = max(0.0, org_o[i] - grown_c * comp_o + died_c * params.fresh_o_per_c);
	fung_out[i] = max(0.0, gnew);
}
