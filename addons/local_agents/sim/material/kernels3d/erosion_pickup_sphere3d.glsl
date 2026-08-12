#[compute]
#version 450

#include "neighbours.glsli"

layout(local_size_x = 64) in;

// A cell scours ONLY its radial-DOWN neighbour, and a bed cell is solid so it never scours in turn. Every
// write below therefore has exactly one author: rock_fill/temp at the bed, susp/temp at the scourer.
layout(set = 0, binding = 0, std430) readonly buffer Water { float water[]; };       // settled water (back half)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };         // in place
layout(set = 0, binding = 3, std430) buffer RockFill { float rock_fill[]; };         // bedrock mineral, scoured in place
layout(set = 0, binding = 4, std430) buffer Susp { float susp[]; };                  // susp back half, own-cell only
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; }; // idx*6 + slot
// Carriers this kernel does not use itself, bound because rc_shared.glsli needs every one of them.
layout(set = 0, binding = 19, std430) readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 20, std430) readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 30, std430) readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 32, std430) readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) readonly buffer Porosity { float porosity[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

#include "cellvol.glsli"
#include "rc_shared.glsli"

// Cell heat capacity gained per unit fill of arriving mineral, J/m3K: its own capacity less the air it
// displaces, since rc_of() fills the unoccupied fraction with air.
const float MINERAL_RC_GAIN = RC_ROCK - RC_AIR;

const float WATER_MIN   = 0.02;   // a cell must hold real flowing water to scour
const float STREAM_K    = 0.25;   // scour per unit stream power (depth * head-gradient) per step
const float MAX_SCOUR   = 0.08;   // cap on bedrock lifted from one bed cell per step
const float ROCK_MIN    = 1.0e-4;
const float HEAD_MIN    = 1.0e-3;

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	// susp[back] already holds this cell's advected load; every early return leaves it untouched.
	if (solid[gidx] != 0.0) {
		return;
	}
	float depth = water[gidx];
	if (depth <= WATER_MIN) {
		return;
	}

	int ib = nbr[base + N_IN];
	if (ib < 0 || solid[ib] == 0.0 || rock_fill[uint(ib)] <= ROCK_MIN) {
		return;
	}

	// Head gradient: the sum of positive water-surface excess over the four lateral neighbours, which are
	// all in this cell's own shell and so already in its fill units.
	float grad = 0.0;
	for (int d = 0; d < 4; d++) {
		int inb = nbr[base + N_LAT0 + uint(d)];
		if (inb < 0 || solid[inb] != 0.0) {
			continue;
		}
		float diff = depth - water[uint(inb)];
		if (diff > HEAD_MIN) {
			grad += diff;
		}
	}
	if (grad <= HEAD_MIN) {
		return;
	}

	// Stream power = depth * head gradient, capped per step and by the bed's available mineral.
	float scour = STREAM_K * depth * grad;
	scour = min(scour, MAX_SCOUR);
	scour = min(scour, rock_fill[uint(ib)]);
	if (scour <= 0.0) {
		return;
	}

	// `rock_fill` is a saturation of the cell's rock MATRIX; the mineral in it is the pore-free share, which
	// is what actually crosses into suspension. rc_of() reads it the same way.
	float mineral = scour * (1.0 - clamp(porosity[uint(ib)], 0.0, 1.0));
	// Capacity of everything already here, read before susp is written.
	float rc_here = rc_of(gidx);
	float gain = mineral * vol_ratio(uint(ib), gidx);

	rock_fill[uint(ib)] = rock_fill[uint(ib)] - scour;
	susp[gidx] = susp[gidx] + gain;

	// The bed keeps its temperature — what left carried exactly its own enthalpy — and this cell mixes that
	// enthalpy in against the heat capacity it already had.
	float gain_c = gain * MINERAL_RC_GAIN;
	float denom = rc_here + gain_c;
	if (gain_c > 0.0 && denom > 0.0) {
		temp[gidx] = (rc_here * temp[gidx] + gain_c * temp[uint(ib)]) / denom;
	}
}
