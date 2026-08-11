#[compute]
#version 450

// One thread per radial-line SEGMENT: its owner is the open cell whose outward neighbour (slot 5) is -1 or
// solid. The owner walks inward (slot 0) until the next owner, summing fert_cell, and deposits the total on
// the segment's lowest open cell. Every cell of a line belongs to exactly one segment, so nothing is summed
// twice and nothing is dropped.

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
	int up = nbr[idx * 6u + 5u];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;
	}
	// Walk inward (slot 0) summing fert_cell, remembering GROUND — the first open cell with rock beneath it.
	float sum = fert_cell[idx];
	int ground = (nbr[idx * 6u + 0u] >= 0 && solid[nbr[idx * 6u + 0u]] != 0.0) ? int(idx) : -1;
	int prev = int(idx);
	int j = nbr[idx * 6u + 0u];
	// Guard the walk against a malformed table with a cell_count cap (a radial line cannot exceed the grid).
	for (uint step = 0u; step < params.cell_count; step++) {
		if (j < 0) {
			break;
		}
		// j is open with rock outward, so j is the next segment's owner: it and everything inward are its.
		if (solid[uint(j)] == 0.0 && solid[uint(prev)] != 0.0) {
			break;
		}
		sum += fert_cell[uint(j)];
		int below = nbr[uint(j) * 6u + 0u];
		if (ground < 0 && solid[j] == 0.0 && below >= 0 && solid[below] != 0.0) {
			ground = j;                    // lowest open cell of this segment
		}
		prev = j;
		j = below;
	}
	int target = (ground >= 0) ? ground : int(idx);
	fert[uint(target)] += sum;
}
