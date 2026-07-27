#[compute]
#version 450

// CUBED-SPHERE SCENT — surface-wind PRECOMPUTE. Sphere port of scent_wind3d.glsl. The box kernel dispatched one
// invocation per XZ COLUMN and copied the resident wind (vel_x/vel_z) of that column's TOPMOST OPEN cell into a
// per-column surf_vx/surf_vz scratch. On the sphere there are no columns, so we dispatch PER CELL (like
// heat_sphere3d, `if (idx >= cell_count) return;`) and write the surface wind into a PER-CELL buffer keyed by
// the same cell index as every other sphere field (surf_vx[idx] / surf_vz[idx], sized cell_count).
//
// SURFACE / SKY cell on the sphere: a cell is the surface iff it is OPEN (solid == 0) and its OUTWARD-radial
// neighbour (nbr slot 5) is -1 (space boundary) or solid — i.e. the OUTERMOST open cell reached walking slot 5
// outward until -1 or rock (the local landing-set form of that walk). Its resident wind is copied to its own
// surf slot; every non-surface cell writes 0. Each cell touches only its own slot → race-free.
//
// DECISION — this precompute is produced for completeness/parity, but note scent_transport_sphere3d currently
// DROPS the wind-advection term (the sphere neighbour table carries only indices, not per-slot world
// directions, so a directional bias cannot be mechanically preserved) and keeps symmetric diffusion only. So on
// the sphere these surf_vx/surf_vz outputs are not yet consumed by scent transport; they are the faithful port
// of the box precompute and are available for any pass that later wants a per-cell surface wind.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VelX   { float vel_x[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer VelZ   { float vel_z[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer SurfVx { float surf_vx[]; };  // per-cell (cell_count)
layout(set = 0, binding = 4, std430) restrict writeonly buffer SurfVz { float surf_vz[]; };  // per-cell (cell_count)
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh  { int nbr[]; };        // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	bool is_surface = false;
	if (solid[idx] == 0.0) {
		int up = nbr[idx * 6u + 5u];
		is_surface = (up < 0) || (solid[up] != 0.0);
	}
	if (is_surface) {
		surf_vx[idx] = vel_x[idx];
		surf_vz[idx] = vel_z[idx];
	} else {
		surf_vx[idx] = 0.0;
		surf_vz[idx] = 0.0;
	}
}
