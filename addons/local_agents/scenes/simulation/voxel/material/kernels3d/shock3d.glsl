#[compute]
#version 450

// GPU 3D SHOCK / SOUND pressure-wave — a race-free GATHER port of LAMaterialShock3D.step(): each non-solid
// cell relaxes toward the average of its six OPEN neighbours (a SOLID/out-of-bounds neighbour REFLECTS,
// reading this cell's OWN value, so shock never transmits through rock — a blast behind a ridge is muffled
// emergently) and loses a fixed LOSS fraction each step so an acute blast fades in ~1-2 s. Reads only the OLD
// shock snapshot (shock_in) + solid, writes shock_out[g], so it is order-independent and mirrors the CPU
// oracle bit-for-bit. Emit points are folded into shock_in on the CPU (re-uploaded each frame). Runs as its
// own pass in LAMaterialGPU3D.step(); the GPU has no idle-skip (the whole grid is cheap on-device).
//
// Constants copied EXACTLY from MaterialShock3D.gd. Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ShockIn  { float shock_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ShockOut { float shock_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid     { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Wave tuning — MUST match MaterialShock3D.gd exactly.
const float SPREAD = 0.15;   // per-neighbour diffusion weight (<= 1/6 for stability)
const float LOSS = 0.25;     // fraction of shock energy lost per step

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	if (solid[g] != 0.0) {
		shock_out[g] = 0.0;             // rock carries no shock energy
		return;
	}
	uint iy = g / layer;
	uint rem = g - iy * layer;
	uint iz = rem / dx;
	uint ix = rem - iz * dx;

	float s0 = shock_in[g];
	// GATHER the 6 neighbours; a solid / out-of-bounds neighbour REFLECTS (reads s0) so energy stays on this
	// side of the wall — shock never transmits through rock.
	float nsum = 0.0;
	nsum += (ix > 0u && solid[g - 1u] == 0.0)        ? shock_in[g - 1u]     : s0;
	nsum += (ix < dx - 1u && solid[g + 1u] == 0.0)   ? shock_in[g + 1u]     : s0;
	nsum += (iz > 0u && solid[g - dx] == 0.0)        ? shock_in[g - dx]     : s0;
	nsum += (iz < dz - 1u && solid[g + dx] == 0.0)   ? shock_in[g + dx]     : s0;
	nsum += (iy > 0u && solid[g - layer] == 0.0)     ? shock_in[g - layer]  : s0;
	nsum += (iy < dy - 1u && solid[g + layer] == 0.0)? shock_in[g + layer]  : s0;

	float keep = 1.0 - LOSS;
	float self_w = 1.0 - 6.0 * SPREAD;
	shock_out[g] = keep * (self_w * s0 + SPREAD * nsum);
}
