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
// OWNER cell on the sphere: the representative for a radial column is the OUTERMOST open cell — OPEN
// (solid == 0) whose OUTWARD-radial neighbour (nbr slot 5) is -1 (space boundary) or solid. That is the local
// landing-set form of "walk slot 5 outward until -1 or rock". From it we walk INWARD (slot 0) to the sphere
// centre (until slot 0 == -1), summing fert_cell of every cell on the line (solid cells contribute the 0 that
// fungus3d wrote for them), which reproduces the box's whole-column sum. The DEPOSIT, however, lands on the
// GROUND cell of that line (the first open cell with rock directly beneath it), not on the owner — see the
// note at the write below for the measurement that forced the change. Each line writes exactly one cell that
// it uniquely owns → race-free (distinct radial lines own distinct ground cells).
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
	// The radial line is OWNED by its outermost open cell (outward-radial neighbour is space or rock), which is
	// the unique, race-free representative for the whole line — one owner per line, exactly as before.
	int up = nbr[idx * 6u + 5u];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;
	}
	// Reduce the RADIAL column: walk inward (slot 0) from the owner to the centre, summing fert_cell — and on
	// the way down remember the GROUND, the first open cell that has rock directly beneath it.
	float sum = fert_cell[idx];
	int ground = (nbr[idx * 6u + 0u] >= 0 && solid[nbr[idx * 6u + 0u]] != 0.0) ? int(idx) : -1;
	int j = nbr[idx * 6u + 0u];
	// Guard the walk against a malformed table with a cell_count cap (a radial line cannot exceed the grid).
	for (uint step = 0u; step < params.cell_count; step++) {
		if (j < 0) {
			break;
		}
		sum += fert_cell[uint(j)];
		int below = nbr[uint(j) * 6u + 0u];
		if (ground < 0 && solid[j] == 0.0 && below >= 0 && solid[below] != 0.0) {
			ground = j;                    // topmost ground-hugging open cell on this line
		}
		j = below;
	}
	// DEPOSIT ON THE GROUND, not at the top of the atmosphere. The old kernel wrote the column's whole
	// fertility into its own (sky-exposed, outermost) cell, which on a shell sits ~78 world-units ABOVE the
	// terrain. That put the entire soil-nutrient channel in the stratosphere: measured 2026-07-29, mean fert
	// over the 2156 land ground cells was exactly 0.0 while fertility_peak read 0.37. Photosynthesis was
	// gated to the same wrong surface, so the loop was self-consistently misplaced and nobody noticed. R19
	// now runs on the ground (GATE_NEAR_GROUND), roots reach into the rock below, and nutrient has to be
	// there to be taken up — so the reduce lands where the roots are. This also repairs `fertility_at(pos)`,
	// which reads the cell at a world point and therefore used to report ~0 anywhere a player actually looked.
	// Still one write per radial line to a cell that line uniquely owns → race-free as before.
	int target = (ground >= 0) ? ground : int(idx);
	fert[uint(target)] += sum;
}
