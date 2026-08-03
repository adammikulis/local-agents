#[compute]
#version 450

// CUBED-SPHERE EROSION PICKUP — the SCOUR leg of the mineral cycle (Stage D). Flowing water lifts bedrock off
// its bed into waterborne SUSPENSION. erosion_transport_sphere3d then CARRIES that suspension downstream and
// M3 SETTLE drops it where the flow slackens, so the pair closes rock_fill → susp → (moved) → sediment →
// (lithify) rock_fill: rivers carve their beds and the mineral they lift comes back down somewhere ELSE. NO
// scripted valleys and no landform code — erosion emerges from water × slope, deposition from carriage ×
// settling.
//
// (Corrected 2026-08-03: this header claimed the cycle closed with pickup alone, "and the granular slump CA
// spreads it → deltas, floodplains, beaches". It did not. Scour credited susp to the SCOURING CELL, M3
// settled it to sediment in that same cell, and the slump CA cannot move sediment at all until it exceeds
// REPOSE_TAN 0.70 — while lithification returns it to bedrock from 0.50. The mineral went rock → susp →
// sediment → rock without ever leaving its own column: the bed was scoured and refilled in place, so no
// depositional landform was reachable. The advection leg simply did not exist.)
//
// EMERGENT STREAM POWER (no new channel): a surface water cell's scour rate ∝ its stream power, proxied by
// DEPTH × HEAD-GRADIENT = water[i] * Σ_lateral max(0, water[i] - water[nbr]). That head is the EXACT quantity
// the water CA uses to drive lateral flow (water_sphere3d.glsl:120), so scour is large precisely where water
// runs fast down a slope and ~0 in a flat lake / the calm static sea. No velocity field needed.
//
// RACE-FREEDOM: a cell i scours ONLY its radial-DOWN neighbour's bedrock (nbr slot 0). By the neighbour table's
// radial reciprocity (my slot-0 down-cell has ME as its slot-5 up-cell — the same pairing the water/slump inflow
// gathers rely on), each solid bed cell is the down-neighbour of EXACTLY ONE open cell, so the cross-cell
// `rock_fill[down] -= scour` write targets a unique address per thread → no atomics, no barrier. susp is written
// OWN-cell. As a bed cell's rock_fill scours below 0.5 the SolidDerive pass opens it (the valley incises one cell
// deeper) and MineralStamp3D carves the SDF; where susp settles + lithifies, rock_fill crosses 0.5 → new land.
//
// SUSP PING-PONG: ErosionTransportPass runs IMMEDIATELY BEFORE this pass and fully writes susp[back] (every
// cell, its load advected). This pass then ADDS its scour to susp[back] IN PLACE — an own-cell read-modify-
// write on ONE buffer, which is race-free because no thread reads another thread's susp. ReactionsPass, next,
// reads susp[back] for M3 SETTLE. So the back half is exactly "last step's load, moved" + "this step's
// pickup", and the live→back carry is the transport pass's job, not this one's.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer WaterIn { float water_in[]; };   // settled water (back half)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; }; // calm sea sink (no scour)
layout(set = 0, binding = 3, std430) restrict buffer RockFill { float rock_fill[]; };            // bedrock mineral — scoured in place (cross-cell to DOWN, unique)
layout(set = 0, binding = 4, std430) restrict buffer Susp { float susp[]; };                     // susp back half — += scour, OWN-cell only
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// --- Tunables (behavioural, not parity-bound) -----------------------------------------------------------
const float WATER_MIN   = 0.02;   // a cell must hold real flowing water (> the wet-surface threshold) to scour
const float STREAM_K    = 0.25;   // scour per unit stream power (depth * head-gradient) per step
const float MAX_SCOUR   = 0.08;   // hard cap on bedrock lifted from one bed cell per step (anti-runaway)
const float ROCK_MIN    = 1.0e-4; // don't bother scouring a nearly-empty bed cell
const float HEAD_MIN    = 1.0e-3; // ignore negligible head differences (matches the water CA MIN_FLOW scale)

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	// susp[back] already holds this cell's advected load (ErosionTransportPass wrote it). Every early return
	// below therefore writes NOTHING — leaving that load exactly as transport left it.

	// Only OPEN, non-static (genuinely flowing) water cells scour. Rock and the held static sea are inert.
	if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
		return;
	}
	float depth = water_in[gidx];
	if (depth <= WATER_MIN) {
		return;
	}

	// The BED: the radial-DOWN neighbour must be bedrock with mineral to give.
	int ib = nbr[base + 0u];
	if (ib < 0 || solid[ib] == 0.0 || rock_fill[uint(ib)] <= ROCK_MIN) {
		return;
	}

	// HEAD-GRADIENT: sum of positive water-surface excess over the 4 lateral neighbours (the same head that
	// drives the water CA's lateral flow) → large in a fast river on a slope, ~0 in a flat pond / the sea edge.
	float grad = 0.0;
	for (int d = 0; d < 4; d++) {
		int inb = nbr[base + 1u + uint(d)];
		if (inb < 0) {
			continue;
		}
		if (solid[inb] != 0.0) {
			continue;                       // a rock wall is not a downhill outlet
		}
		float diff = depth - water_in[uint(inb)];
		if (diff > HEAD_MIN) {
			grad += diff;
		}
	}
	if (grad <= HEAD_MIN) {
		return;                             // standing / calm water does not scour
	}

	// STREAM POWER = depth * head-gradient. Scour is capped per step AND by the bed's available mineral.
	float scour = STREAM_K * depth * grad;
	scour = min(scour, MAX_SCOUR);
	scour = min(scour, rock_fill[uint(ib)]);
	if (scour <= 0.0) {
		return;
	}

	rock_fill[uint(ib)] = rock_fill[uint(ib)] - scour;   // debit the bed (unique target per thread)
	susp[gidx] = susp[gidx] + scour;                     // credit own-cell suspension (conserving transfer)
}
