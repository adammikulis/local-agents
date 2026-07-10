#[compute]
#version 450

// CUBED-SPHERE OXYGEN — TRANSPORT pass. Sphere port of o2_transport3d.glsl. The box kernel gathered its six
// neighbours by idx arithmetic (±1, ±dim_x, ±layer) with dim-bounds ifs + a solid[] wall test, and biased the
// diffusion share by the wind blowing TOWARD each neighbour (share(toward) = DIFFUSE + ADVECT * ...). On the
// cubed sphere every cell gathers its six neighbours from the precomputed INDEX TABLE nbr[idx*6 + d]
// (nbr == -1 → boundary, skipped); a solid neighbour donates AND receives nothing, so O₂ never crosses stone
// (this is what emergently SEALS caves).
//
// NON-MECHANICAL: the wind ADVECTION term is DROPPED here. The box kernel projects the world-space wind vector
// onto each neighbour direction (share(vxi) for +x, share(-vxi) for -x, …). The sphere neighbour table carries
// only indices, not per-slot world directions, and on a cubed sphere the lateral neighbours point in varying
// world directions — so the directional bias cannot be mechanically preserved. This pass keeps the SYMMETRIC
// diffusion share only (DIFFUSE per open neighbour), i.e. exactly the box kernel with wind = 0: still
// mass-conserving and pairwise-symmetric. DIFFUSE is copied EXACTLY from MaterialGas3D.gd. Reads only the OLD
// o2 snapshot (o2_in) + solid, writes o2_out[g] → order-independent.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer O2In  { float o2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer O2Out { float o2_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Transport tunable — MUST match MaterialGas3D.gd exactly. (ADVECT/wind dropped on the sphere; see header.)
const float DIFFUSE = 0.12;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		o2_out[g] = 0.0;
		return;
	}
	// Symmetric diffusion: each OPEN neighbour exchanges a fixed DIFFUSE share (pairwise-conserving).
	float acc = o2_in[g];
	for (int d = 0; d < 6; d++) {
		int nb = nbr[g * 6u + uint(d)];
		if (nb >= 0 && solid[nb] == 0.0) {
			acc += DIFFUSE * (o2_in[nb] - o2_in[g]);
		}
	}
	o2_out[g] = max(0.0, acc);
}
