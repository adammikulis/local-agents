#[compute]
#version 450


layout(local_size_x = 64) in;

// No `restrict`: a row that does not use Back/Aux binds an already-bound buffer into those slots.
layout(set = 0, binding = 1, std430) readonly buffer Prim { float prim[]; };
layout(set = 0, binding = 2, std430) readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) readonly buffer Back { float back_half[]; };
layout(set = 0, binding = 4, std430) writeonly buffer ActiveIdx { uint active_idx[]; };
// Doubles as the dispatch-indirect argument buffer AND the atomic counter. Slots:
//   [0] groups_x   [1] groups_y (1)   [2] groups_z (1)   -- read by compute_list_dispatch_indirect at offset 0
//   [3] list_count    -- number of entries written into active_idx; the consumer's loop bound
layout(set = 0, binding = 5, std430) buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 6, std430) readonly buffer Aux { float aux[]; };
layout(set = 0, binding = 15, std430) readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = reset counters, 1 = append, 2 = publish dispatch args
	uint flags;        // predicate terms, below
	float thr;         // prim/back keep threshold
	float aux_thr;     // aux keep threshold
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Predicate terms. Bit values, not model parameters; CellListPass.Flag mirrors them.
#define F_OPEN_ONLY 1u    // reject solid cells
#define F_INCLUSIVE 2u    // keep on >= thr rather than > thr
#define F_BACK 4u         // keep when the ping-pong back half is over thr
#define F_HALO 8u         // keep when any of the six neighbours is over thr
#define F_AUX 16u         // keep when the aux channel is over aux_thr

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
		if (!hit && (params.flags & F_BACK) != 0u) {
			hit = over(back_half[g]);
		}
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
