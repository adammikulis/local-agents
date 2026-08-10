#[compute]
#version 450

// `nbr[idx*6 + d]` (slot 0 = inward/radial-DOWN = gravity, 1-4 = LATERAL, 5 = outward/radial-UP;
//   dir 0 = DOWN (radially inward) = nbr slot 0; dir 1-4 = LATERAL = nbr slots 1-4; dir 5 = UP (radially
//   outward) = nbr slot 5. PASS-1 opposite-slot pairing: (0 <-> 5) radial, (1 <-> 2), (3 <-> 4).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SedIn { float sed_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict writeonly buffer SedOut { float sed_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };
// ANGULAR separation to each lateral neighbour, radians, per SURFACE column (LASphereGrid.link_arc). Times a
// cell's radius it is the arc between the two cell centres — the lateral RUN of that link.
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkArc { float larc[]; };    // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = outflow, 1 = inflow/apply
	uint depth;        // radial shells per column — turns a cell index into its column and its layer
	float core_radius; // shell floor; a cell's radius is core_radius + (layer + 0.5) * cell_size
	float cell_size;   // radial thickness of a cell, and the RISE a unit of mass represents
	float pad0;
	float pad1;
	float pad2;
} params;

// --- THE SUBSTRATE'S CELL-FILL UNITS — authority LAMaterialField3D (that file exists; these two are checked
// against MaterialField3D.gd:26-27 by reading, not by a gate).
const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;

// --- MODEL PARAMETERS of this kernel's explicit integrator. Properties of THIS solver, not of sediment: a
const float SLUMP_MAX_FLOW = 0.5;
const float SLUMP_MIN_MASS = 0.0001;
const float SLUMP_MIN_FLOW = 0.01;
const float SLUMP_LATERAL_FRACTION = 0.25;

// --- THE ANGLE OF REPOSE — a measured property of dry granular matter, and the only physical constant in this
const float REPOSE_TAN = 0.70;   // LAPhysical.REPOSE_TAN_DRY_GRANULAR

// Stable amount for the LOWER of two radially-stacked cells (identical to the water/lava CA _stable_below).
float stable_below(float total_mass) {
	if (total_mass <= MAX_MASS) {
		return total_mass;
	}
	if (total_mass < 2.0 * MAX_MASS + MAX_COMPRESS) {
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS);
	}
	return (total_mass + MAX_COMPRESS) * 0.5;
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;

		if (solid[gidx] != 0.0) {
			return;
		}
		float remaining = sed_in[gidx];
		if (remaining < SLUMP_MIN_MASS) {
			return;
		}

		// 1) DOWN (radially inward) — gravity into the (non-solid) cell below (debris piles bottom-up).
		int ib = nbr[base + 0u];
		if (ib >= 0 && solid[ib] == 0.0) {
			float dflow = stable_below(remaining + sed_in[ib]) - sed_in[ib];
			dflow = clamp(dflow, 0.0, min(SLUMP_MAX_FLOW, remaining));
			if (dflow > SLUMP_MIN_FLOW) {
				send[base + 0u] = dflow;
				remaining -= dflow;
			}
		}
		if (remaining < SLUMP_MIN_MASS) {
			return;
		}

		// 2) LATERAL — REPOSE-GATED level-out with the 4 lateral neighbours (slots 1-4; only push to a
		// lower one, and only the mass EXCESS over the repose threshold: diff - REPOSE_TAN).
		for (int d = 0; d < 4; d++) {
			if (remaining < SLUMP_MIN_MASS) {
				break;
			}
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0) {
				continue;
			}
			if (solid[inb] != 0.0) {
				continue;
			}
			// THE REPOSE THRESHOLD IS AN ANGLE, SO IT NEEDS THE RUN. A mass difference of 1.0 is a rise of
			// `cell_size`; the run is the arc to this neighbour, `angle * radius`. Comparing the difference
			// directly against a tangent (which is what this did) asserts run == cell_size, i.e. cubes.
			uint column = gidx / max(params.depth, 1u);
			uint layer = gidx - column * max(params.depth, 1u);
			float radius = params.core_radius + (float(layer) + 0.5) * params.cell_size;
			float run = larc[column * 4u + uint(d)] * radius;
			float thresh = REPOSE_TAN * run / max(params.cell_size, 1e-6);
			float diff = remaining - sed_in[inb];
			if (diff > thresh) {
				float excess = diff - thresh;
				float lflow = clamp(excess * SLUMP_LATERAL_FRACTION, 0.0, min(SLUMP_MAX_FLOW, remaining));
				if (lflow > SLUMP_MIN_FLOW) {
					send[base + 1u + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// 3) UP (radially outward) — only overflow (compressed above a full cell) presses into the cell above.
		if (remaining > MAX_MASS) {
			int iu = nbr[base + 5u];
			if (iu >= 0 && solid[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + sed_in[iu]);
				uflow = clamp(uflow, 0.0, min(SLUMP_MAX_FLOW, remaining));
				if (uflow > SLUMP_MIN_FLOW) {
					send[base + 5u] = uflow;
					remaining -= uflow;
				}
			}
		}
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	if (solid[gidx] != 0.0) {
		sed_out[gidx] = sed_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	int nb;
	nb = nbr[base + 0u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 5u]; }  // below sent UP (5)
	nb = nbr[base + 5u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 0u]; }  // above sent DOWN (0)
	nb = nbr[base + 1u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 2u]; }  // -x sent +x (2)
	nb = nbr[base + 2u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 1u]; }  // +x sent -x (1)
	nb = nbr[base + 3u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 4u]; }  // -z sent +z (4)
	nb = nbr[base + 4u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 3u]; }  // +z sent -z (3)

	sed_out[gidx] = sed_in[gidx] - own_out + inflow;
}
