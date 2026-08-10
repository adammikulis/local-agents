#[compute]
#version 450

// cell sums the rain aimed AT it — its own rain when it has no open cell DOWN (inward, slot 0), plus the
// rain from the cell directly ABOVE (outward, slot 5) when that cell drains down into this open cell.
//   "down/below/ground" → INWARD radial neighbour = slot 0;  "up/above" → OUTWARD = slot 5.
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

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

	// SELF: this cell rains into itself when there is no open cell DOWN (inward). slot0 == -1 is the world
	// core/bottom (box iy==0); a solid inward neighbour is the box "solid directly below".
	float r_self = rain[g];
	if (r_self > 0.0) {
		int below = nbr[base + 0];
		bool self_target = (below < 0) || (solid[below] != 0.0);
		if (self_target) {
			add += r_self;
		}
	}

	// FROM ABOVE: the OUTWARD cell (slot 5) rains DOWN into this (open) cell — its target = idx because idx
	// is non-solid. (If idx were solid the above cell would rain into itself; handled by the guard above.)
	int above = nbr[base + 5];
	if (above >= 0) {
		float r_above = rain[above];
		if (r_above > 0.0) {
			add += r_above;
		}
	}

	// KERNEL THAT DOES NOT EXIST. Nothing ever wrote that buffer; AtmospherePass created it zero-filled and
	// UNCHANGED atmos_rain reading all-zeros", which is parity with a deleted thing and never a reason.)*
	if (add != 0.0) {
		water[g] = water[g] + add;
	}
}
