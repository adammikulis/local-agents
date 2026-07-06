#[compute]
#version 450

// GPU 3D atmosphere RAIN GATHER — the race-free cross-cell WRITE half of MaterialAtmosphere3D's
// precipitation. atmos_condense3d already subtracted each raining cell's rain from its cloud and stored
// the rain MASS in the per-cell `rain` scratch. The CPU oracle then does `_water[target] += rain`, where
// target = the cell BELOW when that below cell is open (so gravity later carries the drop down), else the
// raining cell itself (a cell resting on the ground or at the world floor rains into itself). This gather
// inverts that: each cell sums the rain aimed AT it — its own rain if it rains into itself, plus the rain
// from the cell directly above when that cell rains down into this (open) cell. One invocation per cell.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Rain { float rain[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;

	// The CPU only ever adds rain into non-solid cells (target is always an open cell). Solid cells are
	// left untouched.
	if (solid[g] != 0.0) {
		return;
	}

	float add = 0.0;

	// SELF: this cell rains into itself when there is no open cell below it (bottom of the world, or solid
	// directly below) — target resolved to idx in the oracle.
	float r_self = rain[g];
	if (r_self > 0.0) {
		bool self_target = (iy == 0);
		if (!self_target && solid[idx - layer] != 0.0) {
			self_target = true;
		}
		if (self_target) {
			add += r_self;
		}
	}

	// FROM ABOVE: the cell directly above rains DOWN into this (open) cell — its target = idx because idx
	// is non-solid. (If idx were solid the above cell would rain into itself; handled by the guard above.)
	if (iy < dim_y - 1) {
		float r_above = rain[idx + layer];
		if (r_above > 0.0) {
			add += r_above;
		}
	}

	if (add != 0.0) {
		water[g] = water[g] + add;
	}
}
