#[compute]
#version 450

// GPU 3D GRANULAR SLUMP — a race-free two-pass GATHER port of MaterialSlump3D._flow() (the granular
// landslide CA: gravity down, a LATERAL level-out GATED by the angle of repose, then up under pressure —
// mass-conserving via the same finite-volume rule the water/lava CAs use). Same shape as lava_flow3d.glsl:
// pass 0 (outflow) replays the CPU cell's ordered DOWN / LATERAL / UP logic on the OLD sediment snapshot,
// recording per-direction sends; pass 1 (inflow) sets new = old - sent + received. UNLIKE lava there is NO
// carry-heat (sediment is cold) and the lateral pass is REPOSE-GATED: sediment creeps to a lower neighbour
// only when the mass-height difference exceeds REPOSE_TAN, and only the EXCESS moves — so a heap relaxes to
// the repose slope and stops (a cone, not a puddle). Settling back into terrain (SDF stamp) is CPU-only
// (MaterialSlump3D.settle), so this kernel is a pure flow. Constants + math copied EXACTLY from
// MaterialSlump3D.gd / MaterialField3D.gd — do not diverge.
//
// Direction convention (send slot = idx*6 + dir): 0 = down, 1 = -x, 2 = +x, 3 = -z, 4 = +z, 5 = up.
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SedIn { float sed_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Send { float send[]; };            // idx*6 + dir
layout(set = 0, binding = 3, std430) restrict writeonly buffer SedOut { float sed_out[]; };

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

// Constants — MUST match MaterialSlump3D.gd / MaterialField3D.gd exactly.
const float MAX_MASS = 1.0;
const float MAX_COMPRESS = 0.02;
const float SLUMP_MAX_FLOW = 0.5;
const float SLUMP_MIN_MASS = 0.0001;
const float SLUMP_MIN_FLOW = 0.01;
const float SLUMP_LATERAL_FRACTION = 0.25;
const float REPOSE_TAN = 0.70;

// Stable amount for the LOWER of two vertically-stacked cells (identical to the water/lava CA _stable_below).
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

		if (solid[gidx] != 0.0) {
			return;
		}
		float remaining = sed_in[gidx];
		if (remaining < SLUMP_MIN_MASS) {
			return;
		}

		// 1) DOWN — gravity into the (non-solid) cell below (debris falls down a wall/cliff, piles bottom-up).
		if (iy > 0) {
			int ib = idx - layer;
			if (solid[ib] == 0.0) {
				float dflow = stable_below(remaining + sed_in[ib]) - sed_in[ib];
				dflow = clamp(dflow, 0.0, min(SLUMP_MAX_FLOW, remaining));
				if (dflow > SLUMP_MIN_FLOW) {
					send[base + 0u] = dflow;
					remaining -= dflow;
				}
			}
		}
		if (remaining < SLUMP_MIN_MASS) {
			return;
		}

		// 2) LATERAL — REPOSE-GATED level-out with the 4 XZ neighbours (order -x, +x, -z, +z; only push to a
		// lower one, and only the mass EXCESS over the repose threshold: diff - REPOSE_TAN).
		int lat_idx[4];
		bool lat_valid[4];
		lat_valid[0] = (ix - 1 >= 0);      lat_idx[0] = idx - 1;
		lat_valid[1] = (ix + 1 < dim_x);   lat_idx[1] = idx + 1;
		lat_valid[2] = (iz - 1 >= 0);      lat_idx[2] = idx - dim_x;
		lat_valid[3] = (iz + 1 < dim_z);   lat_idx[3] = idx + dim_x;
		for (int d = 0; d < 4; d++) {
			if (remaining < SLUMP_MIN_MASS) {
				break;
			}
			if (!lat_valid[d]) {
				continue;
			}
			int inb = lat_idx[d];
			if (solid[inb] != 0.0) {
				continue;
			}
			float diff = remaining - sed_in[inb];
			if (diff > REPOSE_TAN) {
				float excess = diff - REPOSE_TAN;
				float lflow = clamp(excess * SLUMP_LATERAL_FRACTION, 0.0, min(SLUMP_MAX_FLOW, remaining));
				if (lflow > SLUMP_MIN_FLOW) {
					send[base + 1u + uint(d)] = lflow;
					remaining -= lflow;
				}
			}
		}

		// 3) UP — only overflow (compressed above a full cell) presses into the cell above.
		if (remaining > MAX_MASS && iy < dim_y - 1) {
			int iu = idx + layer;
			if (solid[iu] == 0.0) {
				float uflow = remaining - stable_below(remaining + sed_in[iu]);
				uflow = clamp(uflow, 0.0, min(SLUMP_MAX_FLOW, remaining));
				if (uflow > SLUMP_MIN_FLOW) {
					send[base + 5u] = uflow;
					remaining -= uflow;
				}
			}
		}
		return;
	}

	// ---- PASS 1: INFLOW / APPLY -------------------------------------------------
	if (solid[gidx] != 0.0) {
		sed_out[gidx] = sed_in[gidx];
		return;
	}

	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	if (iy > 0)          { inflow += send[uint(idx - layer) * 6u + 5u]; }  // below sent UP
	if (iy < dim_y - 1)  { inflow += send[uint(idx + layer) * 6u + 0u]; }  // above sent DOWN
	if (ix > 0)          { inflow += send[uint(idx - 1) * 6u + 2u]; }      // -x sent +x
	if (ix < dim_x - 1)  { inflow += send[uint(idx + 1) * 6u + 1u]; }      // +x sent -x
	if (iz > 0)          { inflow += send[uint(idx - dim_x) * 6u + 4u]; }  // -z sent +z
	if (iz < dim_z - 1)  { inflow += send[uint(idx + dim_x) * 6u + 3u]; }  // +z sent -z

	sed_out[gidx] = sed_in[gidx] - own_out + inflow;
}
