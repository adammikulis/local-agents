#[compute]
#version 450

// GPU 3D hydraulic-erosion ADVECT — a race-free GATHER port of MaterialErosion3D._advect(): carry suspended
// sediment one cell DOWNHILL along the water-surface gradient (so a grain torn loose in the rapids travels
// downstream before it deposits — that transport is what builds a delta at the river MOUTH). The CPU oracle
// is a SCATTER (each cell pushes a share of its own load to every lower open lateral neighbour); this kernel
// evaluates the SAME edge from both endpoints on the stable susp snapshot so mass is conserved and it is
// order-independent:  new[i] = susp[i] - (sum of shares i sends to lower neighbours) + (sum of shares higher
// neighbours send to i).  A share along an edge is susp[source]*ADVECT_FRACTION, gated by SUSP_MIN exactly
// like the oracle's _push. Constants copied EXACTLY from MaterialErosion3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SuspIn { float susp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer SuspOut { float susp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

const float ADVECT_FRACTION = 0.25;
const float SUSP_MIN = 0.0005;

// Inflow this cell receives from one lateral neighbour `n` (a higher open cell pushes a share of ITS load
// to us). Mirrors the oracle _push seen from the receiver: source pushes if water[source] > water[here].
float inflow_from(int n, float here) {
	if (solid[n] != 0.0) {
		return 0.0;
	}
	float sn = susp_in[n];
	if (sn < SUSP_MIN) {
		return 0.0;
	}
	if (water[n] <= here) {
		return 0.0;
	}
	float mv = sn * ADVECT_FRACTION;
	if (mv < SUSP_MIN) {
		return 0.0;
	}
	return mv;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		susp_out[g] = susp_in[g];
		return;
	}
	int dim_x = int(params.dim_x);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;
	int rem = idx - iy * layer;
	int iz = rem / dim_x;
	int ix = rem - iz * dim_x;

	float here = water[g];
	float s = susp_in[g];
	float newv = s;

	// OUTFLOW — this cell sends s*ADVECT_FRACTION to each strictly-lower open lateral neighbour.
	if (s >= SUSP_MIN) {
		float mv = s * ADVECT_FRACTION;
		if (mv >= SUSP_MIN) {
			if (ix > 0)         { int n = idx - 1;     if (solid[n] == 0.0 && here > water[n]) newv -= mv; }
			if (ix < dim_x - 1) { int n = idx + 1;     if (solid[n] == 0.0 && here > water[n]) newv -= mv; }
			if (iz > 0)         { int n = idx - dim_x; if (solid[n] == 0.0 && here > water[n]) newv -= mv; }
			if (iz < dim_z - 1) { int n = idx + dim_x; if (solid[n] == 0.0 && here > water[n]) newv -= mv; }
		}
	}

	// INFLOW — each strictly-higher open lateral neighbour pushes a share of its load down into us.
	if (ix > 0)         { newv += inflow_from(idx - 1, here); }
	if (ix < dim_x - 1) { newv += inflow_from(idx + 1, here); }
	if (iz > 0)         { newv += inflow_from(idx - dim_x, here); }
	if (iz < dim_z - 1) { newv += inflow_from(idx + dim_x, here); }

	susp_out[g] = newv;
}
