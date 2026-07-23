#[compute]
#version 450

// CUBED-SPHERE EROSION PICKUP — the missing SCOUR leg of the mineral cycle (Stage D). Flowing water lifts
// bedrock off its bed into waterborne SUSPENSION; the existing M3 SETTLE record drops that susp back to loose
// SEDIMENT where flow slackens, and the granular slump CA spreads it → deltas, floodplains, beaches. Net: this
// ONE kernel closes rock_fill → susp → sediment → (lithify) rock_fill, so rivers carve their beds and the land
// gains a history — with NO scripted valleys (dissolve-don't-patch: erosion emerges from water × slope).
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
// SUSP PING-PONG CARRY: this pass runs right BEFORE ReactionsPass (which reads susp[back] for M3 SETTLE), so it
// FULLY writes the back half: susp_out[i] = susp_in[i] (live carry) + scour. Nothing else touches susp, so this
// carry + settle keeps the channel consistent across the phase flip (the stale back half is overwritten, never
// accumulated).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer WaterIn { float water_in[]; };   // settled water (back half)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; }; // calm sea sink (no scour)
layout(set = 0, binding = 3, std430) restrict buffer RockFill { float rock_fill[]; };            // bedrock mineral — scoured in place (cross-cell to DOWN, unique)
layout(set = 0, binding = 4, std430) restrict readonly buffer SuspIn { float susp_in[]; };       // susp live half (carry source)
layout(set = 0, binding = 5, std430) restrict writeonly buffer SuspOut { float susp_out[]; };    // susp back half (carry + pickup)
layout(set = 0, binding = 6, std430) restrict readonly buffer Relevance { float relevance[]; };  // Keystone C
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };             // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint step_index;   // monotonic field-step counter, for the relevance-gated update stride
	uint pad1;
	uint pad2;
} params;

// --- Tunables (behavioural, not parity-bound) -----------------------------------------------------------
const float WATER_MIN   = 0.02;   // a cell must hold real flowing water (> the wet-surface threshold) to scour
const float STREAM_K    = 0.25;   // scour per unit stream power (depth * head-gradient) per step
const float MAX_SCOUR   = 0.08;   // hard cap on bedrock lifted from one bed cell per step (anti-runaway)
const float ROCK_MIN    = 1.0e-4; // don't bother scouring a nearly-empty bed cell
const float HEAD_MIN    = 1.0e-3; // ignore negligible head differences (matches the water CA MIN_FLOW scale)

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	// Default: pure ping-pong carry of the live susp into the back half (settle reads it next).
	float susp_here = susp_in[gidx];

	// RELEVANCE-GATED (Keystone C): quiescent/far cells recompute the scour test on a continuous stride
	// instead of every step; the persist below is exactly what the kernel already does for any cell that
	// fails its own water/rock/head-gradient checks, so this gate is behaviourally exact, not approximate.
	int stride = stride_for(relevance[gidx], MAX_STRIDE, 1);
	if (!should_run(params.step_index, gidx, stride)) {
		susp_out[gidx] = susp_here;
		return;
	}

	// Only OPEN, non-static (genuinely flowing) water cells scour. Rock and the held static sea are inert.
	if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
		susp_out[gidx] = susp_here;
		return;
	}
	float depth = water_in[gidx];
	if (depth <= WATER_MIN) {
		susp_out[gidx] = susp_here;
		return;
	}

	// The BED: the radial-DOWN neighbour must be bedrock with mineral to give.
	int ib = nbr[base + 0u];
	if (ib < 0 || solid[ib] == 0.0 || rock_fill[uint(ib)] <= ROCK_MIN) {
		susp_out[gidx] = susp_here;
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
		susp_out[gidx] = susp_here;         // standing / calm water does not scour
		return;
	}

	// STREAM POWER = depth * head-gradient. Scour is capped per step AND by the bed's available mineral.
	float scour = STREAM_K * depth * grad;
	scour = min(scour, MAX_SCOUR);
	scour = min(scour, rock_fill[uint(ib)]);
	if (scour <= 0.0) {
		susp_out[gidx] = susp_here;
		return;
	}

	rock_fill[uint(ib)] = rock_fill[uint(ib)] - scour;   // debit the bed (unique target per thread)
	susp_out[gidx] = susp_here + scour;                  // credit own-cell suspension (conserving transfer)
}
