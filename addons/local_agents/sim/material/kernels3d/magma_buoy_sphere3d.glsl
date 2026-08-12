#[compute]
#version 450

#include "neighbours.glsli"
#include "cellvol.glsli"

// precomputed INDEX TABLE `nbr[idx*6 + slot]` — N_OUT = UP (above), N_IN = DOWN (below);

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };       // lava[back] (rw)
layout(set = 0, binding = 1, std430) restrict buffer Scratch { float scratch[]; }; // stable snapshot
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };       // temp[back] (carry-heat)
layout(set = 0, binding = 41, std430) restrict buffer TempSnap { float temp_snap[]; };  // stable snapshot
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = copy snapshot, 1 = gather/apply
	uint pad0;
	uint pad1;
} params;

// The substrate's cell-fill unit — authority LAMaterialField3D (MaterialField3D.gd:26). That file exists.
const float MAX_MASS = 1.0;

// --- MODEL PARAMETERS. Properties of THIS kernel's overpressure rule; this file is their only declaration.
const float BUOY_FRAC = 0.55;
const float K_P = 0.6;
const float MAX_UP_FLOW = 0.4;
const float MIN_OP = 0.0001;
// MOLTEN_FLOOR = 950.0 and LAVA_EMPLACE_TEMP = 1150.0 used to live here and are gone: this kernel no longer

// Buoyant up-transfer a cell contributes given its lava mass — mirrors _buoy_up exactly.
float buoy_up(float mass) {
	float op = mass - MAX_MASS;
	if (op < MIN_OP) {
		return 0.0;
	}
	float flow = op * (BUOY_FRAC + K_P * op);
	return clamp(flow, 0.0, min(MAX_UP_FLOW, op));
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;

	if (params.pass_id == 0u) {
		scratch[g] = lava[g];
		temp_snap[g] = temp[g];
		return;
	}

	// PASS 1: gather. Solid cells hold no lava — pass the snapshot through unchanged.
	if (solid[g] != 0.0) {
		lava[g] = scratch[g];
		return;
	}
	float base_mass = scratch[g];
	float out_up = 0.0;
	float in_below = 0.0;

	// UP: overpressure we shed into the open cell above.
	int iu = nbr[base + N_OUT];
	if (iu >= 0 && solid[iu] == 0.0) {
		out_up = buoy_up(scratch[g]);
	}
	// DOWN: overpressure the open cell below buoys up into us.
	int ib = nbr[base + N_IN];
	if (ib >= 0 && solid[ib] == 0.0) {
		in_below = buoy_up(scratch[uint(ib)]) * vol_ratio(uint(ib), g);
	}
	lava[g] = base_mass - out_up + in_below;

	// Carry-heat: mass-weighted mix of this cell and what buoyed up into it. Both temperatures come from
	// the pass-0 snapshot, so the result does not depend on which cell the GPU scheduled first.
	if (in_below > 0.0 && ib >= 0) {
		temp[g] = (MAX_MASS * temp_snap[g] + in_below * temp_snap[uint(ib)]) / (MAX_MASS + in_below);
	}
}
