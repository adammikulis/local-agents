#[compute]
#version 450

// CUBED-SPHERE SHOCK / SOUND pressure-wave. Sphere port of shock3d.glsl. The box kernel gathered its six
// neighbours by idx arithmetic (±1, ±dim_x, ±layer) with dim-bounds ifs, where a SOLID or out-of-bounds
// neighbour REFLECTS (reads this cell's OWN value s0) so shock never transmits through rock — a blast behind a
// ridge is muffled emergently. On the cubed sphere every cell gathers its six neighbours from the precomputed
// INDEX TABLE nbr[idx*6 + d]; a boundary slot (nbr == -1) or a solid neighbour REFLECTS exactly as before.
//
// This is a fully MECHANICAL conversion: the wave has no gravity direction, so all six slots are symmetric.
// The self-weight stays 1 - 6*SPREAD because there are always six reflecting-or-open contributions. Reads only
// the OLD shock snapshot (shock_in) + solid, writes shock_out[g] → order-independent.
//
// THIS FILE IS THE ONLY DECLARATION OF SPREAD AND LOSS. *(Corrected 2026-08-09. The line above used to end
// "Constants copied EXACTLY from MaterialShock3D.gd" and the const block said "MUST match MaterialShock3D.gd
// exactly". LAMaterialShock3D EXISTS — which is why this one survived a sweep that was looking for deleted
// files — but it holds SHOCK_ACTIVE and SEED_NEIGHBOUR_FRACTION and nothing else: no SPREAD, no LOSS. A grep
// for either name returns this file alone. A pointer at a file that exists but does not carry the constant is
// the same defect as a pointer at a deleted one and is harder to catch, because checking that the file exists
// is not checking that the contract does. scent_transport_sphere3d.glsl had the identical failure.)*

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

// MODEL PARAMETERS, owned here (see the header for what used to be claimed). Properties of this explicit
// stencil, not of air or rock: SPREAD is bounded by the stencil's own stability limit (<= 1/6, so the
// self-weight 1 - 6*SPREAD stays non-negative) and LOSS is a per-STEP attenuation, so both are tied to this
// grid and this timestep rather than to a material. The real quantity a blast wave's decay is a property of —
// acoustic absorption plus geometric spreading, which for a spherical wave falls as 1/r before any absorption
// at all — is not what either of these expresses, and neither is a speed of sound: this kernel diffuses shock,
// it does not propagate it at a physical velocity.
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
