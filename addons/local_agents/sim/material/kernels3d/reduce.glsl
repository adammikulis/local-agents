#[compute]
#version 450

layout(local_size_x = 64) in;

// No `restrict`: a row with no aux or no ref binds an already-bound buffer into those slots.
layout(set = 0, binding = 1, std430) readonly buffer Src { float src[]; };
layout(set = 0, binding = 2, std430) readonly buffer Aux { float aux[]; };
layout(set = 0, binding = 3, std430) readonly buffer Solid { float solid[]; };
// One partial per workgroup, at a fixed slot. Summed on the CPU in float64: a cross-workgroup atomicAdd
// on floats reduces in scheduling order and does not reproduce.
layout(set = 0, binding = 4, std430) writeonly buffer Partials { float partials[]; };
layout(set = 0, binding = 5, std430) buffer Ref { float refv[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint op;
	uint mask;
	uint base;         // this row's first partial slot
	float threshold;
	float weight;      // cell volume, m^3, or 1 for an unweighted row
	uint has_aux;
	uint pad0;
} params;

#include "generated.glsli"

shared float s_acc[64];

void main() {
	uint lid = gl_LocalInvocationID.x;
	uint g = gl_GlobalInvocationID.x;

	// op is a push constant, so this branch is uniform across the workgroup: no invocation of a LATCH
	// dispatch reaches the barriers below, which is what keeps them legal.
	if (params.op == OP_LATCH) {
		if (g < params.cell_count) {
			float v = src[g];
			if (params.has_aux != 0u) {
				v *= aux[g];
			}
			refv[g] = v;
		}
		return;
	}

	float acc = 0.0;
	uint stride = gl_NumWorkGroups.x * 64u;
	for (uint i = g; i < params.cell_count; i += stride) {
		bool keep = (params.mask == MASK_ALL) || ((params.mask == MASK_OPEN) == (solid[i] == 0.0));
		if (keep) {
			float v = src[i];
			if (params.has_aux != 0u) {
				v *= aux[i];
			}
			if (params.op == OP_SUM_ABS_DIFF) {
				v = abs(v - refv[i]);
			}
			if (params.op == OP_COUNT_GT) {
				acc += (v > params.threshold) ? 1.0 : 0.0;
			} else if (params.op == OP_COUNT_GE) {
				acc += (v >= params.threshold) ? 1.0 : 0.0;
			} else {
				acc += v * params.weight;
			}
		}
	}

	s_acc[lid] = acc;
	memoryBarrierShared();
	barrier();

	// Fixed-order tree: the loop bound is a literal, so every invocation reaches every barrier.
	for (uint s = 32u; s > 0u; s >>= 1u) {
		if (lid < s) {
			s_acc[lid] += s_acc[lid + s];
		}
		memoryBarrierShared();
		barrier();
	}

	if (lid == 0u) {
		partials[params.base + gl_WorkGroupID.x] = s_acc[0];
	}
}
