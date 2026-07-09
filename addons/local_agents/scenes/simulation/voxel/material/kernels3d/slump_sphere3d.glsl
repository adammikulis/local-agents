#[compute]
#version 450

// CUBED-SPHERE granular SLUMP — the sphere port of slump3d.glsl. IDENTICAL two-pass GATHER logic and
// IDENTICAL repose-gated flow math (gravity DOWN, a LATERAL level-out gated by the angle of repose so only
// the mass EXCESS over REPOSE_TAN creeps to a lower neighbour, then UP under pressure). NO carry-heat
// (sediment is cold). The ONLY change vs the box kernel is neighbour addressing: instead of idx±offset +
// `if(iy>0)` bounds tests, every cell gathers its 6 neighbours from the precomputed INDEX TABLE
// `nbr[idx*6 + d]` (slot 0 = inward/radial-DOWN = gravity, 1-4 = LATERAL, 5 = outward/radial-UP;
// -1 = boundary → skipped). Constants copied EXACTLY from MaterialSlump3D.gd / MaterialField3D.gd.
//
// SEND slot = idx*6 + dir. Direct map box dir d → table slot d:
//   dir 0 = DOWN (radially inward) = nbr slot 0; dir 1-4 = LATERAL = nbr slots 1-4; dir 5 = UP (radially
//   outward) = nbr slot 5. PASS-1 opposite-slot pairing: (0 <-> 5) radial, (1 <-> 2), (3 <-> 4).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SedIn { float sed_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict writeonly buffer SedOut { float sed_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };    // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint pad0;
	uint pad1;
} params;

// Constants — MUST match MaterialSlump3D.gd / MaterialField3D.gd exactly.
const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;
const float SLUMP_MAX_FLOW = 0.5;
const float SLUMP_MIN_MASS = 0.0001;
const float SLUMP_MIN_FLOW = 0.01;
const float SLUMP_LATERAL_FRACTION = 0.25;
const float REPOSE_TAN = 0.70;

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
			float diff = remaining - sed_in[inb];
			if (diff > REPOSE_TAN) {
				float excess = diff - REPOSE_TAN;
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
