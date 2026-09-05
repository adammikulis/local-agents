#[compute]
#version 450

#include "bindings.glsli"

// Geometric multigrid for the same finite-volume Poisson equation gravity_poisson.glsl states. The
// octree levels ARE the hierarchy: level 0 is the leaf grid, level L the octree pruned at depth
// max_level - L, and the coarsest is the base lattice. One flat index space over every level.

#include "gravity_ref.glsli"
#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = LA_BIND_POS, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = LA_BIND_GRAV_DENSITY, std430) restrict readonly buffer Density { float density[]; };  // kg/m^3
layout(set = 0, binding = LA_BIND_GRAV_PHI, std430) restrict buffer Phi { float grav_phi[]; };      // J/kg
layout(set = 0, binding = LA_BIND_GRAV_MOMENTS, std430) restrict buffer Moments { float moments[]; };
layout(set = 0, binding = LA_BIND_GRAV_PARTIALS, std430) restrict buffer Partials { float partials[]; };
// The hierarchy past level 0: face rows, neighbours, and per-cell ring/colour/octant/depth.
layout(set = 0, binding = LA_BIND_MG_SLOT_OFF, std430) restrict readonly buffer MgSlotOff { int mg_slot_off[]; };
layout(set = 0, binding = LA_BIND_MG_NBR, std430) restrict readonly buffer MgNeigh { int mg_nbr[]; };
layout(set = 0, binding = LA_BIND_MG_FLAGS, std430) restrict readonly buffer MgFlags { uint mg_flags[]; };
layout(set = 0, binding = LA_BIND_MG_PARENT, std430) restrict readonly buffer MgParent { int mg_parent[]; };
layout(set = 0, binding = LA_BIND_MG_CHILD_OFF, std430) restrict readonly buffer MgChildOff { int mg_child_off[]; };
layout(set = 0, binding = LA_BIND_MG_CHILD_IDX, std430) restrict readonly buffer MgChildIdx { int mg_child_idx[]; };
layout(set = 0, binding = LA_BIND_MG_PHI, std430) restrict buffer MgPhi { float mg_phi[]; };        // J/kg
layout(set = 0, binding = LA_BIND_MG_RHS, std430) restrict buffer MgRhs { float mg_rhs[]; };        // s^-2
layout(set = 0, binding = LA_BIND_MG_RES, std430) restrict buffer MgRes { float mg_res[]; };        // s^-2

const uint MODE_LOAD = 0u;
const uint MODE_SMOOTH = 1u;
const uint MODE_RESIDUAL = 2u;
const uint MODE_RESTRICT = 3u;
const uint MODE_PROLONG = 4u;
const uint MODE_NORM = 5u;
const uint MODE_NORM_FOLD = 6u;
const uint MODE_STORE = 7u;

const uint FLAG_RING = 1u;
const uint COLOUR_SHIFT = 1u;
const uint OCTANT_SHIFT = 3u;
const uint FLAG_PASS = 64u;
const uint DEPTH_SHIFT = 7u;

const uint PART_STRIDE = 11u;      // GravityPass.PART_STRIDE
const uint PART_RES = 6u;          // worst |residual| in the workgroup
const uint PART_SRC = 7u;          // worst |4 pi G rho| in the workgroup

layout(push_constant, std430) uniform Params {
	uint cell_count;    // level 0's cells: a flat index below this reads the leaf grid's own face rows
	uint level_base;    // flat index the dispatched level starts at
	uint level_count;
	uint mode;
	uint colour;
	uint groups;
	float g_si;
	float base_edge;    // m: the edge at depth 0, which is the COARSEST agglomerated cell
} params;

shared float s_red[64];

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

uint mg_depth(uint i) { return (mg_flags[i] >> DEPTH_SHIFT) & 31u; }
float mg_edge(uint i) { return params.base_edge * exp2(-float(mg_depth(i))); }
float mg_vol(uint i) { float e = mg_edge(i); return e * e * e; }
bool mg_ring(uint i) { return (mg_flags[i] & FLAG_RING) != 0u; }

uint mg_lo(uint i, uint d) { return i < params.cell_count ? slot_off[i * 7u + d] : uint(mg_slot_off[(i - params.cell_count) * 7u + d]); }
uint mg_face_lo(uint i) { return mg_lo(i, 0u); }
uint mg_face_hi(uint i) { return mg_lo(i, 6u); }
int mg_neighbour(uint i, uint f) { return i < params.cell_count ? nbr[f] : mg_nbr[f]; }

// Face conductance, m: shared area over centre distance, the finer of the pair stating the area.
float mg_w(uint i, uint nb) {
	float a = min(mg_edge(i), mg_edge(nb));
	return a * a / (0.5 * (mg_edge(i) + mg_edge(nb)));
}

vec3 pos_at(uint c) {
	return vec3(pos[c * 3u], pos[c * 3u + 1u], pos[c * 3u + 2u]);
}

// ref(nb) - ref(c) of the reference sphere gravity_poisson.glsl seeds against.
float ref_drop(uint c, uint nb) {
	vec3 com = vec3(moments[1], moments[2], moments[3]);
	float g = params.g_si;
	float m = moments[0];
	float req = moments[7];
	return la_gref(g, m, req, length(pos_at(nb) - com)) - la_gref(g, m, req, length(pos_at(c) - com));
}

// The leaf grid's own equation: 4 pi G rho, less what the monopole reference already satisfies.
void mode_load(uint i, bool live) {
	float src = 0.0;
	if (live) {
		src = 4.0 * acos(-1.0) * params.g_si * density[i];
		mg_phi[i] = grav_phi[i];
		float acc = 0.0;
		for (uint f = mg_face_lo(i); f < mg_face_hi(i); ++f) {
			int nb = mg_neighbour(i, f);
			if (nb < 0) { continue; }
			acc += mg_w(i, uint(nb)) * ref_drop(i, uint(nb));
		}
		mg_rhs[i] = mg_ring(i) ? 0.0 : src - acc / mg_vol(i);
		mg_res[i] = 0.0;
	}
	float worst = wg_max(live && !mg_ring(i) ? abs(src) : 0.0);
	if (gl_LocalInvocationID.x == 0u) {
		partials[gl_WorkGroupID.x * PART_STRIDE + PART_SRC] = worst;
	}
}

// Red-black Gauss-Seidel over the four colours a 2:1 graded lattice needs.
void mode_smooth(uint i) {
	if (mg_ring(i) || ((mg_flags[i] >> COLOUR_SHIFT) & 3u) != params.colour) { return; }
	float sw = 0.0;
	float sp = 0.0;
	for (uint f = mg_face_lo(i); f < mg_face_hi(i); ++f) {
		int nb = mg_neighbour(i, f);
		if (nb < 0) { continue; }
		float w = mg_w(i, uint(nb));
		sw += w;
		sp += w * mg_phi[uint(nb)];
	}
	if (sw > 0.0) { mg_phi[i] = (sp - mg_vol(i) * mg_rhs[i]) / sw; }
}

void mode_residual(uint i) {
	if (mg_ring(i)) { mg_res[i] = 0.0; return; }
	float acc = 0.0;
	for (uint f = mg_face_lo(i); f < mg_face_hi(i); ++f) {
		int nb = mg_neighbour(i, f);
		if (nb < 0) { continue; }
		acc += mg_w(i, uint(nb)) * (mg_phi[uint(nb)] - mg_phi[i]);
	}
	mg_res[i] = mg_rhs[i] - acc / mg_vol(i);
}

// Volume-weighted average of the children's residual, and a zero start for the correction.
void mode_restrict(uint i) {
	float num = 0.0;
	float den = 0.0;
	for (int k = mg_child_off[i]; k < mg_child_off[i + 1]; ++k) {
		uint ch = uint(mg_child_idx[k]);
		float v = mg_vol(ch);
		num += v * mg_res[ch];
		den += v;
	}
	mg_phi[i] = 0.0;
	mg_rhs[i] = (mg_ring(i) || den <= 0.0) ? 0.0 : num / den;
	mg_res[i] = 0.0;
}

// Area-weighted potential DROP from i across one slot and the centre distance to it; false at the box face.
bool slot_mean(uint i, uint d, out float drop, out float dist) {
	float a = 0.0;
	float ap = 0.0;
	float ad = 0.0;
	for (uint f = mg_lo(i, d); f < mg_lo(i, d + 1u); ++f) {
		int nb = mg_neighbour(i, f);
		if (nb < 0) { continue; }
		float e = min(mg_edge(i), mg_edge(uint(nb)));
		float w = e * e;
		a += w;
		ap += w * (mg_phi[uint(nb)] - mg_phi[i]);
		ad += w * 0.5 * (mg_edge(i) + mg_edge(uint(nb)));
	}
	if (a <= 0.0) { return false; }
	drop = ap / a;
	dist = ad / a;
	return true;
}

// d(phi)/d(axis) across a slot pair: central where both sides exist, one-sided at the box face.
float axis_deriv(uint i, uint lo_slot, uint hi_slot) {
	float dr_lo = 0.0;
	float dr_hi = 0.0;
	float dlo = 0.0;
	float dhi = 0.0;
	bool has_lo = slot_mean(i, lo_slot, dr_lo, dlo);
	bool has_hi = slot_mean(i, hi_slot, dr_hi, dhi);
	if (has_lo && has_hi) { return (dr_hi - dr_lo) / (dlo + dhi); }
	if (has_hi) { return dr_hi / dhi; }
	if (has_lo) { return -dr_lo / dlo; }
	return 0.0;
}

// The coarse correction interpolated to the child's own centre: linear in the coarse gradient, which a
// child sits a quarter of the coarse edge along in each axis.
void mode_prolong(uint i) {
	int p = mg_parent[i];
	if (p < 0 || mg_ring(i)) { return; }
	uint pu = uint(p);
	float c = mg_phi[pu];
	if ((mg_flags[i] & FLAG_PASS) == 0u) {
		uint oct = (mg_flags[i] >> OCTANT_SHIFT) & 7u;
		float q = 0.25 * mg_edge(pu);
		for (uint a = 0u; a < 3u; ++a) {
			float s = ((oct >> a) & 1u) != 0u ? 1.0 : -1.0;
			c += s * q * axis_deriv(pu, a * 2u, a * 2u + 1u);
		}
	}
	mg_phi[i] += c;
}

void mode_norm(uint i, bool live) {
	float worst = wg_max(live ? abs(mg_res[i]) : 0.0);
	if (gl_LocalInvocationID.x == 0u) {
		partials[gl_WorkGroupID.x * PART_STRIDE + PART_RES] = worst;
	}
}

// One workgroup: the discrete residual over its own source, which is what the driver converges on.
void mode_norm_fold() {
	uint t = gl_LocalInvocationID.x;
	float r = 0.0;
	float s = 0.0;
	for (uint g = t; g < params.groups; g += 64u) {
		r = max(r, partials[g * PART_STRIDE + PART_RES]);
		s = max(s, partials[g * PART_STRIDE + PART_SRC]);
	}
	float max_r = wg_max(r);
	float max_s = wg_max(s);
	if (t == 0u) {
		moments[5] = max_s > 0.0 ? max_r / max_s : 0.0;
	}
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	bool live = g < params.level_count;
	uint i = params.level_base + g;
	switch (params.mode) {
		case MODE_LOAD:
			mode_load(i, live);
			return;
		case MODE_SMOOTH:
			if (live) { mode_smooth(i); }
			return;
		case MODE_RESIDUAL:
			if (live) { mode_residual(i); }
			return;
		case MODE_RESTRICT:
			if (live) { mode_restrict(i); }
			return;
		case MODE_PROLONG:
			if (live) { mode_prolong(i); }
			return;
		case MODE_NORM:
			mode_norm(i, live);
			return;
		case MODE_NORM_FOLD:
			mode_norm_fold();
			return;
		case MODE_STORE:
			if (live) { grav_phi[i] = mg_phi[i]; }
			return;
	}
}
