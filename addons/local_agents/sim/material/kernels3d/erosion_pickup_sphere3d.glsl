#[compute]
#version 450

#include "neighbours.glsli"

// RACE-FREEDOM: a cell i scours ONLY its radial-DOWN neighbour's bedrock. By the neighbour table's

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer WaterIn { float water_in[]; };   // settled water (back half)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict buffer RockFill { float rock_fill[]; };            // bedrock mineral — scoured in place (cross-cell to DOWN, unique)
layout(set = 0, binding = 4, std430) restrict buffer Susp { float susp[]; };                     // susp back half — += scour, OWN-cell only
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// --- Tunables (behavioural, not parity-bound) -----------------------------------------------------------
const float WATER_MIN   = 0.02;   // a cell must hold real flowing water (> the wet-surface threshold) to scour
const float STREAM_K    = 0.25;   // scour per unit stream power (depth * head-gradient) per step
const float MAX_SCOUR   = 0.08;   // hard cap on bedrock lifted from one bed cell per step (anti-runaway)
const float ROCK_MIN    = 1.0e-4; // don't bother scouring a nearly-empty bed cell
const float HEAD_MIN    = 1.0e-3; // ignore negligible head differences (matches the water CA MIN_FLOW scale)

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	// susp[back] already holds this cell's advected load (ErosionTransportPass wrote it). Every early return
	// below therefore writes NOTHING — leaving that load exactly as transport left it.

	// Only OPEN, non-static (genuinely flowing) water cells scour. Rock and the held static sea are inert.
	if (solid[gidx] != 0.0) {
		return;
	}
	float depth = water_in[gidx];
	if (depth <= WATER_MIN) {
		return;
	}

	// The BED: the radial-DOWN neighbour must be bedrock with mineral to give.
	int ib = nbr[base + N_IN];
	if (ib < 0 || solid[ib] == 0.0 || rock_fill[uint(ib)] <= ROCK_MIN) {
		return;
	}

	// HEAD-GRADIENT: sum of positive water-surface excess over the 4 lateral neighbours (the same head that
	// drives the water CA's lateral flow) → large in a fast river on a slope, ~0 in a flat pond / the sea edge.
	float grad = 0.0;
	for (int d = 0; d < 4; d++) {
		int inb = nbr[base + N_LAT0 + uint(d)];
		if (inb < 0) {
			continue;
		}
		if (solid[inb] != 0.0) {
			continue;                       // a rock wall is not a downhill outlet
		}
		float diff = depth - water_in[uint(inb)];
		if (diff > HEAD_MIN) {
			grad += diff;
		}
	}
	if (grad <= HEAD_MIN) {
		return;                             // standing / calm water does not scour
	}

	// STREAM POWER = depth * head-gradient. Scour is capped per step AND by the bed's available mineral.
	float scour = STREAM_K * depth * grad;
	scour = min(scour, MAX_SCOUR);
	scour = min(scour, rock_fill[uint(ib)]);
	if (scour <= 0.0) {
		return;
	}

	rock_fill[uint(ib)] = rock_fill[uint(ib)] - scour;   // debit the bed (unique target per thread)
	susp[gidx] = susp[gidx] + scour;                     // credit own-cell suspension (conserving transfer)
}
