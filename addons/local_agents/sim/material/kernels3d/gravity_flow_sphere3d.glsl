#[compute]
#version 450

// Gravity-driven mass redistribution over the neighbour table, for any flowing material.
// Replaces water_sphere3d, lava_flow_sphere3d and slump_sphere3d, which were one kernel three times.
//
// Two passes: pass 0 writes each cell's outflow into `send[idx*6 + dir]`, pass 1 gathers.
// Order: DOWN (slot 0) to the stable stack, then LATERAL level-out (slots 1-4), then UP (slot 5) if the
// cell is over MAX_MASS.
//
// Per-material, all push constants:
//   max_flow, min_flow, min_mass, lateral_frac  flow caps
//   repose_tan   0 = level out freely (water, lava); >0 = only the excess over the angle of repose moves,
//                which is what makes a granular pile stand at an angle instead of flowing flat
//
// Moving mass carries its enthalpy. Not optional: a transfer that moves matter without its heat is an
// unbooked energy term.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer MassIn { float mass_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer MassOut { float mass_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 5, std430) restrict buffer Temp { float temp[]; };            // in place
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };    // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkArc { float larc[]; };  // column*4 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // 0 = outflow, 1 = inflow/apply
	uint depth;           // radial shells per column
	float core_radius;    // shell floor; cell radius = core_radius + (layer + 0.5) * cell_size
	float cell_size;      // radial thickness, and the RISE one unit of mass represents
	float max_flow;
	float min_flow;
	float min_mass;
	float lateral_frac;
	float repose_tan;     // 0 = level out freely
} params;

const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;

// Stable amount for the LOWER of two radially-stacked cells.
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
		for (uint d = 0u; d < 6u; ++d) {
			send[base + d] = 0.0;
		}
		if (solid[gidx] != 0.0) {
			return;
		}
		float remaining = mass_in[gidx];
		if (remaining < params.min_mass) {
			return;
		}

		// DOWN
		int ib = nbr[base + 0u];
		if (ib >= 0 && solid[ib] == 0.0) {
			float flow = stable_below(remaining + mass_in[ib]) - mass_in[ib];
			flow = clamp(flow, 0.0, min(params.max_flow, remaining));
			if (flow > params.min_flow) {
				send[base + 0u] = flow;
				remaining -= flow;
			}
		}
		if (remaining < params.min_mass) {
			return;
		}

		// LATERAL
		uint column = gidx / max(params.depth, 1u);
		uint layer = gidx % max(params.depth, 1u);
		float radius = params.core_radius + (float(layer) + 0.5) * params.cell_size;
		for (int d = 0; d < 4; d++) {
			if (remaining < params.min_mass) {
				break;
			}
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			float diff = remaining - mass_in[inb];
			// The repose gate: only the mass ABOVE the slope the material can hold moves. `run` is the real
			// arc distance to that neighbour, so the threshold is an angle rather than a mass difference.
			float movable = diff;
			if (params.repose_tan > 0.0) {
				float run = larc[column * 4u + uint(d)] * radius;
				float thresh = params.repose_tan * run / max(params.cell_size, 1e-6);
				movable = diff - thresh;
			}
			if (movable > params.min_flow) {
				float lflow = clamp(movable * params.lateral_frac, 0.0, min(params.max_flow, remaining));
				if (lflow > params.min_flow) {
					send[base + 1u + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// UP, only when over-full
		if (remaining > MAX_MASS) {
			int iu = nbr[base + 5u];
			if (iu >= 0 && solid[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + mass_in[iu]);
				uflow = clamp(uflow, 0.0, min(params.max_flow, remaining));
				if (uflow > params.min_flow) {
					send[base + 5u] = uflow;
					remaining -= uflow;
				}
			}
		}
		return;
	}

	// pass 1 — gather
	if (solid[gidx] != 0.0) {
		mass_out[gidx] = mass_in[gidx];
		return;
	}

	float own_out = 0.0;
	for (uint d = 0u; d < 6u; ++d) {
		own_out += send[base + d];
	}

	float inflow = 0.0;
	float inflow_heat = 0.0;
	for (uint d = 0u; d < 6u; ++d) {
		int m = nbr[base + d];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		// The neighbour's send slot aimed back at us. The table is RECIPROCAL IN THE OPPOSITE SLOT `d ^ 1`
		// for all three pairs — LASphereGrid slots: 0/1 radial in/out, 2/3 lateral A, 4/5 lateral B.
		uint rev = d ^ 1u;
		float f = send[uint(m) * 6u + rev];
		if (f > 0.0) {
			inflow += f;
			inflow_heat += f * temp[m];
		}
	}

	float kept = mass_in[gidx] - own_out;
	float total = kept + inflow;
	mass_out[gidx] = total;

	// Mass-weighted enthalpy mix. A cell that receives nothing keeps its temperature exactly.
	if (inflow > 0.0 && total > 0.0) {
		temp[gidx] = (kept * temp[gidx] + inflow_heat) / total;
	}
}
