#[compute]
#version 450

// CUBED-SPHERE ACTIVE-CELL COMPACTION (Keystone C, asymptotic half). Builds a COMPACTED index list of the
// cells lava_phase_sphere3d.glsl would actually do work on this step, plus the uvec3 dispatch-indirect
// argument that makes that kernel run ONE INVOCATION PER LISTED CELL instead of one per grid cell.
//
// WHY THIS EXISTS. The shipped relevance mechanism (activity_sphere3d.glsl + LALodStride) throttles work by
// making each thread evaluate a per-cell update STRIDE and early-out. That saves ALU, but every kernel still
// dispatched the FULL grid, so it saved nothing on dispatch, scheduling or the memory traffic of reading each
// cell's inputs just to decide to bail. This kernel moves the decision OFF the consumer: the consumer no
// longer tests anything, it just reads its cell id out of `active_idx` and works. That is the O(all-cells) ->
// O(active-cells) step.
//
// EXACTNESS (this is the whole correctness argument, read it before changing the predicate). The append
// predicate below is, term for term, the set of SIDE-EFFECT-FREE EARLY-OUTS that lava_phase_sphere3d.glsl
// already evaluated at the top of its own main():
//     lava[g] < LAVA_MIN_MASS            -> return        (own-cell)
//     solid[g] != 0.0                    -> return        (own-cell)
//     !should_run(step, g, stride(rel))  -> return        (the Keystone C stride gate)
// None of the three writes anything before returning, and lava_phase writes ONLY temp[g] (own cell, unique
// per thread), so dropping the un-listed cells is not an approximation -- it produces bit-identical output.
// The append order is nondeterministic (atomics), which is harmless for exactly the same reason: every listed
// thread writes one address that no other listed thread writes.
//
// KEEPING IT EXACT WHEN YOU EXTEND IT. A predicate term is only safe here if the consumer's matching branch is
// a bare `return`. Most of the other gated kernels FAIL that test and must not be compacted with this
// predicate as-is: fire_sphere3d persists (`fire_out = fire_in`), erosion_pickup carries susp live->back,
// dust_outscale writes 0.0, charge_accum keeps applying its quiet leak, soil zeroes send[] before its gate.
// Every one of those needs the un-listed cells written, so they need their carry hoisted out (see the pass
// module's header) before a compacted dispatch is legal for them.
//
// PLACEMENT: runs as its own pass module between WaterSlumpLavaPass (which finalises lava[back]) and
// ThermalPass (which consumes the list for its lava_phase leg). `relevance` is activity[LIVE] -- the same
// half, and therefore the same one-step lag, that lava_phase_sphere3d.glsl read for itself before this
// existed. Nothing between here and lava_phase touches lava or solid, so the list cannot go stale.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Relevance { float relevance[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer ActiveIdx { uint active_idx[]; };
// Doubles as the dispatch-indirect argument buffer AND the atomic counters. Slots:
//   [0] groups_x   [1] groups_y (1)   [2] groups_z (1)   -- read by compute_list_dispatch_indirect at offset 0
//   [3] list_count    -- number of entries written into active_idx; the consumer's loop bound
//   [4] relevance_gate_count -- TELEMETRY: how many cells passed the stride gate ALONE, i.e. how many
//       invocations a relevance-only compaction (one shared list for every gated pass) would dispatch.
//   [5] static_hot_count     -- TELEMETRY: static (held sea) cells scoring relevance >= 0.5, i.e. how much of
//       the ocean the relevance channel currently considers worth full-rate compute.
layout(set = 0, binding = 5, std430) restrict buffer ActiveArgs { uint active_args[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint step_index;   // monotonic field-step counter — the LALodStride "tick"
	uint pass_id;      // 0 = reset counters, 1 = append, 2 = publish dispatch args
	uint pad0;
} params;

// MUST match lava_phase_sphere3d.glsl's LAVA_MIN_MASS exactly — this predicate stands in for that kernel's
// own first early-out, so a different constant here would silently change which cells it processes.
const float LAVA_MIN_MASS = 0.0001;
// Relevance high enough that stride_for resolves to <= 2 — the same "near full rate" cutoff
// MaterialFieldQueries3D.active_cells() uses on the CPU, so the two numbers are directly comparable.
const float HOT_RELEVANCE = 0.5;

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly. Identical
// to the copies in fire/erosion/soil/lava_phase/charge/dust; this kernel now evaluates it ON BEHALF OF
// lava_phase, which no longer carries its own copy.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

// WORKGROUP-AGGREGATED APPEND. Each workgroup tallies its own hits in shared memory and takes ONE global
// atomic for the whole group, so the global counter sees cell_count/64 contended writes instead of one per
// passing cell. That matters the moment this mechanism is pointed at a dense predicate: the telemetry counter
// below passes ~57% of the grid on a live sandbox, and 74K serialised device-scope atomics per step would cost
// more than the dispatch this exists to save.
shared uint s_list_n;
shared uint s_list_base;
shared uint s_rel_n;
shared uint s_sea_n;

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
			active_args[4] = 0u;
			active_args[5] = 0u;
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
		s_rel_n = 0u;
		s_sea_n = 0u;
	}
	memoryBarrierShared();
	barrier();

	bool keep = false;
	bool gate_open = false;
	bool sea_hot = false;
	if (g < params.cell_count) {
		float rel = relevance[g];
		gate_open = should_run(params.step_index, g, stride_for(rel, MAX_STRIDE, 1));
		sea_hot = (static_cells[g] != 0.0) && (rel >= HOT_RELEVANCE);
		// lava_phase's own first two early-outs, evaluated here instead of there.
		keep = gate_open && (lava[g] >= LAVA_MIN_MASS) && (solid[g] == 0.0);
	}

	uint slot_local = 0u;
	if (keep) {
		slot_local = atomicAdd(s_list_n, 1u);
	}
	if (gate_open) {
		atomicAdd(s_rel_n, 1u);
	}
	if (sea_hot) {
		atomicAdd(s_sea_n, 1u);
	}
	memoryBarrierShared();
	barrier();

	if (lid == 0u) {
		s_list_base = atomicAdd(active_args[3], s_list_n);
		if (s_rel_n > 0u) {
			atomicAdd(active_args[4], s_rel_n);
		}
		if (s_sea_n > 0u) {
			atomicAdd(active_args[5], s_sea_n);
		}
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
