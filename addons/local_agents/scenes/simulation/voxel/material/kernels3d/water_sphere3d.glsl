#[compute]
#version 450

// CUBED-SPHERE water CA — the sphere port of water3d.glsl. IDENTICAL two-pass GATHER logic (pass 0 outflow
// records per-direction sends on the OLD water snapshot; pass 1 inflow = old - sent + received), IDENTICAL
// constants and flow/gravity math. The ONLY change is neighbour addressing: instead of idx±offset + `if(iy>0)`
// bounds tests, every cell gathers its 6 neighbours from the precomputed INDEX TABLE `nbr[idx*6 + d]`
// (slot 0 = inward/radial-DOWN = gravity, 1-4 = LATERAL, 5 = outward/radial-UP; -1 = boundary → skipped).
// Static cells remain INFINITE SINKS exactly as the box kernel. Constants copied EXACTLY from
// MaterialField3D.gd — do not diverge.
//
// SEND slot = idx*6 + dir. Direct map box dir d → table slot d:
//   dir 0 = DOWN  (radially inward)  = nbr slot 0
//   dir 1 = -x, dir 2 = +x, dir 3 = -z, dir 4 = +z  (LATERAL)  = nbr slots 1-4
//   dir 5 = UP    (radially outward) = nbr slot 5
// PASS-1 opposite-slot pairing (a neighbour reached via my slot s sent into me on its slot opposite(s)):
//   (0 <-> 5) radial, (1 <-> 2), (3 <-> 4)  — matches the box kernel's exact inflow mapping.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer WaterIn { float water_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };          // idx*6 + dir
layout(set = 0, binding = 4, std430) restrict writeonly buffer WaterOut { float water_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint pad0;
	uint pad1;
} params;

// Constants — MUST match MaterialField3D.gd exactly.
const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;
const float MIN_MASS = 0.0001;
const float MAX_FLOW = 1.0;
const float MIN_FLOW = 0.01;
const float LATERAL_FRACTION = 0.5;

// Stable amount for the LOWER of two radially-stacked water cells given their combined mass.
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

		// Skip rock and calm STATIC sea — only dynamic water is a source.
		if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
			return;
		}
		float remaining = water_in[gidx];
		if (remaining < MIN_MASS) {
			return;
		}

		// 1) DOWN (radially inward) — gravity. Move toward the stable split with the cell below (drain into sea).
		int ib = nbr[base + 0u];
		if (ib >= 0) {
			if (solid[ib] == 0.0) {
				if (static_cells[ib] != 0.0) {
					// The sea below is an infinite sink: water pours in and is absorbed.
					send[base + 0u] = remaining;
					remaining = 0.0;
				} else {
					float flow = stable_below(remaining + water_in[ib]) - water_in[ib];
					flow = clamp(flow, 0.0, min(MAX_FLOW, remaining));
					if (flow > MIN_FLOW) {
						send[base + 0u] = flow;
						remaining -= flow;
					}
				}
			}
		}
		if (remaining < MIN_MASS) {
			return;
		}

		// 2) LATERAL — level out with the 4 lateral neighbours (slots 1-4; only push to lower).
		for (int d = 0; d < 4; d++) {
			if (remaining < MIN_MASS) {
				break;
			}
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0) {
				continue;
			}
			if (solid[inb] != 0.0) {
				continue;
			}
			if (static_cells[inb] != 0.0) {
				// Reached the sea sideways (a river mouth) — absorb a share and move on.
				float drain = clamp(remaining * LATERAL_FRACTION, 0.0, remaining);
				send[base + 1u + uint(d)] = drain;
				remaining -= drain;
				continue;
			}
			float diff = remaining - water_in[inb];
			if (diff > MIN_FLOW) {
				float lflow = clamp(diff * LATERAL_FRACTION, 0.0, min(MAX_FLOW, remaining));
				if (lflow > MIN_FLOW) {
					send[base + 1u + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// 3) UP (radially outward) — only overflow (compressed above MAX_MASS) pushes into the cell above.
		if (remaining > MAX_MASS) {
			int iu = nbr[base + 5u];
			if (iu >= 0 && solid[iu] == 0.0 && static_cells[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + water_in[iu]);
				uflow = clamp(uflow, 0.0, min(MAX_FLOW, remaining));
				if (uflow > MIN_FLOW) {
					send[base + 5u] = uflow;
					remaining -= uflow;
				}
			}
		}
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	// Rock holds no fluid; calm STATIC sea is held at rest and absorbs (never stepped) — pass through so
	// water aimed at a static/solid cell simply vanishes (drains into the sea), matching the CPU.
	if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
		water_out[gidx] = water_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	int nb;
	nb = nbr[base + 0u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 5u]; }  // down-neighbour sent UP (5)
	nb = nbr[base + 5u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 0u]; }  // up-neighbour sent DOWN (0)
	nb = nbr[base + 1u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 2u]; }  // -x neighbour sent +x (2)
	nb = nbr[base + 2u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 1u]; }  // +x neighbour sent -x (1)
	nb = nbr[base + 3u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 4u]; }  // -z neighbour sent +z (4)
	nb = nbr[base + 4u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 3u]; }  // +z neighbour sent -z (3)

	water_out[gidx] = water_in[gidx] - own_out + inflow;
}
