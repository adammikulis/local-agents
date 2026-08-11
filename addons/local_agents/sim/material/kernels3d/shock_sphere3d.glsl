#[compute]
#version 450

// `shock` is a DIMENSIONLESS intensity, not energy. Its seed magnitude is set by the emitting actor, it is
// on no conservation ledger, and its only consumers are the panic gradient, the camera shake and the impact
// counter. SPREAD and LOSS below are per STEP, not per second, so both the propagation speed and the decay
// scale with the step rate rather than with simulated time.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ShockIn  { float shock_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ShockOut { float shock_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid     { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh    { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const float SPREAD = 0.15;   // per-neighbour diffusion weight (<= 1/6 for stability)
const float LOSS = 0.25;     // fraction of the intensity discarded per step; neither derived nor cited

void main() {
	// One invocation per ACTIVE cell. A cell absent from the list has shock 0 in BOTH ping-pong halves and
	// zero shock in all six neighbours, so this kernel would have written exactly 0.0 into a slot already 0.
	uint t = gl_GlobalInvocationID.x;
	if (t >= active_args[3]) {
		return;
	}
	uint g = active_idx[t];
	if (g >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	if (solid[g] != 0.0) {
		shock_out[g] = 0.0;             // the channel propagates through open cells only
		return;
	}
	float s0 = shock_in[g];
	// GATHER six neighbours; a solid / boundary neighbour REFLECTS (contributes s0). Always six
	// contributions → self-weight below is 1 - 6*SPREAD.
	float nsum = 0.0;
	for (int d = 0; d < 6; d++) {
		int nb = nbr[g * 6u + uint(d)];
		nsum += (nb >= 0 && solid[nb] == 0.0) ? shock_in[nb] : s0;
	}
	float keep = 1.0 - LOSS;
	float self_w = 1.0 - 6.0 * SPREAD;
	shock_out[g] = keep * (self_w * s0 + SPREAD * nsum);
}
