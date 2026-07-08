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
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float k;        // STEP_DT / cell_size (Courant factor)
	float pad0;
	float pad1;
} params;

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

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		outscale[g] = 0.0;
		return;
	}
	uint base = g * 6u;
	float k = params.k;

	int nb_w = nbr[base + 1u];   // -x
	int nb_e = nbr[base + 2u];   // +x
	int nb_n = nbr[base + 3u];   // -z
	int nb_s = nbr[base + 4u];   // +z
	int nb_u = nbr[base + 5u];   // UP (+y)

	// raw_out_total: horizontal + upward wind Courant fractions toward each OPEN neighbour, + the always-
	// present downward settling flux (never blocked — deposited when the cell below is solid, in transport).
	float t = 0.0;
	if (nb_e >= 0 && solid[nb_e] == 0.0) { t += max(0.0, vel_x[g]) * k; }
	if (nb_w >= 0 && solid[nb_w] == 0.0) { t += max(0.0, -vel_x[g]) * k; }
	if (nb_s >= 0 && solid[nb_s] == 0.0) { t += max(0.0, vel_z[g]) * k; }
	if (nb_n >= 0 && solid[nb_n] == 0.0) { t += max(0.0, -vel_z[g]) * k; }
	if (nb_u >= 0 && solid[nb_u] == 0.0) { t += max(0.0, vel_y[g]) * k; }
	t += fall_frac(g, k);

	if (t > OUT_MAX && t > 0.0) {
		outscale[g] = OUT_MAX / t;
	} else {
		outscale[g] = 1.0;
	}
}
