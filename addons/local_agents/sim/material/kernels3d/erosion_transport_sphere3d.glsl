#[compute]
#version 450

#include "neighbours.glsli"

// already exists (M3, a constant per-step fraction, which is what a constant Stokes settling velocity looks
// of the load as of the water. Suspended load does not climb, so slot 5 (radially outward) carries nothing.
// susp_out = susp_in - own_out + inflow, where inflow reads each neighbour's send slot aimed back at me. What

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SuspIn { float susp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer SuspOut { float susp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };          // PRE-step water (live half)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 5, std430) restrict buffer Send { float send[]; };                     // idx*6 + dir (shared scratch)
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint enabled;   // 0 = advection off (pass 0 sends nothing, so pass 1 is an exact carry) — measurement A/B
	uint pad0;
} params;

// --- Tunables -------------------------------------------------------------------------------------------
const float MAX_MASS      = 1.0;
const float LATERAL_SHARE = 0.5;
const float WATER_MIN     = 0.02;    // below the wet-surface threshold there is no flow to ride (matches pickup)
const float MIN_SUSP      = 1.0e-6;  // don't bother moving a numerically empty load
const float MAX_OUT_FRAC  = 0.9;     // never empty a cell in one step (stability; the gather stays exact either way)

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
		for (uint z = 0u; z < N_SLOTS; ++z) { send[base + z] = 0.0; }

		// Rock carries nothing; the held calm sea has no head, so it receives but never sends.
		if (params.enabled == 0u || solid[gidx] != 0.0) {
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

		//   DOWN (N_IN)        — gravity moves as much as the cell below can still hold, or EVERYTHING
		//   UP (N_OUT)         — nothing: suspended load does not climb.
		float raw[5];
		float total = 0.0;

		int ib = nbr[base + N_IN];
		raw[0] = 0.0;
		if (ib >= 0 && solid[ib] == 0.0) {
			raw[0] = min(w, max(0.0, MAX_MASS - water[uint(ib)]));
		}
		total += raw[0];

		for (int d = 0; d < 4; d++) {
			raw[d + 1] = 0.0;
			int inb = nbr[base + N_LAT0 + uint(d)];
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
		send[base + N_IN] = load * raw[0] * scale;
		for (uint l = 0u; l < N_LATERAL_COUNT; ++l) {
			send[base + N_LAT0 + l] = load * raw[l + 1u] * scale;
		}
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	// Rock holds no suspension: pass its (zero) value through untouched. Everything else — including the
	// static sea — applies the full gather, so mineral delivered to the sea is kept, not absorbed.
	if (solid[gidx] != 0.0) {
		susp_out[gidx] = susp_in[gidx];
		return;
	}

	float own_out = 0.0;
	for (uint z = 0u; z < N_SLOTS; ++z) { own_out += send[base + z]; }

	float inflow = 0.0;
	int nb;
	// Credit the OPPOSITE slot, `d ^ 1`. These were six unrolled lines pairing 0<->5, 1<->2, 3<->4, which is
	// not this table's pairing, so load was debited into slots nobody read and read twice out of others.
	for (uint d = 0u; d < N_SLOTS; ++d) {
		nb = nbr[base + d];
		if (nb >= 0) { inflow += send[uint(nb) * N_SLOTS + opposite(d)]; }
	}

	float value = susp_in[gidx] - own_out + inflow;
	susp_out[gidx] = max(value, 0.0);
}
