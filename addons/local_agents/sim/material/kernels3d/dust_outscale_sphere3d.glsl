#[compute]
#version 450

// CUBED-SPHERE DUST — OUTSCALE precompute. The sphere port of dust_outscale3d.glsl: IDENTICAL CFL out-scale
// math and constants; only neighbour addressing changes. For every non-solid cell it computes the uniform
// scale that keeps its TOTAL outgoing dust fraction at or below OUT_MAX. The raw fractions are the wind
// Courant numbers toward each OPEN lateral/upward neighbour plus the always-present downward gravity-settling
// flux; a direction blocked by rock/boundary contributes nothing. Neighbours come from the INDEX TABLE
// `nbr[idx*6 + slot]` — slot 1 = -x, 2 = +x, 3 = -z, 4 = +z, 5 = outward/UP (+y), 0 = inward/DOWN (unused
// here: the downward settling flux is fall_frac(), never gated by the open-below test — deposit is handled in
// the transport pass). fall_frac() reads only the cell's OWN velocity, so no neighbour lookup. Its math MUST
// stay identical to dust_transport_sphere3d.glsl. Constants copied EXACTLY from dust_outscale3d.glsl.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutScale { float outscale[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Relevance { float relevance[]; };  // Keystone C
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };  // per-column link dirs

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float k;             // STEP_DT / cell_size (Courant factor)
	uint step_index;     // monotonic field-step counter, for the relevance-gated update stride
	uint depth;          // radial shells per column — turns a cell index into its column for the ltan lookup
} params;

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
// The horizontal wind is stored in a per-cell frame that is a separate table from the neighbour slots (see
// wind_step_sphere3d), so "am I blowing that way" is a dot with the link direction, not a signed component.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// Transport tunables — MUST match dust_outscale3d.glsl / MaterialDust3D.gd exactly.
const float OUT_MAX = 0.55;
const float SETTLE_BASE = 0.25;
const float SETTLE_MIN_FRAC = 0.02;
const float SETTLE_WIND_REF = 6.0;

// Downward flux fraction of a cell — identical to MaterialDust3D._fall_frac / dust_transport_sphere3d.glsl.
float fall_frac(uint i, float k) {
	float vxi = vel_x[i];
	float vyi = vel_y[i];
	float vzi = vel_z[i];
	float speed = sqrt(vxi * vxi + vyi * vyi + vzi * vzi);
	float calm = clamp(1.0 - speed / SETTLE_WIND_REF, 0.0, 1.0);
	float settle = SETTLE_MIN_FRAC + (SETTLE_BASE - SETTLE_MIN_FRAC) * calm;
	return max(0.0, -vyi) * k + settle;
}

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		outscale[g] = 0.0;
		return;
	}
	// RELEVANCE-GATED (Keystone C): outscale is fully-recomputed scratch every step, not carried state, so a
	// gated cell writes 0.0 (a safe conservative default — dust_transport's inflow terms treat 0.0 there as
	// "assume no dust would have flowed out of that neighbour this step"), not a copy-through.
	int stride = stride_for(relevance[g], MAX_STRIDE, 1);
	if (!should_run(params.step_index, g, stride)) {
		outscale[g] = 0.0;
		return;
	}
	uint base = g * 6u;
	float k = params.k;

	int nb_u = nbr[base + 5u];   // UP (outward)

	// raw_out_total: horizontal + upward wind Courant fractions toward each OPEN neighbour, + the always-
	// present downward settling flux (never blocked — deposited when the cell below is solid, in transport).
	float t = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[base + uint(l + 1)];
		if (m >= 0 && solid[m] == 0.0) { t += max(0.0, toward_link(g, l)) * k; }
	}
	if (nb_u >= 0 && solid[nb_u] == 0.0) { t += max(0.0, vel_y[g]) * k; }
	t += fall_frac(g, k);

	if (t > OUT_MAX && t > 0.0) {
		outscale[g] = OUT_MAX / t;
	} else {
		outscale[g] = 1.0;
	}
}
