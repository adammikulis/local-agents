#[compute]
#version 450

// GPU 3D SNOW phase — the per-COLUMN CORE of MaterialSnowIce3D._step_snow(): where it is precipitating and
// the surface cell is at/below freezing, the falling precipitation ACCRETES as snowpack (a per-column depth);
// where the surface is above the melt point the pack MELTS at a rate ∝ how far over it is, pouring meltwater
// into the surface water cell (the water CA then swells the rivers below — spring melt, unscripted). One
// invocation per XZ column (dispatch over dim_x*dim_z). Reads the post-heat temperature + the frame's
// precipitation (push constant), writes the per-column snow depth in place and adds meltwater to water[back].
//
// The WATER FREEZE/THAW phase (water <-> ice, marking cells solid + the fill_sphere/carve_sphere SDF stamps +
// the solid-mask re-upload) stays a capped CPU tail (MaterialSnowIce3D.step_scene_only) — exactly like lava's
// solidify/melt SDF stamps — because it edits the terrain geometry + rock mask. Constants copied EXACTLY from
// MaterialSnowIce3D.gd. Index layout: idx = (iy*dim_z + iz)*dim_x + ix; column = iz*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Snow { float snow[]; };          // per-column depth (dim_x*dim_z), in place
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; }; // per-cell
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };        // per-cell (+= meltwater)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float precip;
	float pad0;
	float pad1;
	float pad2;
} params;

// Constants — MUST match MaterialSnowIce3D.gd exactly.
const float SNOW_T = 0.0;
const float MELT_T = 2.0;
const float SNOW_FALL_RATE = 0.03;
const float SNOW_MIN = 0.001;
const float MELT_RATE = 0.02;
const float MELT_MAX_PER_STEP = 0.15;
const float SNOW_WATER_YIELD = 0.3;

void main() {
	uint g = gl_GlobalInvocationID.x;
	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int area = dim_x * dim_z;
	if (g >= uint(area)) {
		return;
	}
	int col = int(g);
	int iz = col / dim_x;
	int ix = col - iz * dim_x;

	// Topmost SOLID (ground) cell in this column.
	int giy = -1;
	for (int iy = dim_y - 1; iy >= 0; iy--) {
		if (solid[(iy * dim_z + iz) * dim_x + ix] != 0.0) {
			giy = iy;
			break;
		}
	}
	if (giy < 0 || giy >= dim_y - 1) {
		return;                                            // no ground, or no surface air cell above it
	}
	int si = ((giy + 1) * dim_z + iz) * dim_x + ix;
	if (solid[si] != 0.0) {
		return;
	}

	float st = temp[si];
	float depth = snow[col];
	float falling = params.precip * SNOW_FALL_RATE;
	if (falling > 0.0 && st < SNOW_T) {
		depth += falling;                                  // cold + precipitating -> precip becomes snowpack
	} else if (st > MELT_T && depth > 0.0) {
		float melted = min(depth, min(MELT_MAX_PER_STEP, (st - MELT_T) * MELT_RATE));
		if (melted > 0.0) {
			depth -= melted;
			water[si] += melted * SNOW_WATER_YIELD;        // meltwater feeds the river CA at the surface cell
		}
	}
	if (depth < SNOW_MIN) {
		depth = 0.0;
	}
	snow[col] = depth;
}
