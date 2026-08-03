#[compute]
#version 450

// CUBED-SPHERE ACTIVE-CELL COMPACTION. Builds a COMPACTED index list of the cells lava_phase_sphere3d.glsl
// would actually do work on this step, plus the uvec3 dispatch-indirect argument that makes that kernel run
// ONE INVOCATION PER LISTED CELL instead of one per grid cell.
//
// THE PREDICATE IS PHYSICAL: a cell is on the list because it HOLDS MOLTEN ROCK IN OPEN SPACE. Nothing about
// the viewer enters into it. (Until 2026-08-03 this predicate also AND-ed in a camera-relevance stride gate,
// so which lava cooled depended on where the player was looking; that whole mechanism is deleted — see the
// header note in MaterialSphereGPU3D.gd for the measurement that killed it.) The list is therefore EXACT: it
// contains every cell lava_phase can write and no others, at any camera position, on every step.
//
// WHY COMPACT AT ALL. lava is the sparsest thing on the planet — 2 to 22 cells of 69,120 on a typical run —
// so dispatching the full grid for it means 69,118 threads that get scheduled, read lava[g] and solid[g], and
// bail. Compaction moves the decision OFF the consumer: the consumer tests nothing, it reads its cell id out
// of `active_idx` and works. One cheap 3-float-per-cell scan replaces a full-grid dispatch of the real kernel.
// That is the O(all-cells) -> O(active-cells) step, and it is the ONLY form of do-less this field should use:
// compact on what the MATTER is doing, never on where the camera is.
//
// EXACTNESS (this is the whole correctness argument, read it before changing the predicate). The append
// predicate below is, term for term, the set of SIDE-EFFECT-FREE EARLY-OUTS that lava_phase_sphere3d.glsl
// already evaluated at the top of its own main():
//     lava[g] < LAVA_MIN_MASS            -> return        (own-cell)
//     solid[g] != 0.0                    -> return        (own-cell)
// Neither writes anything before returning, and lava_phase writes ONLY temp[g] (own cell, unique per thread),
// so dropping the un-listed cells is not an approximation -- it produces bit-identical output. The append
// order is nondeterministic (atomics), which is harmless for exactly the same reason: every listed thread
// writes one address that no other listed thread writes.
//
// NEIGHBOUR READS DO NOT NEED LISTING. lava_phase's shell-first cooling loop READS its 6 neighbours
// (lava/temp/solid) but never writes them, so a cell that merely BORDERS lava belongs nowhere on this list —
// adding a border term would enlarge the dispatch without changing a single output value.
//
// lava_phase's third own-cell early-out (temp[g] < SOLIDIFY_TEMP -> return) is deliberately NOT in the
// predicate even though it would be exact by the same argument: `temp` is not final here. ThermalPass's
// earlier legs rewrite it between this pass and lava_phase, so a temp test taken now would be answering last
// step's question. `lava` and `solid` ARE final at this point (see PLACEMENT), which is what makes them usable.
//
// PLACEMENT: runs as its own pass module between WaterSlumpLavaPass (which finalises lava[back]) and
// ThermalPass (which consumes the list for its lava_phase leg). Nothing between here and lava_phase touches
// lava or solid, so the list cannot go stale.

layout(local_size_x = 64) in;

layout(set = 0, binding = 1, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer ActiveIdx { uint active_idx[]; };
// Doubles as the dispatch-indirect argument buffer AND the atomic counter. Slots:
//   [0] groups_x   [1] groups_y (1)   [2] groups_z (1)   -- read by compute_list_dispatch_indirect at offset 0
//   [3] list_count    -- number of entries written into active_idx; the consumer's loop bound
layout(set = 0, binding = 5, std430) restrict buffer ActiveArgs { uint active_args[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = reset counters, 1 = append, 2 = publish dispatch args
	uint pad0;
	uint pad1;
} params;

// MUST match lava_phase_sphere3d.glsl's LAVA_MIN_MASS exactly — this predicate stands in for that kernel's
// own first early-out, so a different constant here would silently change which cells it processes.
const float LAVA_MIN_MASS = 0.0001;

// WORKGROUP-AGGREGATED APPEND. Each workgroup tallies its own hits in shared memory and takes ONE global
// atomic for the whole group, so the global counter sees at most cell_count/64 contended writes instead of one
// per passing cell. With the physical predicate the list is tiny (single-digit cells on a quiet planet) and
// nearly every group contributes nothing, but the aggregation stays: it costs one shared add and is what keeps
// this cheap if the predicate is ever pointed at something dense.
shared uint s_list_n;
shared uint s_list_base;

void main() {
	uint lid = gl_LocalInvocationID.x;
	uint g = gl_GlobalInvocationID.x;

	// pass_id is a push constant, so these branches are uniform across the workgroup: every invocation of a
	// group takes the same one and none of them reaches the barriers below. That is what makes the barriers
	// legal (they must sit in uniform control flow).
	if (params.pass_id == 0u) {
		if (g == 0u) {
			active_args[1] = 1u;
			active_args[2] = 1u;
			active_args[3] = 0u;
		}
		return;
	}
	if (params.pass_id == 2u) {
		if (g == 0u) {
			// One workgroup minimum. A literal 0 would be the honest O(active) statement, but a zero-group
			// indirect dispatch is not uniformly safe across backends, and one idle group of 64 threads (each
			// of which early-outs on the count) is 0.05% of a full-grid dispatch — not worth the risk.
			uint n = active_args[3];
			active_args[0] = max(1u, (n + 63u) / 64u);
		}
		return;
	}

	// ---- pass 1: APPEND ---------------------------------------------------------------------------------
	if (lid == 0u) {
		s_list_n = 0u;
	}
	memoryBarrierShared();
	barrier();

	bool keep = false;
	if (g < params.cell_count) {
		// lava_phase's own two final-input early-outs, evaluated here instead of there. This is the whole
		// predicate: the cell holds molten rock, and it is open space rather than bedrock.
		keep = (lava[g] >= LAVA_MIN_MASS) && (solid[g] == 0.0);
	}

	uint slot_local = 0u;
	if (keep) {
		slot_local = atomicAdd(s_list_n, 1u);
	}
	memoryBarrierShared();
	barrier();

	if (lid == 0u) {
		s_list_base = atomicAdd(active_args[3], s_list_n);
	}
	memoryBarrierShared();
	barrier();

	if (keep) {
		uint slot = s_list_base + slot_local;
		if (slot < params.cell_count) {
			active_idx[slot] = g;
		}
	}
}
