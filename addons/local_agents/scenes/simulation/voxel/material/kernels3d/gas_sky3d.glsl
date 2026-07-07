#[compute]
#version 450

// GPU 3D GAS — SKY EXCHANGE + SKY VENT pass. A per-COLUMN port of LAMaterialGas3D._sky_exchange() +
// _co2_sky_vent(): one invocation per XZ column (dispatch over dim_x*dim_z). It finds the column's TOPMOST
// OPEN cell (the sky-exposed surface — scan iy from dim_y-1 down to the first non-solid cell, mirroring
// MaterialField3D._surface_iy) and, IN PLACE on that cell:
//   O₂  — relaxes toward O2_AMBIENT by SKY_EXCHANGE (the open atmosphere breathes it back in).
//   CO₂ — sheds toward 0 by CO2_SKY_VENT (the free atmosphere carries it off).
// A sealed cave's cells are never a surface cell, so they get NO replenishment and NO venting — the emergent
// suffocation seal: trapped O₂ draws down and trapped CO₂ pools until wind/plants flush it. Columns are
// independent (each touches only its own surface cell), so this is race-free.
//
// Runs AFTER the o2/co2 transport gather (o2_transport3d / co2_transport3d), in place on their output buffers.
// Constants copied EXACTLY from MaterialGas3D.gd. Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer O2  { float o2[]; };
layout(set = 0, binding = 1, std430) restrict buffer CO2 { float co2[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialGas3D.gd exactly.
const float O2_AMBIENT = 1.0;
const float SKY_EXCHANGE = 0.5;
const float CO2_SKY_VENT = 0.25;

void main() {
	uint c = gl_GlobalInvocationID.x;
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint col_count = dx * dz;
	if (c >= col_count) {
		return;
	}
	uint ix = c % dx;
	uint iz = c / dx;

	// Topmost OPEN cell of this column (mirrors MaterialField3D._surface_iy: scan down from the top).
	for (int iy = int(dy) - 1; iy >= 0; iy--) {
		uint si = (uint(iy) * dz + iz) * dx + ix;
		if (solid[si] == 0.0) {
			o2[si] += SKY_EXCHANGE * (O2_AMBIENT - o2[si]);
			co2[si] = max(0.0, co2[si] - CO2_SKY_VENT * co2[si]);
			return;
		}
	}
}
