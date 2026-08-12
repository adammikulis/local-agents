#[compute]
#version 450

#include "neighbours.glsli"

// Gravity-driven mass redistribution over the neighbour table, for any flowing material.
// Replaces water_sphere3d, lava_flow_sphere3d and slump_sphere3d, which were one kernel three times.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer MassIn { float mass_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer MassOut { float mass_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 5, std430) restrict buffer Temp { float temp[]; };            // in place
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };    // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkArc { float larc[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // 0 = outflow, 1 = inflow/apply
	uint depth;           // radial shells per column
	float max_flow;
	float min_flow;
	float min_mass;
	float lateral_frac;
	float repose_tan;     // 0 = level out freely
} params;

#include "shell.glsli"

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
		int ib = nbr[base + N_IN];
		if (ib >= 0 && solid[ib] == 0.0) {
			float flow = stable_below(remaining + mass_in[ib]) - mass_in[ib];
			flow = clamp(flow, 0.0, min(params.max_flow, remaining));
			if (flow > params.min_flow) {
				send[base + N_IN] = flow;
				remaining -= flow;
			}
		}
		if (remaining < params.min_mass) {
			return;
		}

		// LATERAL — slots 2..5 (LASphereGrid N_A0..N_B1). `larc` is indexed by the same lateral index,
		// `link_arc[column*4 + l]` for N_LAT0 + l, because the table is filled as
		uint column = gidx / max(params.depth, 1u);
		uint layer = gidx % max(params.depth, 1u);
		float radius = shell_mid(layer);
		for (int d = 0; d < 4; d++) {
			if (remaining < params.min_mass) {
				break;
			}
			int inb = nbr[base + N_A0 + uint(d)];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			float diff = remaining - mass_in[inb];
			// The repose gate: only the mass ABOVE the slope the material can hold moves. `run` is the real
			// arc distance to that neighbour, so the threshold is an angle rather than a mass difference.
			float movable = diff;
			if (params.repose_tan > 0.0) {
				float run = larc[column * 4u + uint(d)] * radius;
				float thresh = params.repose_tan * run / max(shell_dr(layer), 1e-6);
				movable = diff - thresh;
			}
			if (movable > params.min_flow) {
				float lflow = clamp(movable * params.lateral_frac, 0.0, min(params.max_flow, remaining));
				if (lflow > params.min_flow) {
					send[base + N_A0 + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// UP, only when over-full.
		if (remaining > MAX_MASS) {
			int iu = nbr[base + N_OUT];
			if (iu >= 0 && solid[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + mass_in[iu]);
				uflow = clamp(uflow, 0.0, min(params.max_flow, remaining));
				if (uflow > params.min_flow) {
					send[base + N_OUT] = uflow;
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
		// The slot that answers this link, resolved by LASphereGrid rather than computed here.
		int pi = partner[base + d];
		if (pi < 0) { continue; }
		float f = send[uint(pi)];
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
