#[compute]
#version 450

// GPU SCENT — surface-wind PRECOMPUTE. One invocation per XZ column (dispatch over dim_x*dim_z). It finds the
// column's TOPMOST OPEN cell (scan iy from dim_y-1 down to the first non-solid cell, mirroring
// MaterialField3D._surface_iy) and copies the resident per-cell wind (vel_x/vel_z) there into the surf_vx/
// surf_vz column scratch — exactly the per-column surface wind LAMaterialScent3D.step() computes once before
// the transport gather. Columns are independent (each writes only its own surf slot), so it is race-free.
//
// Index layout for the full 3D vel/solid buffers: idx = (iy*dim_z + iz)*dim_x + ix. Column index: c = iz*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VelX   { float vel_x[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer VelZ   { float vel_z[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer SurfVx { float surf_vx[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer SurfVz { float surf_vz[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint area;
} params;

void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c >= params.area) {
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint ix = c % dx;
	uint iz = c / dx;
	for (int iy = int(dy) - 1; iy >= 0; iy--) {
		uint si = (uint(iy) * dz + iz) * dx + ix;
		if (solid[si] == 0.0) {
			surf_vx[c] = vel_x[si];
			surf_vz[c] = vel_z[si];
			return;
		}
	}
	surf_vx[c] = 0.0;
	surf_vz[c] = 0.0;
}
