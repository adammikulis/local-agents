#[compute]
#version 450

// GPU SCENT — soil FERTILITY pass. A race-free GATHER port of LAMaterialScent3D._step_fertility(): one
// invocation per XZ column (dispatch over dim_x*dim_z). Each column gently blurs toward its 4 lateral
// neighbours (soil creep) and leaches a slow fraction each step (faster in rain). Reads only the OLD fertility
// snapshot (fert_in), writes fert_out, so it is order-independent. Waste deposits + budgeted plant-seeding
// stay on the CPU (they touch the ecology); this pass is the pure diffusion+leach field update.
//
// Constants copied EXACTLY from MaterialScent3D.gd. Column index: col = iz*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertIn  { float fert_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FertOut { float fert_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_z;
	uint area;
	float precip;
} params;

// Tunables — MUST match MaterialScent3D.gd exactly.
const float FERT_DECAY = 0.0015;
const float FERT_RAIN_LEACH = 0.02;
const float FERT_BLUR = 0.04;

void main() {
	uint col = gl_GlobalInvocationID.x;
	if (col >= params.area) {
		return;
	}
	uint dx = params.dim_x;
	uint dz = params.dim_z;
	uint ix = col % dx;
	uint iz = col / dx;
	float leach = FERT_DECAY + params.precip * FERT_RAIN_LEACH;
	float here = fert_in[col];
	float acc = here * (1.0 - 4.0 * FERT_BLUR);
	if (ix < dx - 1u) { acc += FERT_BLUR * fert_in[col + 1u]; }
	if (ix > 0u)      { acc += FERT_BLUR * fert_in[col - 1u]; }
	if (iz < dz - 1u) { acc += FERT_BLUR * fert_in[col + dx]; }
	if (iz > 0u)      { acc += FERT_BLUR * fert_in[col - dx]; }
	fert_out[col] = max(0.0, acc * (1.0 - leach));
}
