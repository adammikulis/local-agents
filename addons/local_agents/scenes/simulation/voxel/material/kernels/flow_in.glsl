#[compute]
#version 450

// GPU liquid-flow PASS B (inflow/apply) — the second half of the two-pass GATHER port of
// MaterialLiquid._flow_liquid. Each cell's new depth = its depth − everything it sent out (PASS A)
// + everything its 4 neighbours directed AT it. Neighbour-to-the-left sent RIGHT (dir 1) toward this
// cell, neighbour-to-the-right sent LEFT (dir 0), the down neighbour sent UP (dir 3), the up neighbour
// sent DOWN (dir 2). Clamp ≥ 0. Numerically identical to the CPU symmetric scatter + apply. Direction
// convention matches flow_out.glsl: 0 = left, 1 = right, 2 = down, 3 = up.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DepthIn { float depth_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Send { float send[]; };  // idx*4 + dir
layout(set = 0, binding = 2, std430) restrict readonly buffer Sampled { float sampled[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer DepthOut { float depth_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim;
	uint cell_count;
	uint pad0;
	uint pad1;
} params;

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	if (sampled[gidx] == 0.0) {
		depth_out[gidx] = depth_in[gidx];   // untouched (mirror the CPU apply-loop skip)
		return;
	}

	int dim = int(params.dim);
	int idx = int(gidx);
	uint base = gidx * 4u;
	float own_out = send[base] + send[base + 1u] + send[base + 2u] + send[base + 3u];

	int i = idx % dim;
	int j = idx / dim;
	float inflow = 0.0;
	if (i > 0) {
		inflow += send[uint(idx - 1) * 4u + 1u];      // left neighbour sent RIGHT
	}
	if (i < dim - 1) {
		inflow += send[uint(idx + 1) * 4u + 0u];      // right neighbour sent LEFT
	}
	if (j > 0) {
		inflow += send[uint(idx - dim) * 4u + 3u];    // down neighbour sent UP
	}
	if (j < dim - 1) {
		inflow += send[uint(idx + dim) * 4u + 2u];    // up neighbour sent DOWN
	}

	float nv = depth_in[idx] - own_out + inflow;
	if (nv < 0.0) {
		nv = 0.0;
	}
	depth_out[idx] = nv;
}
