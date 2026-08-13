#[compute]
#version 450

layout(local_size_x = 64) in;

// No `restrict`: a row with no aux, gate or ref binds an already-bound buffer into those slots.
layout(set = 0, binding = 1, std430) readonly buffer Src { float src[]; };
layout(set = 0, binding = 2, std430) readonly buffer Aux { float aux[]; };
layout(set = 0, binding = 3, std430) readonly buffer Solid { float solid[]; };
// One partial per workgroup, at a fixed slot. Folded on the CPU in float64: a cross-workgroup atomicAdd
// on floats reduces in scheduling order and does not reproduce.
layout(set = 0, binding = 4, std430) writeonly buffer Partials { float partials[]; };
layout(set = 0, binding = 5, std430) buffer Ref { float refv[]; };
layout(set = 0, binding = 6, std430) readonly buffer Gate { float gatev[]; };
layout(set = 0, binding = 7, std430) readonly buffer GateAux { float gate_aux[]; };
layout(set = 0, binding = 8, std430) readonly buffer Aux2 { float aux2[]; };
layout(set = 0, binding = 9, std430) readonly buffer Nbr { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint op;
	uint mask;
	uint base;         // this row's first partial slot
	float threshold;
	float weight;      // cell volume, m^3, or 1 for an unweighted row
	uint has_aux;      // 0 none, 1 src*aux, 2 src*(aux + aux2)
	uint has_gate;     // 0 none, 1 gate, 2 gate*gate_aux
	float gate_lo;     // gated cells are those inside [gate_lo, gate_hi)
	float gate_hi;
	uint nbr_solid;    // 1: the cell's value is how many of its six neighbours are solid
	uint pad0;
} params;

#include "neighbours.glsli"
#include "generated.glsli"

shared float s_acc[64];

// The fold's identity, so a lane that keeps no cell cannot move the result.
float la_identity() {
	if (params.op == OP_MIN) {
		return uintBitsToFloat(0x7F800000u);
	}
	if (params.op == OP_MAX) {
		return uintBitsToFloat(0xFF800000u);
	}
	return 0.0;
}

float la_fold(float a, float b) {
	if (params.op == OP_MIN) {
		return min(a, b);
	}
	if (params.op == OP_MAX) {
		return max(a, b);
	}
	return a + b;
}

float la_value(uint i) {
	if (params.nbr_solid != 0u) {
		float n = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			int nb = nbr[i * N_SLOTS + d];
			if (nb >= 0 && solid[uint(nb)] != 0.0) {
				n += 1.0;
			}
		}
		return n;
	}
	float v = src[i];
	if (params.has_aux != 0u) {
		float a = aux[i];
		if (params.has_aux == 2u) {
			a += aux2[i];
		}
		v *= a;
	}
	return v;
}

bool la_keep(uint i) {
	if (!((params.mask == MASK_ALL) || ((params.mask == MASK_OPEN) == (solid[i] == 0.0)))) {
		return false;
	}
	if (params.has_gate == 0u) {
		return true;
	}
	float g = gatev[i];
	if (params.has_gate == 2u) {
		g *= gate_aux[i];
	}
	return g >= params.gate_lo && g < params.gate_hi;
}

void main() {
	uint lid = gl_LocalInvocationID.x;
	uint g = gl_GlobalInvocationID.x;

	// op is a push constant, so this branch is uniform across the workgroup: no invocation of a LATCH
	// dispatch reaches the barriers below, which is what keeps them legal.
	if (params.op == OP_LATCH) {
		if (g < params.cell_count) {
			refv[g] = la_value(g);
		}
		return;
	}

	float acc = la_identity();
	uint stride = gl_NumWorkGroups.x * 64u;
	for (uint i = g; i < params.cell_count; i += stride) {
		if (!la_keep(i)) {
			continue;
		}
		float v = la_value(i);
		if (params.op == OP_SUM_ABS_DIFF) {
			v = abs(v - refv[i]);
		}
		if (params.op == OP_COUNT_GT) {
			acc += (v > params.threshold) ? 1.0 : 0.0;
		} else if (params.op == OP_COUNT_GE) {
			acc += (v >= params.threshold) ? 1.0 : 0.0;
		} else if (params.op == OP_COUNT) {
			acc += 1.0;
		} else if (params.op == OP_MIN || params.op == OP_MAX) {
			acc = la_fold(acc, v);
		} else {
			acc += v * params.weight;
		}
	}

	s_acc[lid] = acc;
	memoryBarrierShared();
	barrier();

	// Fixed-order tree: the loop bound is a literal, so every invocation reaches every barrier.
	for (uint s = 32u; s > 0u; s >>= 1u) {
		if (lid < s) {
			s_acc[lid] = la_fold(s_acc[lid], s_acc[lid + s]);
		}
		memoryBarrierShared();
		barrier();
	}

	if (lid == 0u) {
		partials[params.base + gl_WorkGroupID.x] = s_acc[0];
	}
}
