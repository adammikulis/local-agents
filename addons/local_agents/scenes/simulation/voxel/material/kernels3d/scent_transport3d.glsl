#[compute]
#version 450

// GPU SCENT — TRANSPORT pass. A race-free GATHER port of the airborne-channel loop in LAMaterialScent3D.step():
// one invocation per XZ column (dispatch over dim_x*dim_z). Each column keeps its retained fraction, then sums
// the wind-biased inflow shares of its 5 packed channels from its 4 lateral neighbours (a symmetric diffusion
// share + a downwind advection share scaled by the surface wind toward this column), and applies per-channel
// decay plus a rain-wash boost (precip * RAIN_WASH). Reads only the OLD scent snapshot (scent_in) + the
// precomputed surface wind, writes scent_out, so it is order-independent and mass-aware. Emits are folded into
// scent_in on the CPU (re-uploaded each frame).
//
// Constants copied EXACTLY from MaterialScent3D.gd. Channel c, column col -> index c*area + col.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ScentIn  { float scent_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ScentOut { float scent_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer SurfVx    { float surf_vx[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer SurfVz    { float surf_vz[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_z;
	uint area;
	float precip;
} params;

// Tunables — MUST match MaterialScent3D.gd exactly.
const float DIFFUSE = 0.08;
const float ADVECT = 0.06;
const float INV_WIND_REF = 1.0 / 6.0;    // 1 / WIND_REF (=6.0)
const float RAIN_WASH = 0.30;            // extra decay * precipitation()
const int CHANNELS = 5;
// Per-channel decay per step (PREY, PREDATOR, BLOOD, FOOD, ALARM) — MaterialScent3D.DECAY.
const float DECAY[5] = float[5](0.030, 0.030, 0.100, 0.015, 0.045);

// Outflow/inflow share toward a neighbour the wind blows toward at speed `x` (only the positive part counts).
float share(float x) {
	return DIFFUSE + ADVECT * clamp(max(0.0, x) * INV_WIND_REF, 0.0, 1.0);
}

void main() {
	uint col = gl_GlobalInvocationID.x;
	if (col >= params.area) {
		return;
	}
	uint dx = params.dim_x;
	uint dz = params.dim_z;
	uint ix = col % dx;
	uint iz = col / dx;

	float wvx = surf_vx[col];
	float wvz = surf_vz[col];
	bool has_e = ix < dx - 1u;
	bool has_w = ix > 0u;
	bool has_s = iz < dz - 1u;
	bool has_n = iz > 0u;

	// Wind-biased outflow shares to each of the 4 lateral neighbours (away from this column).
	float out_e = share(wvx);
	float out_w = share(-wvx);
	float out_s = share(wvz);
	float out_n = share(-wvz);
	float out_share = 0.0;
	if (has_e) { out_share += out_e; }
	if (has_w) { out_share += out_w; }
	if (has_s) { out_share += out_s; }
	if (has_n) { out_share += out_n; }
	float keep = 1.0 - out_share;

	// Inflow shares from each neighbour (its wind blowing TOWARD this column) — pairwise-conserving.
	float in_e = has_e ? share(-surf_vx[col + 1u]) : 0.0;
	float in_w = has_w ? share(surf_vx[col - 1u]) : 0.0;
	float in_s = has_s ? share(-surf_vz[col + dx]) : 0.0;
	float in_n = has_n ? share(surf_vz[col - dx]) : 0.0;

	for (int ch = 0; ch < CHANNELS; ch++) {
		uint base = uint(ch) * params.area;
		float acc = scent_in[base + col] * keep;
		if (has_e) { acc += scent_in[base + col + 1u] * in_e; }
		if (has_w) { acc += scent_in[base + col - 1u] * in_w; }
		if (has_s) { acc += scent_in[base + col + dx] * in_s; }
		if (has_n) { acc += scent_in[base + col - dx] * in_n; }
		float d = DECAY[ch] + params.precip * RAIN_WASH;
		scent_out[base + col] = max(0.0, acc * (1.0 - d));
	}
}
