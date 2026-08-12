#[compute]
#version 450

#include "neighbours.glsli"
#include "cellvol.glsli"

// SURFACE cell own its radial line, walk the line INWARD via the radial neighbour summing fert_cell, and deposit the total
// (solid == 0) whose OUTWARD-radial neighbour is -1 (space boundary) or solid. That is the local

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertCell { float fert_cell[]; };
layout(set = 0, binding = 1, std430) restrict buffer Fert { float fert[]; };            // per-cell (cell_count)
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };    // idx*6 + slot

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
	if (solid[idx] != 0.0) {
		return;
	}
	// The radial line is OWNED by its outermost open cell (outward-radial neighbour is space or rock), which is
	// the unique, race-free representative for the whole line — one owner per line, exactly as before.
	int up = nbr[idx * N_SLOTS + N_OUT];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;
	}
	// Reduce the RADIAL column: walk inward from the owner to the centre, summing fert_cell — and on
	// the way down remember the GROUND, the first open cell that has rock directly beneath it.
	float sum = fert_cell[idx];
	int ground = (nbr[idx * N_SLOTS + N_IN] >= 0 && solid[nbr[idx * N_SLOTS + N_IN]] != 0.0) ? int(idx) : -1;
	int j = nbr[idx * N_SLOTS + N_IN];
	// Guard the walk against a malformed table with a cell_count cap (a radial line cannot exceed the grid).
	for (uint step = 0u; step < params.cell_count; step++) {
		if (j < 0) {
			break;
		}
		sum += fert_cell[uint(j)] * vol_ratio(uint(j), idx);
		int below = nbr[uint(j) * N_SLOTS + N_IN];
		if (ground < 0 && solid[j] == 0.0 && below >= 0 && solid[below] != 0.0) {
			ground = j;                    // topmost ground-hugging open cell on this line
		}
		j = below;
	}
	int target = (ground >= 0) ? ground : int(idx);
	fert[uint(target)] += sum * vol_ratio(idx, uint(target));
}
