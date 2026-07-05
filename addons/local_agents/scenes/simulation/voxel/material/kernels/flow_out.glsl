#[compute]
#version 450

// GPU liquid-flow PASS A (outflow) — the first half of a race-free two-pass GATHER port of
// MaterialLiquid._flow_liquid (shallow-water redistribution by surface head). The CPU version is a
// SCATTER (a cell pushes depth to each strictly-lower neighbour), which races on the GPU. Here each
// cell computes ONLY its own per-edge sends and writes them to a 4-float slot in `send` (indexed
// idx*4 + dir); PASS B (flow_in.glsl) then gathers each cell's net change. Direction convention:
// 0 = left (i-1), 1 = right (i+1), 2 = down (j-1), 3 = up (j+1). Constants + math copied EXACTLY from
// MaterialLiquid.gd (FLOW_FACTOR/LAVA_FLOW passed in, MAX_PAIR_FRACTION cap, freeze skip for water).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DepthIn { float depth_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TerrainH { float terrain_h[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Sampled { float sampled[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer Send { float send[]; };  // idx*4 + dir

layout(push_constant, std430) uniform Params {
	float flow_factor;
	uint freeze_aware;   // 1 => skip frozen (temp < FREEZE_TEMP) cells as sources (water); 0 => lava
	uint dim;
	uint cell_count;
} params;

const float MAX_PAIR_FRACTION = 0.5;   // LAMaterialLiquid.MAX_PAIR_FRACTION
const float FREEZE_TEMP = 0.0;         // LAMaterialLiquid.FREEZE_TEMP

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 4u;
	send[base] = 0.0;
	send[base + 1u] = 0.0;
	send[base + 2u] = 0.0;
	send[base + 3u] = 0.0;
	if (sampled[gidx] == 0.0) {
		return;
	}

	int dim = int(params.dim);
	int idx = int(gidx);
	float d = depth_in[idx];
	if (d <= 0.0) {
		return;
	}
	if (params.freeze_aware == 1u && temp[idx] < FREEZE_TEMP) {
		return;   // frozen solid — does not flow
	}

	float head = terrain_h[idx] + d;
	int i = idx % dim;
	int j = idx / dim;

	float dh0 = 0.0;
	float dh1 = 0.0;
	float dh2 = 0.0;
	float dh3 = 0.0;
	bool l0 = false;
	bool l1 = false;
	bool l2 = false;
	bool l3 = false;
	float total_diff = 0.0;

	if (i > 0) {
		int n = idx - 1;
		if (sampled[n] != 0.0) {
			float nh = terrain_h[n] + depth_in[n];
			if (nh < head) {
				dh0 = head - nh;
				l0 = true;
				total_diff += dh0;
			}
		}
	}
	if (i < dim - 1) {
		int n = idx + 1;
		if (sampled[n] != 0.0) {
			float nh = terrain_h[n] + depth_in[n];
			if (nh < head) {
				dh1 = head - nh;
				l1 = true;
				total_diff += dh1;
			}
		}
	}
	if (j > 0) {
		int n = idx - dim;
		if (sampled[n] != 0.0) {
			float nh = terrain_h[n] + depth_in[n];
			if (nh < head) {
				dh2 = head - nh;
				l2 = true;
				total_diff += dh2;
			}
		}
	}
	if (j < dim - 1) {
		int n = idx + dim;
		if (sampled[n] != 0.0) {
			float nh = terrain_h[n] + depth_in[n];
			if (nh < head) {
				dh3 = head - nh;
				l3 = true;
				total_diff += dh3;
			}
		}
	}

	if (total_diff <= 0.0) {
		return;
	}
	float move_total = min(d, total_diff * params.flow_factor);
	if (move_total <= 0.0) {
		return;
	}
	float scale = move_total / total_diff;
	if (l0) {
		send[base] = min(dh0 * scale, dh0 * MAX_PAIR_FRACTION);
	}
	if (l1) {
		send[base + 1u] = min(dh1 * scale, dh1 * MAX_PAIR_FRACTION);
	}
	if (l2) {
		send[base + 2u] = min(dh2 * scale, dh2 * MAX_PAIR_FRACTION);
	}
	if (l3) {
		send[base + 3u] = min(dh3 * scale, dh3 * MAX_PAIR_FRACTION);
	}
}
