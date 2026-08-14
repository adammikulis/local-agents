#[compute]
#version 450

layout(local_size_x = 64) in;

// No `restrict`: a row that does not use Aux binds an already-bound buffer into that slot.
layout(set = 0, binding = 1, std430) readonly buffer Prim { float prim[]; };
layout(set = 0, binding = 2, std430) readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) writeonly buffer ActiveIdx { uint active_idx[]; };
// Doubles as the dispatch-indirect argument buffer AND the atomic counter. Slots:
//   [0] groups_x   [1] groups_y (1)   [2] groups_z (1)   -- read by compute_list_dispatch_indirect at offset 0
//   [3] list_count    -- number of entries written into active_idx; the consumer's loop bound
layout(set = 0, binding = 5, std430) buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 6, std430) readonly buffer Aux { float aux[]; };
// 1 where this cell is in the list. A consumer dispatched over the list gathers only from cells that are
// in it — a cell that is out never ran, so whatever its scratch holds belongs to somebody else.
layout(set = 0, binding = 7, std430) writeonly buffer ActiveFlag { uint active_flag[]; };
layout(set = 0, binding = 15, std430) readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = reset counters, 1 = append, 2 = publish dispatch args
	uint flags;        // predicate terms, below
	float thr;         // prim keep threshold
	float aux_thr;     // aux keep threshold
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Below the buffer blocks, so a future block name cannot collide with a generated slot name.
#include "generated.glsli"

shared uint s_list_n;
shared uint s_list_base;

bool over(float v) {
	return ((params.flags & F_INCLUSIVE) != 0u) ? (v >= params.thr) : (v > params.thr);
}

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
			// One workgroup minimum: a zero-group indirect dispatch is not uniformly safe across backends.
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
		bool hit = over(prim[g]);
		if (!hit && (params.flags & F_AUX) != 0u) {
			hit = aux[g] > params.aux_thr;
		}
		if (!hit && (params.flags & F_HALO) != 0u) {
			uint base = g * 6u;
			for (int d = 0; d < 6; ++d) {
				int nb = nbr[base + uint(d)];
				if (nb >= 0 && over(prim[uint(nb)])) {
					hit = true;
				}
			}
		}
		keep = hit && ((params.flags & F_OPEN_ONLY) == 0u || solid[g] == 0.0);
		active_flag[g] = keep ? 1u : 0u;   // APPEND already sweeps the grid, so this needs no clearing pass
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
