#[compute]
#version 450

// CUBED-SPHERE SCENT — soil FERTILITY pass. Sphere port of scent_fert3d.glsl. This is a per-SURFACE-CELL 2D
// field: one invocation per surface cell (dispatch over surf_count). The box kernel blurred toward its 4 lateral
// column-neighbours by idx arithmetic (±1, ±dim_x) with dim-bounds ifs, then leached a slow fraction (faster in
// rain). On the sphere each surface cell blurs toward its 4 LATERAL neighbours from the surface index table
// nbr[cell*6 + d], slots 1..4 (radial slots 0 and 5 SKIPPED for this 2D surface field); a boundary slot -1 is
// skipped.
//
// This is a fully MECHANICAL conversion — the box already had no wind, only an isotropic FERT_BLUR. The self
// weight stays 1 - 4*FERT_BLUR (four blur contributions on the closed surface). Reads only the OLD fertility
// snapshot (fert_in), writes fert_out → order-independent. Constants copied EXACTLY from MaterialScent3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertIn  { float fert_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FertOut { float fert_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh  { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;   // = surf_count
	uint pad0;
	uint pad1;
	float precip;
} params;

// Tunables — MUST match MaterialScent3D.gd exactly.
const float FERT_DECAY = 0.0015;
const float FERT_RAIN_LEACH = 0.02;
const float FERT_BLUR = 0.04;

void main() {
	uint cell = gl_GlobalInvocationID.x;
	if (cell >= params.cell_count) {
		return;
	}
	float leach = FERT_DECAY + params.precip * FERT_RAIN_LEACH;
	float here = fert_in[cell];
	float acc = here * (1.0 - 4.0 * FERT_BLUR);
	// Soil creep: blur toward the 4 LATERAL neighbours (table slots 1..4).
	for (int d = 1; d < 5; d++) {
		int nb = nbr[cell * 6u + uint(d)];
		if (nb >= 0) {
			acc += FERT_BLUR * fert_in[uint(nb)];
		}
	}
	fert_out[cell] = max(0.0, acc * (1.0 - leach));
}
