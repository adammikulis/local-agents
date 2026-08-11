#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ShockIn  { float shock_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ShockOut { float shock_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid     { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh    { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const float SPREAD = 0.15;   // per-neighbour diffusion weight (<= 1/6 for stability)
const float LOSS = 0.25;     // fraction of shock energy lost per step

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		shock_out[g] = 0.0;             // rock carries no shock energy
		return;
	}
	float s0 = shock_in[g];
	// GATHER six neighbours; a solid / boundary neighbour REFLECTS (contributes s0) so energy stays on this
	// side of the wall. Always six contributions → self-weight below is 1 - 6*SPREAD.
	float nsum = 0.0;
	for (int d = 0; d < 6; d++) {
		int nb = nbr[g * 6u + uint(d)];
		nsum += (nb >= 0 && solid[nb] == 0.0) ? shock_in[nb] : s0;
	}
	float keep = 1.0 - LOSS;
	float self_w = 1.0 - 6.0 * SPREAD;
	shock_out[g] = keep * (self_w * s0 + SPREAD * nsum);
}
