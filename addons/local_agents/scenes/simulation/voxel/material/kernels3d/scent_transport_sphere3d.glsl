#[compute]
#version 450

// CUBED-SPHERE SCENT — TRANSPORT pass. Sphere port of scent_transport3d.glsl. This is a per-SURFACE-CELL 2D
// field: one invocation per surface cell (dispatch over surf_count), with the 5 channels packed as
// base = ch*surf_count. The box kernel gathered its 4 lateral column-neighbours by idx arithmetic (±1, ±dim_x)
// and wind-biased the share by the surface wind toward each neighbour. On the sphere each surface cell gathers
// its 4 LATERAL neighbours from the surface index table nbr[cell*6 + d], slots 1..4 (the radial slots 0 and 5
// are the inward/outward directions and are SKIPPED for this 2D surface field). A boundary slot (nbr == -1) is
// skipped.
//
// NON-MECHANICAL: the wind ADVECTION term is DROPPED (as in o2_transport_sphere3d). The box kernel projects the
// surface wind (surf_vx/surf_vz) onto each lateral direction; the sphere neighbour table carries only indices,
// not per-slot world directions, so the directional bias cannot be mechanically preserved. This pass keeps the
// SYMMETRIC diffusion share only (DIFFUSE per open lateral neighbour) — i.e. the box kernel with wind = 0 —
// plus the per-channel DECAY and the rain-wash (precip * RAIN_WASH), all copied EXACTLY from MaterialScent3D.gd.
// Reads only the OLD scent snapshot (scent_in), writes scent_out → order-independent.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ScentIn  { float scent_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ScentOut { float scent_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh   { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;   // = surf_count (also the per-channel stride)
	uint pad0;
	uint pad1;
	float precip;
} params;

// Tunables — MUST match MaterialScent3D.gd exactly. (ADVECT/wind dropped on the sphere; see header.)
const float DIFFUSE = 0.08;
const float RAIN_WASH = 0.30;            // extra decay * precipitation()
const int CHANNELS = 5;
// Per-channel decay per step (PREY, PREDATOR, BLOOD, FOOD, ALARM) — MaterialScent3D.DECAY.
const float DECAY[5] = float[5](0.030, 0.030, 0.100, 0.015, 0.045);

void main() {
	uint cell = gl_GlobalInvocationID.x;
	if (cell >= params.cell_count) {
		return;
	}
	uint stride = params.cell_count;

	for (int ch = 0; ch < CHANNELS; ch++) {
		uint base = uint(ch) * stride;
		float here = scent_in[base + cell];
		float acc = here;
		// Symmetric diffusion across the 4 LATERAL neighbours (table slots 1..4); pairwise-conserving.
		for (int d = 1; d < 5; d++) {
			int nb = nbr[cell * 6u + uint(d)];
			if (nb >= 0) {
				acc += DIFFUSE * (scent_in[base + uint(nb)] - here);
			}
		}
		float dec = DECAY[ch] + params.precip * RAIN_WASH;
		scent_out[base + cell] = max(0.0, acc * (1.0 - dec));
	}
}
