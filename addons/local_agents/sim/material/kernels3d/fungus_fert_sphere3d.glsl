#[compute]
#version 450

// CUBED-SPHERE FUNGUS FERTILITY — per-radial-column reduce. Sphere port of fungus_fert3d.glsl. The box kernel
// dispatched one invocation per XZ COLUMN and summed the per-cell fertility fungus3d produced this step
// (fert_cell = FERT_PER_DECOMPOSE * consumed) down the WHOLE straight column, adding the total into the scent
// soil-fertility field at that column — closing the rot->soil->plant loop on-device. On the sphere a "column"
// is a RADIAL line, so we dispatch PER CELL (like heat_sphere3d, `if (idx >= cell_count) return;`), let each
// SURFACE cell own its radial line, walk the line INWARD via nbr slot 0 summing fert_cell, and deposit the total
// into fert at that surface cell. The reduce/deposit math is copied VERBATIM.
//
// SURFACE cell on the sphere: the representative for a radial column is the OUTERMOST open cell — OPEN
// (solid == 0) whose OUTWARD-radial neighbour (nbr slot 5) is -1 (space boundary) or solid. That is the local
// landing-set form of "walk slot 5 outward until -1 or rock". From it we walk INWARD (slot 0) to the sphere
// centre (until slot 0 == -1), summing fert_cell of every cell on the line (solid cells contribute the 0 that
// fungus3d wrote for them), which reproduces the box's whole-column sum. fert is keyed PER CELL (fert[idx],
// sized cell_count) at the surface cell — the sphere replacement for the box's per-column fert slot. Each
// surface cell writes only its own fert[idx] → race-free (distinct radial lines own distinct surface cells).
// Runs AFTER the scent fertility blur/leach pass, in place on its output. Constants copied EXACTLY from
// MaterialFungus3D.gd (FERT_PER_DECOMPOSE is already folded into fert_cell upstream).

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
	// SURFACE = outermost open cell (its outward-radial neighbour is space or rock) — one per radial line.
	int up = nbr[idx * 6u + 5u];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;
	}
	// Reduce the RADIAL column: walk inward (slot 0) from the surface to the centre, summing fert_cell.
	float sum = fert_cell[idx];
	int j = nbr[idx * 6u + 0u];
	// Guard the walk against a malformed table with a cell_count cap (a radial line cannot exceed the grid).
	for (uint step = 0u; step < params.cell_count; step++) {
		if (j < 0) {
			break;
		}
		sum += fert_cell[uint(j)];
		j = nbr[uint(j) * 6u + 0u];
	}
	fert[idx] += sum;
}
