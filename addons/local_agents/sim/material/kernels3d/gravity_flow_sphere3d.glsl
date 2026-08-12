#[compute]
#version 450

#include "neighbours.glsli"

// Gravity-driven mass redistribution over the neighbour table, for any flowing material.
// Replaces water_sphere3d, lava_flow_sphere3d and slump_sphere3d, which were one kernel three times.

layout(local_size_x = 64) in;

// mass_in is one of the carriers below, so it is bound twice and may not be `restrict`.
layout(set = 0, binding = 0, std430) readonly buffer MassIn { float mass_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer MassOut { float mass_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict buffer SendH { float send_h[]; };         // idx*6 + dir, J per m3 of DONOR volume
layout(set = 0, binding = 5, std430) restrict buffer Temp { float temp[]; };            // in place
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };    // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkArc { float larc[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };
// Carriers this kernel does not use itself, bound because rc_shared.glsli needs every one of them.
layout(set = 0, binding = 7, std430) readonly buffer Water { float water[]; };
layout(set = 0, binding = 18, std430) readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 19, std430) readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 20, std430) readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 30, std430) readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) readonly buffer Porosity { float porosity[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // 0 = outflow, 1 = inflow/apply
	uint depth;           // radial shells per column
	float max_flow;
	float min_flow;
	float min_mass;
	float lateral_frac;
	float repose_tan;     // 0 = level out freely
	float rc_gain;        // cell heat capacity gained per unit fill of THIS material, J/m3K (LAHeatCapacity)
} params;

#include "shell.glsli"
#include "cellvol.glsli"
#include "rc_shared.glsli"

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
			send_h[base + d] = 0.0;
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
			// The stack rule is about how full the LOWER cell gets, so it is evaluated in the lower cell's
			// fill units and the answer converted back into mine.
			float mine_there = remaining * vol_ratio(gidx, uint(ib));
			float flow = (stable_below(mine_there + mass_in[ib]) - mass_in[ib]) * vol_ratio(uint(ib), gidx);
			flow = clamp(flow, 0.0, min(params.max_flow, remaining));
			if (flow > params.min_flow) {
				send[base + N_IN] = flow;
				send_h[base + N_IN] = flow * params.rc_gain * temp[gidx];
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
					send_h[base + N_A0 + uint(d)] = lflow * params.rc_gain * temp[gidx];
					remaining -= lflow;
				}
			}
		}

		// UP, only when over-full.
		if (remaining > MAX_MASS) {
			int iu = nbr[base + N_OUT];
			if (iu >= 0 && solid[iu] == 0.0) {
				// This cell is the lower of the pair, so the rule runs in MY fill units and the cell above
				// converts into them.
				float theirs_here = mass_in[iu] * vol_ratio(uint(iu), gidx);
				float uflow = remaining - stable_below(remaining + theirs_here);
				uflow = clamp(uflow, 0.0, min(params.max_flow, remaining));
				if (uflow > params.min_flow) {
					send[base + N_OUT] = uflow;
					send_h[base + N_OUT] = uflow * params.rc_gain * temp[gidx];
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

	// Capacity of everything already in this cell, before this step's material moved.
	float rc_here = rc_of(gidx);
	float inflow = 0.0;
	float gain_h = 0.0;                    // arriving enthalpy, J per m3 of THIS cell's volume
	for (uint d = 0u; d < 6u; ++d) {
		int m = nbr[base + d];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		// The slot that answers this link, resolved by LASphereGrid rather than computed here.
		int pi = partner[base + d];
		if (pi < 0) { continue; }
		// The donor's fill fraction is over ITS cell volume; carry the same matter into mine.
		float vr = vol_ratio(uint(m), gidx);
		inflow += send[uint(pi)] * vr;
		gain_h += send_h[uint(pi)] * vr;
	}

	mass_out[gidx] = mass_in[gidx] - own_out + inflow;

	// The matter that left carried its enthalpy out and the matter that arrived brought its own in. Weights
	// are heat capacities, not masses: the rest of the cell holds heat too, and a mass-weighted mix ignores
	// it. A cell that receives nothing keeps its temperature exactly.
	float kept_c = rc_here - own_out * params.rc_gain;
	float gain_c = inflow * params.rc_gain;
	float denom = kept_c + gain_c;
	if (gain_c > 0.0 && denom > 0.0) {
		temp[gidx] = (kept_c * temp[gidx] + gain_h) / denom;
	}
}
