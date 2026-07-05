#[compute]
#version 450

// GPU transport for the MaterialField atmosphere — a race-free GATHER port of
// MaterialAtmosphere._transport(arr, diffuse_frac, wind_gain). One invocation per cell reads `in_arr`
// (and its neighbours), writes the moved quantity to `out_arr` (a separate buffer so no invocation
// reads a neighbour another is writing). One kernel serves vapor / cloud / fog: the caller passes the
// diffuse fraction plus the precomputed advection amounts (ax, az) and directions (sx, sz) — which
// already fold in wind_gain, STEP_DT, cell_size and the wind vector — via the push constant.
//
// Diffusion gather:  delta += (in[n] - in[idx]) * diffuse_frac * 0.25  over each sampled 4-neighbour
//   (numerically identical to the CPU symmetric right+up scatter).
// Wind gather (upwind advection): idx LOSES q[idx]*ax to its downwind-x neighbour and q[idx]*az to its
//   downwind-z neighbour (when in bounds + sampled + q[idx] > 0); idx GAINS q[u]*ax / q[u]*az from its
//   upwind neighbours u (when in bounds + sampled + q[u] > 0). Exactly mirrors the CPU scatter.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer InArr { float in_arr[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer OutArr { float out_arr[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Sampled { float sampled[]; };

layout(push_constant, std430) uniform Params {
	float diffuse_frac;
	float ax;          // clamped |wind.x| * wind_gain * STEP_DT / cell_size (0 => no x advection)
	float az;          // clamped |wind.y| * wind_gain * STEP_DT / cell_size
	int sx;            // +1 if wind.x > 0 else -1 (downwind x direction)
	int sz;            // +1 if wind.y > 0 else -1 (downwind z direction)
	uint dim;
	uint cell_count;
	uint pad;
} params;

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	if (sampled[gidx] == 0.0) {
		out_arr[gidx] = in_arr[gidx];
		return;
	}

	int dim = int(params.dim);
	int idx = int(gidx);
	int i = idx % dim;
	int j = idx / dim;
	float q = in_arr[idx];
	float df = params.diffuse_frac * 0.25;
	float delta = 0.0;

	// --- Diffusion gather over the 4 sampled neighbours ---
	if (i > 0) {
		int n = idx - 1;
		if (sampled[n] != 0.0) {
			delta += (in_arr[n] - q) * df;
		}
	}
	if (i < dim - 1) {
		int n = idx + 1;
		if (sampled[n] != 0.0) {
			delta += (in_arr[n] - q) * df;
		}
	}
	if (j > 0) {
		int n = idx - dim;
		if (sampled[n] != 0.0) {
			delta += (in_arr[n] - q) * df;
		}
	}
	if (j < dim - 1) {
		int n = idx + dim;
		if (sampled[n] != 0.0) {
			delta += (in_arr[n] - q) * df;
		}
	}

	// --- Wind advection gather (upwind) ---
	float ax = params.ax;
	float az = params.az;
	int sx = params.sx;
	int sz = params.sz;
	// Losses: idx sends downwind (only if it holds material).
	if (q > 0.0) {
		if (ax > 0.0) {
			int ni = i + sx;
			if (ni >= 0 && ni < dim && sampled[j * dim + ni] != 0.0) {
				delta -= q * ax;
			}
		}
		if (az > 0.0) {
			int nj = j + sz;
			if (nj >= 0 && nj < dim && sampled[nj * dim + i] != 0.0) {
				delta -= q * az;
			}
		}
	}
	// Gains: idx receives from its upwind neighbours (which send only if they hold material).
	if (ax > 0.0) {
		int ui = i - sx;
		if (ui >= 0 && ui < dim) {
			int u = j * dim + ui;
			if (sampled[u] != 0.0 && in_arr[u] > 0.0) {
				delta += in_arr[u] * ax;
			}
		}
	}
	if (az > 0.0) {
		int uj = j - sz;
		if (uj >= 0 && uj < dim) {
			int u = uj * dim + i;
			if (sampled[u] != 0.0 && in_arr[u] > 0.0) {
				delta += in_arr[u] * az;
			}
		}
	}

	float v = q + delta;
	if (v < 0.0) {
		v = 0.0;
	}
	out_arr[idx] = v;
}
