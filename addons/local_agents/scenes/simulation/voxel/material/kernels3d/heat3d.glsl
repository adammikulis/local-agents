#[compute]
#version 450

// GPU 3D heat CONDUCTION — a race-free double-buffered port of MaterialHeat3D.step() PART 1: relax each
// cell toward the mean of its IN-BOUNDS 6 neighbours by CONDUCT_FRACTION. One invocation per grid cell.
// Reads temp_in, writes temp_out into a SEPARATE buffer so no invocation reads a neighbour another is
// writing (the CPU oracle uses a scratch array for the same reason). Every cell — rock AND void — is
// relaxed, exactly like the CPU loop (temperature lives in every cell), so no solid check is needed;
// solid is deliberately not bound here. CONDUCT_FRACTION + the neighbour-mean rule are copied EXACTLY
// from MaterialHeat3D.gd — do not diverge. Solar/ambient/buoyancy/wet-cooling stay on the CPU.
//
// Index layout (matches MaterialField3D): idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float CONDUCT_FRACTION = 0.14;
// ENERGY-STABLE FOLD: a radiative sink above a floor + an idempotent global clamp, applied to the
// post-conduction temperature of EVERY cell (mirror of MaterialHeat3D.gd PART 1). BRANCHLESS max(0, t-floor)
// — a `t > floor` conditional would flip on float32/64 differences and break parity. Gives dry fire/lava
// plumes the heat sink a steep lapse needs; sustained sources re-pin in the later passes.
const float RAD_FLOOR = 950.0;
const float RAD_RATE = 0.30;
const float T_MIN = -80.0;
const float T_MAX = 1400.0;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}

	uint dim_x = params.dim_x;
	uint dim_y = params.dim_y;
	uint dim_z = params.dim_z;
	uint layer = dim_x * dim_z;
	uint iy = idx / layer;
	uint rem = idx - iy * layer;
	uint iz = rem / dim_x;
	uint ix = rem - iz * dim_x;

	float t0 = temp_in[idx];
	float sum = 0.0;
	int n = 0;
	if (ix > 0u)         { sum += temp_in[idx - 1u];    n += 1; }
	if (ix < dim_x - 1u) { sum += temp_in[idx + 1u];    n += 1; }
	if (iz > 0u)         { sum += temp_in[idx - dim_x]; n += 1; }
	if (iz < dim_z - 1u) { sum += temp_in[idx + dim_x]; n += 1; }
	if (iy > 0u)         { sum += temp_in[idx - layer]; n += 1; }
	if (iy < dim_y - 1u) { sum += temp_in[idx + layer]; n += 1; }

	float out_t;
	if (n == 0) {
		out_t = t0;
	} else {
		out_t = t0 + CONDUCT_FRACTION * (sum / float(n) - t0);
	}
	// ENERGY-STABLE FOLD (branchless — mirror of MaterialHeat3D.gd): radiative sink then idempotent clamp.
	out_t = out_t - RAD_RATE * max(0.0, out_t - RAD_FLOOR);
	temp_out[idx] = clamp(out_t, T_MIN, T_MAX);
}
