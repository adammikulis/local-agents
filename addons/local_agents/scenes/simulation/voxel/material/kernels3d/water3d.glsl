#[compute]
#version 450

// GPU 3D water CA — a race-free two-pass GATHER port of MaterialField3D.step_water(). The CPU oracle is
// a SEQUENTIAL SCATTER: each non-solid/non-static wet cell pushes water DOWN (gravity), then LATERALLY
// to its 4 XZ neighbours (level-out), then UP if overfull, reading the STABLE _water snapshot and
// writing a _wnext double buffer. That scatter races on the GPU, so this shader splits it into two
// passes over one dispatch (dispatched twice with `pass_id`, a barrier between):
//   pass 0 (outflow): each cell replays the CPU's exact ordered logic on the OLD water snapshot,
//                     recording ONLY its own per-direction outflows into a 6-float `send` slot.
//   pass 1 (inflow):  each cell = old_water - (everything it sent) + (every send aimed at it).
// This is numerically the mass-conserving equivalent of the CPU scatter+apply. Static cells are
// INFINITE SINKS: water sent at a static neighbour is subtracted from the sender but NOT gathered by
// anyone (the static cell passes its water through unchanged), so it is absorbed exactly as the CPU
// does. Constants + math copied EXACTLY from MaterialField3D.gd — do not diverge.
//
// Direction convention (send slot = idx*6 + dir):
//   0 = down (iy-1), 1 = -x (ix-1), 2 = +x (ix+1), 3 = -z (iz-1), 4 = +z (iz+1), 5 = up (iy+1).
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer WaterIn { float water_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };          // idx*6 + dir
layout(set = 0, binding = 4, std430) restrict writeonly buffer WaterOut { float water_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	uint pass_id;   // 0 = outflow, 1 = inflow/apply
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialField3D.gd exactly.
const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;
const float MIN_MASS = 0.0001;
const float MAX_FLOW = 1.0;
const float MIN_FLOW = 0.01;
const float LATERAL_FRACTION = 0.5;

// Stable amount for the LOWER of two vertically-stacked water cells given their combined mass.
float stable_below(float total_mass) {
	if (total_mass <= MAX_MASS) {
		return total_mass;
	}
	if (total_mass < 2.0 * MAX_MASS + MAX_COMPRESS) {
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS);
	}
	return (total_mass + MAX_COMPRESS) * 0.5;
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}

	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(gidx);
	int iy = idx / layer;
	int rem_i = idx - iy * layer;
	int iz = rem_i / dim_x;
	int ix = rem_i - iz * dim_x;
	uint base = gidx * 6u;

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;

		// Skip rock and calm STATIC sea — only dynamic water is a source.
		if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
			return;
		}
		float remaining = water_in[gidx];
		if (remaining < MIN_MASS) {
			return;
		}

		// 1) DOWN — gravity. Move toward the stable split with the cell below (drain into sea).
		if (iy > 0) {
			int ib = idx - layer;
			if (solid[ib] == 0.0) {
				if (static_cells[ib] != 0.0) {
					// The sea below is an infinite sink: water pours in and is absorbed.
					send[base + 0u] = remaining;
					remaining = 0.0;
				} else {
					float flow = stable_below(remaining + water_in[ib]) - water_in[ib];
					flow = clamp(flow, 0.0, min(MAX_FLOW, remaining));
					if (flow > MIN_FLOW) {
						send[base + 0u] = flow;
						remaining -= flow;
					}
				}
			}
		}
		if (remaining < MIN_MASS) {
			return;
		}

		// 2) LATERAL — level out with the 4 XZ neighbours (order: -x, +x, -z, +z; only push to lower).
		int lat_idx[4];
		bool lat_valid[4];
		lat_valid[0] = (ix - 1 >= 0);      lat_idx[0] = idx - 1;
		lat_valid[1] = (ix + 1 < dim_x);   lat_idx[1] = idx + 1;
		lat_valid[2] = (iz - 1 >= 0);      lat_idx[2] = idx - dim_x;
		lat_valid[3] = (iz + 1 < dim_z);   lat_idx[3] = idx + dim_x;
		for (int d = 0; d < 4; d++) {
			if (remaining < MIN_MASS) {
				break;
			}
			if (!lat_valid[d]) {
				continue;
			}
			int inb = lat_idx[d];
			if (solid[inb] != 0.0) {
				continue;
			}
			if (static_cells[inb] != 0.0) {
				// Reached the sea sideways (a river mouth) — absorb a share and move on.
				float drain = clamp(remaining * LATERAL_FRACTION, 0.0, remaining);
				send[base + 1u + uint(d)] = drain;
				remaining -= drain;
				continue;
			}
			float diff = remaining - water_in[inb];
			if (diff > MIN_FLOW) {
				float lflow = clamp(diff * LATERAL_FRACTION, 0.0, min(MAX_FLOW, remaining));
				if (lflow > MIN_FLOW) {
					send[base + 1u + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// 3) UP — only overflow (compressed above MAX_MASS) pushes into the cell above.
		if (remaining > MAX_MASS && iy < dim_y - 1) {
			int iu = idx + layer;
			if (solid[iu] == 0.0 && static_cells[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + water_in[iu]);
				uflow = clamp(uflow, 0.0, min(MAX_FLOW, remaining));
				if (uflow > MIN_FLOW) {
					send[base + 5u] = uflow;
					remaining -= uflow;
				}
			}
		}
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	// Rock holds no fluid; calm STATIC sea is held at rest and absorbs (never stepped) — pass through so
	// water aimed at a static/solid cell simply vanishes (drains into the sea), matching the CPU.
	if (solid[gidx] != 0.0 || static_cells[gidx] != 0.0) {
		water_out[gidx] = water_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	// down-neighbour (idx-layer) sent UP (dir 5) toward me
	if (iy > 0)          { inflow += send[uint(idx - layer) * 6u + 5u]; }
	// up-neighbour (idx+layer) sent DOWN (dir 0) toward me
	if (iy < dim_y - 1)  { inflow += send[uint(idx + layer) * 6u + 0u]; }
	// -x neighbour (idx-1) sent +x (dir 2) toward me
	if (ix > 0)          { inflow += send[uint(idx - 1) * 6u + 2u]; }
	// +x neighbour (idx+1) sent -x (dir 1) toward me
	if (ix < dim_x - 1)  { inflow += send[uint(idx + 1) * 6u + 1u]; }
	// -z neighbour (idx-dim_x) sent +z (dir 4) toward me
	if (iz > 0)          { inflow += send[uint(idx - dim_x) * 6u + 4u]; }
	// +z neighbour (idx+dim_x) sent -z (dir 3) toward me
	if (iz < dim_z - 1)  { inflow += send[uint(idx + dim_x) * 6u + 3u]; }

	water_out[gidx] = water_in[gidx] - own_out + inflow;
}
