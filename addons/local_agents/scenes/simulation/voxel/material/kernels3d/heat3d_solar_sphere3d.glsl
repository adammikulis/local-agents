#[compute]
#version 450

// CUBED-SPHERE heat SOLAR/AMBIENT pass — THE TERMINATOR. Sphere port of heat3d_solar.glsl. The box kernel
// dispatched one invocation per XZ COLUMN and relaxed ONLY that column's topmost cell toward a target built
// from a SINGLE GLOBAL scalar `params.solar` (sun energy x elevation, computed on the CPU) — the whole grid
// saw the same sun. On a planet that is wrong: the sun lights one HEMISPHERE. Here we dispatch PER CELL (like
// heat_sphere3d, `if (idx >= cell_count) return;`) and compute PER-CELL insolation from the cell's own outward
// radial vs a world-space sun direction, so the day side warms and the night side cools — the real terminator
// falls straight out of the temperature field.
//
// SURFACE / SKY cell on the sphere: there are no columns. A cell is a SKY-EXPOSED surface cell iff it is OPEN
// (solid == 0) and its OUTWARD-radial neighbour (nbr slot 5) is -1 (space boundary) or solid — i.e. it is the
// OUTERMOST open cell reached walking slot 5 outward until you hit -1 or rock. That local test is exactly the
// landing set of the "walk slot 5 outward" the box did by scanning a column from the top down, and because each
// surface cell only touches ITSELF it is race-free. Non-surface cells are left as conduction produced them
// (mirrors the box touching only the top cell). Runs AFTER conduction, IN PLACE on the temp buffer.
//
// PER-CELL SOLAR: insolation = max(0, dot(cell_radial, sun_dir)); cell_radial = the binding-14 outward unit
// vector for this cell, sun_dir = the NEW sun_x/sun_y/sun_z push-constant (world-space unit vector to the sun).
// target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation, then relax by AMBIENT_RELAX. The night side relaxes to the
// bare AMBIENT_NIGHT floor; the sub-solar point to AMBIENT_NIGHT + SOLAR_WARMTH.
//
// DECISION — height-lapse + marine branch DROPPED. The box target also subtracted a lapse * (world_height -
// sea_level) and, for ocean columns, anchored to a warm marine air target. Both need the cell's world height /
// radius, but binding-14 radial is a UNIT vector (length 1) and no per-cell world-position buffer is available
// to a sphere kernel (only nbr=15 + radial=14 beyond the box's own temp/solid), and MaterialGPU3D must not be
// edited to add one. Per the port brief ("else keep the target formula but drive it by the per-cell
// insolation"), the lapse/marine terms are dropped and the ambient/solar target is driven purely by the
// per-cell insolation. Constants copied EXACTLY from MaterialHeat3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, packed flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };         // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float sun_x;        // NEW: world-space unit vector pointing TOWARD the sun
	float sun_y;
	float sun_z;
	float pad3;
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float AMBIENT_NIGHT = 6.0;
const float SOLAR_WARMTH = 18.0;
const float AMBIENT_RELAX = 0.05;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not a sky cell
	}
	// SKY-EXPOSED surface = outermost open cell (its outward-radial neighbour is space or rock).
	int up = nbr[idx * 6u + 5u];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;
	}
	// Per-cell insolation from this cell's outward radial vs the sun direction (the terminator).
	uint rb = idx * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 sun_dir = vec3(params.sun_x, params.sun_y, params.sun_z);
	float insolation = max(0.0, dot(cell_radial, sun_dir));

	float target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation;
	temp[idx] += AMBIENT_RELAX * (target - temp[idx]);
}
