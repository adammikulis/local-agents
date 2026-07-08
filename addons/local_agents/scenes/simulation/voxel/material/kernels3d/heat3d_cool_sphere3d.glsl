#[compute]
#version 450

// CUBED-SPHERE heat EVAPORATIVE-COOLING pass — sphere port of heat3d_cool3d.glsl (heat3d_cool.glsl, box).
// Runs LAST in the heat chain, IN PLACE on the temp buffer, reading the POST-FLOW water (a wet cell sheds
// heat toward the sea target so rivers/sea act as a heat sink + firebreak). Purely per-cell independent.
//
// DEPTH ON THE SPHERE: the box derived a thermocline target from the cell's world height wy = origin_y +
// iy*cell_size, then depth = max(0, sea_level - wy). On the cubed sphere "up" is the OUTWARD RADIAL, so the
// physically-correct depth is measured against the sea RADIUS, not a Y plane. This kernel therefore reads the
// cell's world position (bound Pos buffer) and uses its RADIUS (= length(pos)) in place of wy, with the sea
// surface given as a radius (sea_radius). The sea_water_target curve itself is byte-for-byte the box's
// (warm skin near the surface decaying to the cold deep floor across THERMOCLINE_SCALE). This is the one
// non-trivial change; everything else — the wet-cell gate, the knife-edge water >= 0.05 test, the relax
// math — is IDENTICAL. Constants copied EXACTLY from MaterialHeat3D.gd — do not diverge.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { vec4 cell_pos[]; };   // world position per cell (xyz)

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float sea_radius;   // world radius of the sea surface (replaces the box's planar sea_level)
	float pad0;
	float pad1;
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float WATER_COOL_RATE = 0.12;
const float SST_SURFACE = 26.0;
const float WATER_TEMP_DEEP = 10.0;
const float THERMOCLINE_SCALE = 24.0;

// Sea thermal profile — MUST match MaterialHeat3D.sea_water_target(): warm skin near the surface decaying
// with depth toward the cold deep floor (thermocline). On the sphere `wy` is the cell RADIUS and `sea` the
// sea-surface RADIUS, so `depth = max(0, sea - radius)` is the radial depth below the surface — the exact
// analog of the box's height-below-sea-level. The math is unchanged.
float sea_water_target(float wy, float sea) {
	float depth = max(0.0, sea - wy);
	return WATER_TEMP_DEEP + (SST_SURFACE - WATER_TEMP_DEEP) * exp(-depth / THERMOCLINE_SCALE);
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	// The CPU oracle tests `water > 0.05` in FLOAT64 (GDScript widens the float32 cell to double). In
	// float32 the smallest value that widens to > 0.05 is exactly 0.05f itself, so `>= 0.05` in float32 is
	// provably identical to the oracle's float64 `> 0.05` for EVERY float32 input — this restores parity
	// at the knife-edge cell where post-flow water lands on exactly 0.05.
	if (solid[idx] == 0.0 && water[idx] >= 0.05) {
		float radius = length(cell_pos[idx].xyz);
		float wt = sea_water_target(radius, params.sea_radius);
		temp[idx] += WATER_COOL_RATE * (wt - temp[idx]) * clamp(water[idx], 0.0, 1.0);
	}
}
