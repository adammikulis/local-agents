#[compute]
#version 450

// Poisson's equation for the potential of the mass that is there, relaxed red-black in place.
// One dispatch per colour: a colour's cells are never neighbours, so each reads only the other.

#include "neighbours.glsli"
#include "matter_channels.glsli"

layout(local_size_x = 64) in;

// kg/m^3 one unit of fill carries, per channel. The mass every other pass weighs.
layout(set = 0, binding = 14, std430) restrict readonly buffer Props { float rho_unit[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 16, std430) restrict readonly buffer Pos { float pos[]; };
// bit 0 = the cell touches the outside of the box, bit 1 = its red-black colour.
layout(set = 0, binding = 17, std430) restrict buffer Flags { uint cellflag[]; };
layout(set = 0, binding = 18, std430) restrict buffer Phi { float phi[]; };          // J/kg
layout(set = 0, binding = 19, std430) restrict buffer Density { float density[]; };  // kg/m^3
layout(set = 0, binding = 20, std430) restrict buffer Grav { float g_field[]; };     // flat cell*3, m/s^2
// 0 total mass kg · 1..3 centre of mass · 4 mean |g| · 5 max residual
layout(set = 0, binding = 21, std430) restrict buffer Moments { float moments[]; };
layout(set = 0, binding = 22, std430) restrict buffer Partials { float partials[]; };

const uint MODE_FLAGS = 0u;
const uint MODE_DENSITY = 1u;
const uint MODE_MOMENTS = 2u;
const uint MODE_SEED = 3u;
const uint MODE_RELAX = 4u;
const uint MODE_GRADIENT = 5u;
const uint MODE_RESIDUAL = 6u;
const uint MODE_FIELD_STATS = 7u;

const uint FLAG_BOUNDARY = 1u;
const uint FLAG_COLOUR = 2u;

const uint PART_STRIDE = 7u;     // GravityPass.PART_STRIDE

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint mode;
	uint colour;
	uint groups;
	float cell_m;     // cell edge, metres
	float g_si;       // LAPhysical.GRAVITATIONAL_CONSTANT
	uint nx;          // cells along x
	uint nxny;        // cells per z layer
} params;

shared float s_red[64];

vec3 pos_at(uint c) {
	return vec3(pos[c * 3u], pos[c * 3u + 1u], pos[c * 3u + 2u]);
}

// Every invocation must reach these, so out-of-range threads contribute the identity rather than return.
float wg_sum(float v) {
	uint t = gl_LocalInvocationID.x;
	s_red[t] = v;
	barrier();
	for (uint s = 32u; s > 0u; s >>= 1) {
		if (t < s) { s_red[t] += s_red[t + s]; }
		barrier();
	}
	float r = s_red[0];
	barrier();      // every reader is done before the next reduction overwrites the scratch
	return r;
}

float wg_max(float v) {
	uint t = gl_LocalInvocationID.x;
	s_red[t] = v;
	barrier();
	for (uint s = 32u; s > 0u; s >>= 1) {
		if (t < s) { s_red[t] = max(s_red[t], s_red[t + s]); }
		barrier();
	}
	float r = s_red[0];
	barrier();
	return r;
}

float source_k() {
	float h = params.cell_m;
	return 4.0 * acos(-1.0) * params.g_si * h * h;
}

// Sum of the six neighbours' potential. Only ever called on an interior cell, which has all six.
float neighbour_sum(uint c) {
	float acc = 0.0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		acc += phi[nbr[c * N_SLOTS + d]];
	}
	return acc;
}

// d(phi)/d(axis) across a slot pair: central where both neighbours exist, one-sided at the box face.
float axis_deriv(uint c, uint lo_slot, uint hi_slot, float h) {
	int lo = nbr[c * N_SLOTS + lo_slot];
	int hi = nbr[c * N_SLOTS + hi_slot];
	if (lo >= 0 && hi >= 0) { return (phi[hi] - phi[lo]) / (2.0 * h); }
	if (hi >= 0) { return (phi[hi] - phi[c]) / h; }
	if (lo >= 0) { return (phi[c] - phi[lo]) / h; }
	return 0.0;
}

void mode_flags(uint c) {
	uint f = 0u;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		if (nbr[c * N_SLOTS + d] < 0) { f |= FLAG_BOUNDARY; }
	}
	uint x = c % params.nx;
	uint y = (c / params.nx) % (params.nxny / params.nx);
	uint z = c / params.nxny;
	if (((x + y + z) & 1u) == 1u) { f |= FLAG_COLOUR; }
	cellflag[c] = f;
}

void mode_density(uint gidx, bool live) {
	float rho = 0.0;
	if (live) {
		for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
			rho += max(channel_at(i, gidx), 0.0) * rho_unit[i];
		}
		density[gidx] = rho;
	}
	float h = params.cell_m;
	float m = rho * h * h * h;
	vec3 p = live ? pos_at(gidx) : vec3(0.0);
	float acc_m = wg_sum(m);
	float acc_x = wg_sum(m * p.x);
	float acc_y = wg_sum(m * p.y);
	float acc_z = wg_sum(m * p.z);
	if (gl_LocalInvocationID.x == 0u) {
		uint b = gl_WorkGroupID.x * PART_STRIDE;
		partials[b] = acc_m;
		partials[b + 1u] = acc_x;
		partials[b + 2u] = acc_y;
		partials[b + 3u] = acc_z;
	}
}

// One workgroup: the per-workgroup mass moments into a total and a centre of mass.
void mode_moments() {
	uint t = gl_LocalInvocationID.x;
	float m = 0.0;
	vec3 mp = vec3(0.0);
	for (uint g = t; g < params.groups; g += 64u) {
		uint b = g * PART_STRIDE;
		m += partials[b];
		mp += vec3(partials[b + 1u], partials[b + 2u], partials[b + 3u]);
	}
	float total = wg_sum(m);
	float cx = wg_sum(mp.x);
	float cy = wg_sum(mp.y);
	float cz = wg_sum(mp.z);
	if (t == 0u) {
		moments[0] = total;
		float inv = total > 0.0 ? 1.0 / total : 0.0;
		moments[1] = cx * inv;
		moments[2] = cy * inv;
		moments[3] = cz * inv;
	}
}

// Dirichlet edge: the monopole potential of the mass the box encloses.
void mode_seed(uint c) {
	if ((cellflag[c] & FLAG_BOUNDARY) == 0u) { return; }
	float total = moments[0];
	if (total <= 0.0) {
		phi[c] = 0.0;
		return;
	}
	vec3 com = vec3(moments[1], moments[2], moments[3]);
	float r = length(pos_at(c) - com);
	phi[c] = -params.g_si * total / max(r, params.cell_m);
}

void mode_relax(uint c) {
	uint f = cellflag[c];
	if ((f & FLAG_BOUNDARY) != 0u) { return; }
	if (((f & FLAG_COLOUR) != 0u ? 1u : 0u) != params.colour) { return; }
	phi[c] = (neighbour_sum(c) - source_k() * density[c]) / 6.0;
}

void mode_gradient(uint gidx, bool live) {
	float mag = 0.0;
	if (live) {
		float h = params.cell_m;
		vec3 g = -vec3(
			axis_deriv(gidx, 0u, 1u, h),
			axis_deriv(gidx, 2u, 3u, h),
			axis_deriv(gidx, 4u, 5u, h));
		g_field[gidx * 3u] = g.x;
		g_field[gidx * 3u + 1u] = g.y;
		g_field[gidx * 3u + 2u] = g.z;
		mag = length(g);
	}
	float acc = wg_sum(mag);
	float hits = wg_sum(mag > 0.0 ? 1.0 : 0.0);
	if (gl_LocalInvocationID.x == 0u) {
		uint b = gl_WorkGroupID.x * PART_STRIDE;
		partials[b + 4u] = acc;
		partials[b + 5u] = hits;
	}
}

// |laplacian(phi) - 4 pi G rho| over interior cells, in the discrete operator's own units.
void mode_residual(uint gidx, bool live) {
	float r = 0.0;
	if (live && (cellflag[gidx] & FLAG_BOUNDARY) == 0u) {
		float h = params.cell_m;
		r = abs(neighbour_sum(gidx) - 6.0 * phi[gidx] - source_k() * density[gidx]) / (h * h);
	}
	float worst = wg_max(r);
	if (gl_LocalInvocationID.x == 0u) {
		partials[gl_WorkGroupID.x * PART_STRIDE + 6u] = worst;
	}
}

// One workgroup: the field readings the drain publishes.
void mode_field_stats() {
	uint t = gl_LocalInvocationID.x;
	float acc = 0.0;
	float hits = 0.0;
	float worst = 0.0;
	for (uint g = t; g < params.groups; g += 64u) {
		uint b = g * PART_STRIDE;
		acc += partials[b + 4u];
		hits += partials[b + 5u];
		worst = max(worst, partials[b + 6u]);
	}
	float sum_g = wg_sum(acc);
	float n = wg_sum(hits);
	float max_r = wg_max(worst);
	if (t == 0u) {
		moments[4] = n > 0.0 ? sum_g / n : 0.0;
		moments[5] = max_r;
	}
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	bool live = gidx < params.cell_count;
	switch (params.mode) {
		case MODE_FLAGS:
			if (live) { mode_flags(gidx); }
			return;
		case MODE_DENSITY:
			mode_density(gidx, live);
			return;
		case MODE_MOMENTS:
			mode_moments();
			return;
		case MODE_SEED:
			if (live) { mode_seed(gidx); }
			return;
		case MODE_RELAX:
			if (live) { mode_relax(gidx); }
			return;
		case MODE_GRADIENT:
			mode_gradient(gidx, live);
			return;
		case MODE_RESIDUAL:
			mode_residual(gidx, live);
			return;
		case MODE_FIELD_STATS:
			mode_field_stats();
			return;
	}
}
