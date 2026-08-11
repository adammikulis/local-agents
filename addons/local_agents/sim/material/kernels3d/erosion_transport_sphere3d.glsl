#[compute]
#version 450

// Suspended load rides the water. Pass 0 writes outflow per slot; pass 1 gathers.
// Slot 5 (radially outward) carries nothing: suspended load does not climb.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SuspIn { float susp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer SuspOut { float susp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };          // PRE-step water (live half)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 5, std430) restrict buffer Send { float send[]; };                     // idx*6 + dir (shared scratch)
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot
layout(set = 0, binding = 17, std430) restrict readonly buffer SolidAngle { float solid_angle[]; };  // per column, sr

#include "cell_geom.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = outflow, 1 = inflow/apply
	uint depth;        // radial shells per column
	uint pad0;
	float core_radius; // shell floor, model units
	float cell_size;   // radial thickness of one layer, model units
} params;

// --- Tunables -------------------------------------------------------------------------------------------
const float MAX_MASS      = 1.0;
const float LATERAL_SHARE = 0.5;
const float WATER_MIN     = 0.02;    // below the wet-surface threshold there is no flow to ride (matches pickup)
const float MIN_SUSP      = 1.0e-6;  // don't bother moving a numerically empty load
const float MAX_OUT_FRAC  = 0.9;     // never empty a cell in one step (stability; the gather stays exact either way)

// A send is a fraction of the SENDER's own cell; the receiver is a different size.
float xfer(uint src, uint dst) {
	return cg_transfer(src, dst, params.depth, params.core_radius, params.cell_size);
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		// Self-zero all six slots before any early return, exactly like the other CAs, so the shared `send`
		// scratch needs no buffer_clear (illegal while a compute list is open).
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;

		// Rock carries nothing.
		if (solid[gidx] != 0.0) {
			return;
		}
		float load = susp_in[gidx];
		if (load < MIN_SUSP) {
			return;
		}
		float w = water[gidx];
		if (w <= WATER_MIN) {
			return;    // no water in this cell = nothing suspended in anything = nothing to carry
		}

		//   DOWN (slot 0)      — gravity moves as much as the cell below can still hold (:88), or EVERYTHING
		//   UP (slot 5)        — nothing: suspended load does not climb.
		float raw[5];
		float total = 0.0;

		int ib = nbr[base + 0u];
		raw[0] = 0.0;
		if (ib >= 0 && solid[ib] == 0.0) {
			raw[0] = min(w, max(0.0, MAX_MASS - water[uint(ib)]));
		}
		total += raw[0];

		for (int d = 0; d < 4; d++) {
			raw[d + 1] = 0.0;
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			float head = w - water[uint(inb)];
			if (head > 0.0) {
				raw[d + 1] = head * LATERAL_SHARE;
				total += raw[d + 1];
			}
		}
		if (total <= 0.0) {
			return;          // ponded / no downhill outlet: the load stays put and settles where it is
		}

		// Fraction of the LOAD that leaves = fraction of the WATER that leaves, capped for stability.
		float out_frac = min(total / w, MAX_OUT_FRAC);
		float scale = out_frac / total;
		send[base + 0u] = load * raw[0] * scale;
		send[base + 1u] = load * raw[1] * scale;
		send[base + 2u] = load * raw[2] * scale;
		send[base + 3u] = load * raw[3] * scale;
		send[base + 4u] = load * raw[4] * scale;
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	// Rock holds no suspension: pass its (zero) value through untouched.
	if (solid[gidx] != 0.0) {
		susp_out[gidx] = susp_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	// Each send is a fraction of the SENDER's cell; credit it scaled by vol(sender)/vol(me).
	float inflow = 0.0;
	int nb;
	nb = nbr[base + 0u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 5u] * xfer(uint(nb), gidx); }  // below sent UP
	nb = nbr[base + 5u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 0u] * xfer(uint(nb), gidx); }  // above sent DOWN
	nb = nbr[base + 1u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 2u] * xfer(uint(nb), gidx); }
	nb = nbr[base + 2u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 1u] * xfer(uint(nb), gidx); }
	nb = nbr[base + 3u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 4u] * xfer(uint(nb), gidx); }
	nb = nbr[base + 4u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 3u] * xfer(uint(nb), gidx); }

	float value = susp_in[gidx] - own_out + inflow;
	susp_out[gidx] = max(value, 0.0);
}
