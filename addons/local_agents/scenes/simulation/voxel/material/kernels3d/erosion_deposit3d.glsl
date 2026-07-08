#[compute]
#version 450

// GPU 3D hydraulic-erosion DEPOSIT/SETTLE — the per-cell CORE of MaterialErosion3D._erode_and_deposit()
// MINUS the rock CARVE (the SDF carve_sphere edits stay a capped CPU tail, exactly like lava's melt/solidify
// SDF stamps). Per non-solid cell: estimate the water flow SPEED from the local water-surface gradient, form
// the carrying capacity cap = K_CAP*speed*water, then DROP the over-capacity suspended load into the shared
// sediment channel (for slump to pile into deltas/beaches), plus a gravity SETTLE of silt in shallow/slack
// water, plus the receding-flood drop where the cell has gone dry. Reads its own cell only (writes susp +
// sediment in place, no neighbour writes → race-free). Constants copied EXACTLY from MaterialErosion3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Susp { float susp[]; };          // suspended sediment (in place)
layout(set = 0, binding = 1, std430) restrict buffer Sediment { float sediment[]; };  // loose sediment channel (+= deposits)
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialErosion3D.gd exactly.
const float WATER_MIN = 0.05;
const float SPEED_MIN = 0.12;
const float SPEED_MAX = 1.5;
const float K_CAP = 0.9;
const float DEPOSIT_RATE = 0.35;
const float SETTLE_RATE = 0.06;
const float SETTLE_WATER_MAX = 0.6;
const float SUSP_MIN = 0.0005;

// Water flow "speed" at a cell: the largest water-surface height drop to a lower open lateral neighbour
// (the local surface gradient — fast on a steep slope, slack on a flat pool). Clamped to SPEED_MAX.
float surface_speed(int idx, int ix, int iz, int dim_x, int dim_z) {
	float here = water[idx];
	float drop = 0.0;
	if (ix > 0)        { int n = idx - 1;     if (solid[n] == 0.0) drop = max(drop, here - water[n]); }
	if (ix < dim_x - 1){ int n = idx + 1;     if (solid[n] == 0.0) drop = max(drop, here - water[n]); }
	if (iz > 0)        { int n = idx - dim_x; if (solid[n] == 0.0) drop = max(drop, here - water[n]); }
	if (iz < dim_z - 1){ int n = idx + dim_x; if (solid[n] == 0.0) drop = max(drop, here - water[n]); }
	return clamp(drop, 0.0, SPEED_MAX);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		return;
	}
	int dim_x = int(params.dim_x);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;
	int rem = idx - iy * layer;
	int iz = rem / dim_x;
	int ix = rem - iz * dim_x;

	float w = water[g];
	float s = susp[g];
	if (w < WATER_MIN) {
		// No water: any stranded silt drops (a receding flood leaves its load behind).
		if (s > SUSP_MIN) {
			sediment[g] += s;
			susp[g] = 0.0;
		}
		return;
	}

	float speed = surface_speed(idx, ix, iz, dim_x, dim_z);
	float cap = K_CAP * speed * w;
	if (cap <= s) {
		// OVER capacity — the water slowed, so it DROPS the excess load for slump to pile.
		float excess = (s - cap) * DEPOSIT_RATE;
		if (excess > 0.0) {
			s -= excess;
			sediment[g] += excess;
		}
	}
	// NOTE: cap > s (UNDER capacity) is the rock CARVE branch — a budgeted SDF carve_sphere — which stays on
	// the CPU tail (MaterialErosion3D.step_scene_only). The GPU never edits the terrain SDF / solid mask.

	// GRAVITY SETTLE — in shallow / near-still water suspended silt falls out regardless of capacity.
	if (s > SUSP_MIN && (w < SETTLE_WATER_MAX || speed < SPEED_MIN)) {
		float drop = s * SETTLE_RATE;
		s -= drop;
		sediment[g] += drop;
	}
	susp[g] = s;
}
