#[compute]
#version 450

#include "neighbours.glsli"

// cell sums the rain aimed AT it — its own rain when it has no open cell DOWN, plus the

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Rain { float rain[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	int base = idx * 6;

	if (solid[g] != 0.0) {
		return;
	}

	float add = 0.0;

	// SELF: this cell rains into itself when there is no open cell DOWN (inward). N_IN == -1 is the world
	float r_self = rain[g];
	if (r_self > 0.0) {
		int below = nbr[base + int(N_IN)];
		bool self_target = (below < 0) || (solid[below] != 0.0);
		if (self_target) {
			add += r_self;
		}
	}

	// FROM ABOVE: the OUTWARD cell rains DOWN into this (open) cell — its target = idx because idx
	int above = nbr[base + int(N_OUT)];
	if (above >= 0) {
		float r_above = rain[above];
		if (r_above > 0.0) {
			add += r_above;
		}
	}

	// KERNEL THAT DOES NOT EXIST. Nothing ever wrote that buffer; AtmospherePass created it zero-filled and
	if (add != 0.0) {
		water[g] = water[g] + add;
	}
}
