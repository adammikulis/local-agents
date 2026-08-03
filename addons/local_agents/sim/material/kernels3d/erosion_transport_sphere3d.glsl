#[compute]
#version 450

// CUBED-SPHERE EROSION TRANSPORT — the missing ADVECTION leg of the mineral cycle. Suspended sediment RIDES
// THE WATER: it leaves a cell along the same links the water leaves it by, in proportion to the water that
// goes each way. Until this kernel existed, erosion_pickup_sphere3d scoured bedrock into `susp` and credited
// it to the SCOURING CELL, and M3 SETTLE dropped it straight back to `sediment` in that same cell — a river
// scoured its bed and immediately refilled it, so no depositional landform could ever form. Nothing moved.
//
// WHY THIS IS NOT "DELTA CODE". There is no landform here, no mouth test, no basin test. There is one
// universal rule — a suspended substance is carried by the flow that suspends it — plus the settling that
// already exists (M3, a constant per-step fraction, which is what a constant Stokes settling velocity looks
// like on a fixed timestep). Deposition then falls out of the two: how FAR a grain travels before it reaches
// the bed is (settling time) x (flow speed), so fast water carries its load a long way and slack water drops
// it where it slackens. A delta is the name for what that does at a river mouth; a beach, a floodplain and a
// point bar are the same rule at other places. None of them is written down anywhere.
//
// THE FLUX LAW — the water's own. A cell's water leaves DOWN under gravity (as much as the cell below can
// take) and LATERALLY toward whichever neighbours have a lower water surface, by the head difference. That is
// exactly what water_sphere3d.glsl:79-128 does, and exactly the head that erosion_pickup_sphere3d proxies
// stream power with, so scour and carriage are driven by ONE quantity. `raw_d` below reproduces those two
// terms; the fraction of the cell's SUSP that goes along link d is then raw_d / water, i.e. the same fraction
// of the load as of the water. Suspended load does not climb, so slot 5 (radially outward) carries nothing.
//
// IT READS THE WATER'S *LIVE* HALF, NOT THE SETTLED ONE, and that is the whole difference between a working
// transport leg and a token one. The head that drove this step's flow is the head the water CA SAW — the live
// half — and the back half is what is left of it AFTER the CA has equalised it away. Nothing between the water
// CA and this pass writes water[live] (Thermal, GasWind, Atmosphere and Soil all read/modify the BACK half),
// so the live half here is exactly the snapshot water_sphere3d.glsl:74 computed its sends from. Reading the
// settled half instead measures the head that did NOT move anything.
//
// CONSERVATION (the whole point). Two-pass GATHER, identical in structure to water/slump/lava: pass 0 writes
// what leaves cell i along each of its 6 slots into `send[i*6+d]` (own-cell writes only), pass 1 sets
// susp_out = susp_in - own_out + inflow, where inflow reads each neighbour's send slot aimed back at me. What
// leaves equals what arrives EXACTLY, because both ends read the same `send` entry — that is what the grid's
// SLOT-OPPOSITE RECIPROCITY contract buys (LASphereGrid header: nbr[c*6+d]==m => nbr[m*6+(d^1)]==c, repaired
// at the cube-face seams). No atomics, no scatter, no per-cell normalisation table.
//
// SINKS ARE NOT SINKS FOR SEDIMENT. The water CA treats a STATIC (calm sea) cell as an infinite sink: water
// poured into it vanishes. Mineral may NOT vanish, so here a static cell is a normal RECEIVER — it gathers
// the load a river delivers and never sends it on (calm water has no head to carry anything). The load then
// settles there through the ordinary M3 record. That, and not a special case, is what builds a delta front.
// Solid cells hold no water and so neither send nor receive; every send written below targets a neighbour
// that exists (nbr >= 0) and is non-solid, so no flux is ever aimed at a cell that will not gather it.
//
// PING-PONG: reads susp[live], FULLY writes susp[back] (every cell, including solid). Runs immediately BEFORE
// ErosionPickupPass, which then adds its fresh scour to susp[back] IN PLACE (own-cell), so ReactionsPass sees
// one consistent back half: last step's load, moved, plus this step's pickup.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SuspIn { float susp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer SuspOut { float susp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };          // PRE-step water (live half)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };  // calm sea: receives, never sends
layout(set = 0, binding = 5, std430) restrict buffer Send { float send[]; };                     // idx*6 + dir (shared scratch)
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint enabled;   // 0 = advection off (pass 0 sends nothing, so pass 1 is an exact carry) — measurement A/B
	uint pad0;
} params;

// --- Tunables -------------------------------------------------------------------------------------------
// MAX_MASS / LATERAL_SHARE mirror water_sphere3d.glsl's MAX_MASS (1.0) and LATERAL_FRACTION (0.5): the same
// two numbers decide how much WATER goes down and sideways, so they decide how much of its LOAD goes with it.
// If those move in the water CA, move them here — the load has to ride the flux the water actually took.
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
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;

		// Rock carries nothing; the held calm sea has no head, so it receives but never sends.
		if (params.enabled == 0u || solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
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

		// The water's own flux, per link, term for term as water_sphere3d.glsl computes it:
		//   DOWN (slot 0)      — gravity moves as much as the cell below can still hold (:88), or EVERYTHING
		//                        if that cell is the static sea, which the water CA drains into wholesale (:84).
		//   LATERAL (slots 1-4)— the head difference toward a lower water surface, halved (:120-122); into the
		//                        static sea, its fixed drain share (:115), because a river mouth discharges
		//                        whatever the head says about the sea's nominal level.
		//   UP (slot 5)        — nothing: suspended load does not climb.
		// A static neighbour is a sink for WATER but never for MINERAL — the load it takes is credited to it in
		// pass 1 and settles there. That is the delta front, and nothing here knows the word.
		float raw[5];
		float total = 0.0;

		int ib = nbr[base + 0u];
		raw[0] = 0.0;
		if (ib >= 0 && solid[ib] == 0.0) {
			raw[0] = (static_cells[ib] != 0.0) ? w : min(w, max(0.0, MAX_MASS - water[uint(ib)]));
		}
		total += raw[0];

		for (int d = 0; d < 4; d++) {
			raw[d + 1] = 0.0;
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			if (static_cells[inb] != 0.0) {
				raw[d + 1] = w * LATERAL_SHARE;
				total += raw[d + 1];
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
	// Rock holds no suspension: pass its (zero) value through untouched. Everything else — including the
	// static sea — applies the full gather, so mineral delivered to the sea is kept, not absorbed.
	if (solid[gidx] != 0.0) {
		susp_out[gidx] = susp_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	int nb;
	nb = nbr[base + 0u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 5u]; }  // down-neighbour sent UP (5)
	nb = nbr[base + 5u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 0u]; }  // up-neighbour sent DOWN (0)
	nb = nbr[base + 1u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 2u]; }  // -a neighbour sent +a (2)
	nb = nbr[base + 2u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 1u]; }  // +a neighbour sent -a (1)
	nb = nbr[base + 3u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 4u]; }  // -b neighbour sent +b (4)
	nb = nbr[base + 4u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 3u]; }  // +b neighbour sent -b (3)

	float value = susp_in[gidx] - own_out + inflow;
	susp_out[gidx] = max(value, 0.0);
}
