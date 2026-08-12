#[compute]
#version 450

#include "neighbours.glsli"

layout(local_size_x = 64) in;

// susp_in is also bound as a carrier below, so it may not be `restrict`.
layout(set = 0, binding = 0, std430) readonly buffer SuspIn { float susp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer SuspOut { float susp_out[]; };
layout(set = 0, binding = 2, std430) readonly buffer FlowHead { float flow_w[]; };   // pre-step water head
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict buffer SendH { float send_h[]; };      // idx*6 + dir, J per m3 of DONOR volume
layout(set = 0, binding = 5, std430) restrict buffer Send { float send[]; };         // idx*6 + dir (shared scratch)
layout(set = 0, binding = 6, std430) restrict buffer Temp { float temp[]; };         // in place
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; }; // idx*6 + slot
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
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint enabled;   // 0 = advection off; pass 0 sends nothing and pass 1 is an exact carry
	uint pad0;
} params;

#include "cellvol.glsli"
#include "rc_shared.glsli"

// Cell heat capacity gained per unit fill of arriving suspended mineral, J/m3K: its own capacity less the
// air it displaces, since rc_of() fills the unoccupied fraction with air.
const float SUSP_RC_GAIN = RC_ROCK - RC_AIR;

const float MAX_MASS      = 1.0;
const float LATERAL_SHARE = 0.5;
const float WATER_MIN     = 0.02;    // below this a cell has no flow to ride
const float MIN_SUSP      = 1.0e-6;
const float MAX_OUT_FRAC  = 0.9;     // cap on the share of a cell's load that leaves in one step

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 0u) {
		for (uint z = 0u; z < N_SLOTS; ++z) { send[base + z] = 0.0; send_h[base + z] = 0.0; }

		if (params.enabled == 0u || solid[gidx] != 0.0) {
			return;
		}
		float load = susp_in[gidx];
		if (load < MIN_SUSP) {
			return;
		}
		float w = flow_w[gidx];
		if (w <= WATER_MIN) {
			return;
		}

		float raw[5];
		float total = 0.0;

		// DOWN: the cell below can take what its own headroom allows, converted into MY fill units.
		int ib = nbr[base + N_IN];
		raw[0] = 0.0;
		if (ib >= 0 && solid[ib] == 0.0) {
			raw[0] = min(w, max(0.0, MAX_MASS - flow_w[uint(ib)]) * vol_ratio(uint(ib), gidx));
		}
		total += raw[0];

		// LATERAL: a head difference between two cells of the same shell, so it is already in my units.
		for (int d = 0; d < 4; d++) {
			raw[d + 1] = 0.0;
			int inb = nbr[base + N_LAT0 + uint(d)];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			float head = w - flow_w[uint(inb)];
			if (head > 0.0) {
				raw[d + 1] = head * LATERAL_SHARE;
				total += raw[d + 1];
			}
		}
		if (total <= 0.0) {
			return;
		}

		// Fraction of the LOAD that leaves = fraction of the WATER that leaves, capped for stability.
		float out_frac = min(total / w, MAX_OUT_FRAC);
		float scale = out_frac / total;
		float flow = load * raw[0] * scale;
		send[base + N_IN] = flow;
		// Written beside its own send, never in a later loop: an early return between the two drops the
		// heat while the mass still moves.
		send_h[base + N_IN] = flow * SUSP_RC_GAIN * temp[gidx];
		for (uint l = 0u; l < N_LATERAL_COUNT; ++l) {
			float lflow = load * raw[l + 1u] * scale;
			send[base + N_LAT0 + l] = lflow;
			send_h[base + N_LAT0 + l] = lflow * SUSP_RC_GAIN * temp[gidx];
		}
		return;
	}

	// pass 1 — gather
	if (solid[gidx] != 0.0) {
		susp_out[gidx] = susp_in[gidx];
		return;
	}

	// Capacity of everything already in this cell, before this step's load moved.
	float rc_here = rc_of(gidx);
	float own_out = 0.0;
	for (uint z = 0u; z < N_SLOTS; ++z) { own_out += send[base + z]; }

	float inflow = 0.0;
	float gain_h = 0.0;                    // arriving enthalpy, J per m3 of THIS cell's volume
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int pi = partner[base + d];
		int nb = nbr[base + d];
		if (pi < 0 || nb < 0) { continue; }
		// The donor's fill fraction is over ITS cell volume; carry the same matter into mine.
		float vr = vol_ratio(uint(nb), gidx);
		inflow += send[uint(pi)] * vr;
		gain_h += send_h[uint(pi)] * vr;
	}

	susp_out[gidx] = susp_in[gidx] - own_out + inflow;

	// The load that left carried its enthalpy out and the load that arrived brought its own in. Weights are
	// heat capacities, not masses: the rest of the cell holds heat too. A cell that receives nothing keeps
	// its temperature exactly.
	float kept_c = rc_here - own_out * SUSP_RC_GAIN;
	float gain_c = inflow * SUSP_RC_GAIN;
	float denom = kept_c + gain_c;
	if (gain_c > 0.0 && denom > 0.0) {
		temp[gidx] = (kept_c * temp[gidx] + gain_h) / denom;
	}
}
