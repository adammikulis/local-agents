#[compute]
#version 450

// GPU 3D heat BUOYANCY pass — port of MaterialHeat3D.step() PART 3 (hot void rises). Runs AFTER solar,
// IN PLACE on the post-solar temp buffer. The CPU oracle sweeps iy ASCENDING and, for each void cell
// hotter than the void cell above it, convects a share of the difference upward — a strictly SEQUENTIAL
// up-the-column update where heat pushed into a cell is available to convect further up in the same
// pass. Buoyancy only ever couples a cell with the one directly ABOVE it (same ix,iz), so it is purely
// INTRA-COLUMN: one invocation PER XZ COLUMN (dispatch over dim_x*dim_z) that loops iy ascending over its
// OWN column reproduces the CPU sweep EXACTLY (a single invocation's writes are visible to its own later
// reads, and no other invocation touches this column). Constant copied EXACTLY from MaterialHeat3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix. Column index c = iz*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint col_count;     // dim_x * dim_z
} params;

// Constant — MUST match MaterialHeat3D.gd exactly.
const float BUOYANCY = 0.18;

void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c >= params.col_count) {
		return;
	}
	uint dim_x = params.dim_x;
	uint dim_y = params.dim_y;
	uint dim_z = params.dim_z;
	uint ix = c % dim_x;
	uint iz = c / dim_x;
	uint layer = dim_x * dim_z;

	// Ascending Y sweep over this column (iy = 0 .. dim_y-2), exactly mirroring the CPU outer loop's order
	// for a fixed (ix,iz): each iteration may raise temp[iu], which the next iteration reads as temp[i].
	for (uint iy = 0u; iy + 1u < dim_y; iy++) {
		uint i = (iy * dim_z + iz) * dim_x + ix;
		if (solid[i] != 0.0) {
			continue;
		}
		uint iu = i + layer;
		if (solid[iu] != 0.0) {
			continue;
		}
		float d = temp[i] - temp[iu];
		if (d > 0.0) {
			float move = BUOYANCY * d * 0.5;
			temp[i] -= move;
			temp[iu] += move;
		}
	}
}
