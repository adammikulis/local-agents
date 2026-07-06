#[compute]
#version 450

// GPU 3D heat EVAPORATIVE-COOLING pass — port of MaterialHeat3D.step() PART 4. Runs LAST in the heat
// chain, IN PLACE on the temp buffer, reading the POST-FLOW water (a wet cell sheds heat toward
// WATER_TEMP so rivers/sea act as a heat sink + firebreak). Purely per-cell independent, so one
// invocation per grid cell. Lava is deliberately NOT cooled here (the lava module sustains its heat).
// Constants copied EXACTLY from MaterialHeat3D.gd — do not diverge.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float WATER_COOL_RATE = 0.12;
const float WATER_TEMP = 12.0;

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
		temp[idx] += WATER_COOL_RATE * (WATER_TEMP - temp[idx]) * clamp(water[idx], 0.0, 1.0);
	}
}
