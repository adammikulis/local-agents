#[compute]
#version 450

// GPU FUNGUS FERTILITY — per-column reduce. One invocation per XZ column (dispatch over dim_x*dim_z). It sums
// the per-cell fertility that fungus3d.glsl produced this step (fert_cell = FERT_PER_DECOMPOSE*consumed) down
// the WHOLE column and ADDS it into the scent soil-fertility field at that column — the GPU form of
// LAMaterialFungus3D depositing fertility at each decomposing cell's column via the scent module, closing the
// rot→soil→plant loop on-device. Race-free (each column touches only its own fert slot). Runs AFTER the scent
// fertility blur/leach pass (scent_fert3d), in place on its output. Column index: col = iz*dim_x + ix, matching
// MaterialScent3D's per-column packing. Cell index: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertCell { float fert_cell[]; };
layout(set = 0, binding = 1, std430) restrict buffer Fert { float fert[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

void main() {
	uint c = gl_GlobalInvocationID.x;
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint area = dx * dz;
	if (c >= area) {
		return;
	}
	uint ix = c % dx;
	uint iz = c / dx;
	float sum = 0.0;
	for (uint iy = 0u; iy < dy; iy++) {
		uint idx = (iy * dz + iz) * dx + ix;
		sum += fert_cell[idx];
	}
	fert[c] += sum;
}
