#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 1, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer ActiveIdx { uint active_idx[]; };
// Doubles as the dispatch-indirect argument buffer AND the atomic counter. Slots:
layout(set = 0, binding = 5, std430) restrict buffer ActiveArgs { uint active_args[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = reset counters, 1 = append, 2 = publish dispatch args
	uint pad0;
	uint pad1;
} params;

// MUST match lava_phase_sphere3d.glsl's LAVA_MIN_MASS exactly — this predicate stands in for that kernel's
const float LAVA_MIN_MASS = 0.0001;

shared uint s_list_n;
shared uint s_list_base;

void main() {
	uint lid = gl_LocalInvocationID.x;
	uint g = gl_GlobalInvocationID.x;

	// pass_id is a push constant, so these branches are uniform across the workgroup: every invocation of a
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
