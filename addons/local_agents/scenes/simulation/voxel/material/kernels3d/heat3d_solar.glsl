#[compute]
#version 450

// GPU 3D heat SOLAR/AMBIENT pass — port of MaterialHeat3D.step() PART 2. Runs AFTER conduction, IN PLACE
// on the post-conduction temp buffer. One invocation PER XZ COLUMN (dispatch over dim_x*dim_z, not
// cell_count). The CPU oracle's column loop `break`s on its very first iteration in BOTH branches, so it
// only ever touches the TOPMOST cell (iy = dim_y-1) of each column: if that cell is non-solid it relaxes
// it toward the solar/ambient target, otherwise the column has no sky cell. This kernel replicates that
// exactly (top cell only). Columns are independent, so this is race-free without double-buffering.
// Constants + the target formula are copied EXACTLY from MaterialHeat3D.gd — do not diverge.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix. Column index c = iz*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	float solar;        // 0..1 sun factor (energy x elevation), computed on the CPU from the scene sun
	float origin_y;     // world Y of cell (0,0,0) centre
	float cell_size;
	float sea_level;
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint col_count;     // dim_x * dim_z
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float AMBIENT_NIGHT = 6.0;
const float SOLAR_WARMTH = 18.0;
const float AMBIENT_RELAX = 0.05;
const float LAPSE = 0.06;

void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c >= params.col_count) {
		return;
	}
	uint dim_x = params.dim_x;
	uint dim_z = params.dim_z;
	uint ix = c % dim_x;
	uint iz = c / dim_x;
	uint iy = params.dim_y - 1u;                      // topmost cell — the only one the oracle touches
	uint i = (iy * dim_z + iz) * dim_x + ix;

	if (solid[i] != 0.0) {
		return;                                        // top cell is rock -> no sky cell for this column
	}
	float wy = params.origin_y + float(iy) * params.cell_size;
	float target = AMBIENT_NIGHT + SOLAR_WARMTH * params.solar
		- LAPSE * max(0.0, wy - params.sea_level);
	temp[i] += AMBIENT_RELAX * (target - temp[i]);
}
