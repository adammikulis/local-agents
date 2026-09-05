#[compute]
#version 450

#include "bindings.glsli"

// Poisson's equation for the potential of the mass that is there, relaxed red-black in place.
// One dispatch per colour: a colour's cells are never neighbours, so each reads only the other.

#include "cellvol.glsli"
#include "gravity_ref.glsli"
#include "neighbours.glsli"
#include "matter_channels.glsli"

layout(local_size_x = 64) in;

// kg/mol per channel: amounts are mol/m^3, so amount times this is kg/m^3. The mass every other pass weighs.
layout(set = 0, binding = LA_BIND_GRAV_PROPS, std430) restrict readonly buffer Props { float mol_mass[]; };
layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Neigh { int nbr[]; };
#include "march.glsli"
layout(set = 0, binding = LA_BIND_POS, std430) restrict readonly buffer Pos { float pos[]; };
// bit 0 = the cell touches the outside of the box, bits 1-2 = its Gauss-Seidel colour.
layout(set = 0, binding = LA_BIND_GRAV_CELLFLAG, std430) restrict buffer Flags { uint cellflag[]; };
layout(set = 0, binding = LA_BIND_GRAV_REF, std430) restrict buffer GravRef { float grav_ref[]; };  // J/kg, the monopole reference phi is stored against
layout(set = 0, binding = LA_BIND_GRAV_PHI, std430) restrict buffer Phi { float phi[]; };          // J/kg
layout(set = 0, binding = LA_BIND_GRAV_DENSITY, std430) restrict buffer Density { float density[]; };  // kg/m^3
layout(set = 0, binding = LA_BIND_GRAVITY, std430) restrict buffer Grav { float g_field[]; };     // flat cell*3, m/s^2
// 0 mass kg · 1..3 centre of mass · 4 mean |g| · 5 gravity_multigrid.glsl's residual · 6 Gauss ratio
// · 7 the radius of the uniform sphere with that mass and the body's own second moment, m
layout(set = 0, binding = LA_BIND_GRAV_MOMENTS, std430) restrict buffer Moments { float moments[]; };
layout(set = 0, binding = LA_BIND_GRAV_PARTIALS, std430) restrict buffer Partials { float partials[]; };
// The one vertical relation. vert_down is the scattered inverse of vert_up; an unset entry means no cell below.
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict buffer VertUp { int vert_up[]; };
layout(set = 0, binding = LA_BIND_VERT_DOWN, std430) restrict buffer VertDown { uint vert_down[]; };

const uint MODE_FLAGS = 0u;
const uint MODE_DENSITY = 1u;
const uint MODE_MOMENTS = 2u;
const uint MODE_SEED = 3u;
const uint MODE_GRADIENT = 5u;
const uint MODE_FIELD_STATS = 7u;
const uint MODE_VERT_UP = 9u;
const uint MODE_VERT_DOWN = 10u;
const uint MODE_VERT_DOWN_KEY = 11u;

// Cells the packed vertical key can hold, and the offset steps stacked above them.
const uint VERT_INDEX_LIMIT = 2097152u;
const uint VERT_KEY_STEPS = 1024u;

const uint FLAG_BOUNDARY = 1u;
const uint FLAG_COLOUR_SHIFT = 1u;

const uint PART_STRIDE = 11u;    // GravityPass.PART_STRIDE

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint mode;
	uint colour;
	uint groups;
	float g_si;
	float base_edge;   // a LEVEL 0 cell's edge, m
	float ox;          // the box's minimum corner, m
	float oy;
	float oz;
	float r_datum;     // m: the potential's zero is the reference monopole's at this radius
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

// ref(nb) - ref(c) of the reference sphere: what the solve does not have to carry in float32.
float ref_drop(uint c, uint nb) {
	vec3 com = vec3(moments[1], moments[2], moments[3]);
	float g = params.g_si;
	float m = moments[0];
	float req = moments[7];
	return la_gref(g, m, req, length(pos_at(nb) - com)) - la_gref(g, m, req, length(pos_at(c) - com));
}

// Area-weighted potential DROP from c across one slot and the centre distance to it; false at the box face.
bool la_slot_mean(uint c, uint d, out float drop, out float dist) {
	float a = 0.0;
	float ap = 0.0;
	float ad = 0.0;
	for (uint f = la_slot_lo(c, d); f < la_slot_hi(c, d); ++f) {
		int nb = nbr[f];
		if (nb < 0) { continue; }
		float w = la_face_area(c, nb);
		a += w;
		ap += w * (phi[uint(nb)] - phi[c] + ref_drop(c, uint(nb)));
		ad += w * la_face_dist(c, nb);
	}
	if (a <= 0.0) { return false; }
	drop = ap / a;
	dist = ad / a;
	return true;
}

// d(phi)/d(axis) across a slot pair: central where both sides exist, one-sided at the box face.
float axis_deriv(uint c, uint lo_slot, uint hi_slot) {
	float dr_lo = 0.0;
	float dr_hi = 0.0;
	float dlo = 0.0;
	float dhi = 0.0;
	bool has_lo = la_slot_mean(c, lo_slot, dr_lo, dlo);
	bool has_hi = la_slot_mean(c, hi_slot, dr_hi, dhi);
	if (has_lo && has_hi) { return (dr_hi - dr_lo) / (dlo + dhi); }
	if (has_hi) { return dr_hi / dhi; }
	if (has_lo) { return -dr_lo / dlo; }
	return 0.0;
}

// FOUR COLOURS, because the graded face graph has odd cycles: a coarse cell with two of the fine cells
// across one of its faces. The parity of a cell's coordinates IN ITS OWN LEVEL'S LATTICE separates every
// same-level pair, and the level bit separates a coarse cell from every fine one it meets.
void mode_flags(uint c) {
	uint f = 0u;
	for (uint fi = la_face_lo(c); fi < la_face_hi(c); ++fi) {
		if (nbr[fi] < 0) { f |= FLAG_BOUNDARY; }
	}
	float e = cell_edge[c];
	vec3 q = floor((pos_at(c) - vec3(params.ox, params.oy, params.oz)) / max(e, 1.0e-30));
	uint parity = uint(mod(q.x + q.y + q.z, 2.0));
	uint lvl = uint(round(log2(max(params.base_edge / max(e, 1.0e-30), 1.0)))) & 1u;
	cellflag[c] = f | (((lvl << 1) | parity) << FLAG_COLOUR_SHIFT);
}

void mode_density(uint gidx, bool live) {
	float rho = 0.0;
	if (live) {
		for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
			rho += max(channel_at(i, gidx), 0.0) * mol_mass[i];
		}
		density[gidx] = rho;
	}
	float m = live ? rho * cell_volume(gidx) : 0.0;
	vec3 p = live ? pos_at(gidx) : vec3(0.0);
	float acc_m = wg_sum(m);
	float acc_x = wg_sum(m * p.x);
	float acc_y = wg_sum(m * p.y);
	float acc_z = wg_sum(m * p.z);
	// IN CELL EDGES, not metres: m r^2 at a planet's radius overflows float32 before the sum ends.
	float e2 = params.base_edge * params.base_edge;
	float acc_r2 = wg_sum(m * dot(p, p) / e2);
	if (gl_LocalInvocationID.x == 0u) {
		uint b = gl_WorkGroupID.x * PART_STRIDE;
		partials[b] = acc_m;
		partials[b + 1u] = acc_x;
		partials[b + 2u] = acc_y;
		partials[b + 3u] = acc_z;
		partials[b + 10u] = acc_r2;
	}
}

// One workgroup: the per-workgroup mass moments into a total, a centre of mass, and the radius of the
// uniform sphere holding that mass at that second moment — sum m r^2 = (3/5) M R^2 about the centre.
void mode_moments() {
	uint t = gl_LocalInvocationID.x;
	float m = 0.0;
	float mr2 = 0.0;
	vec3 mp = vec3(0.0);
	for (uint g = t; g < params.groups; g += 64u) {
		uint b = g * PART_STRIDE;
		m += partials[b];
		mp += vec3(partials[b + 1u], partials[b + 2u], partials[b + 3u]);
		mr2 += partials[b + 10u];
	}
	float total = wg_sum(m);
	float cx = wg_sum(mp.x);
	float cy = wg_sum(mp.y);
	float cz = wg_sum(mp.z);
	float sum_r2 = wg_sum(mr2);
	if (t == 0u) {
		moments[0] = total;
		float inv = total > 0.0 ? 1.0 / total : 0.0;
		vec3 com = vec3(cx, cy, cz) * inv;
		moments[1] = com.x;
		moments[2] = com.y;
		moments[3] = com.z;
		float e2 = params.base_edge * params.base_edge;
		float inertia = sum_r2 - total * dot(com, com) / e2;
		moments[7] = total > 0.0
			? params.base_edge * sqrt(max(5.0 * inertia / (3.0 * total), 0.0)) : 0.0;
	}
}

// THE REFERENCE, every cell: the uniform sphere the box's own mass and second moment name. `phi` holds
// the deviation from it, so float32 carries the second differences the Laplacian is made of; the
// Dirichlet ring is exactly the reference, so its deviation is zero.
void mode_seed(uint c) {
	vec3 com = vec3(moments[1], moments[2], moments[3]);
	float m = moments[0];
	float req = moments[7];
	float r = length(pos_at(c) - com);
	// STATED AGAINST THE DATUM, so float32 holds a potential of tens of kJ/kg, not tens of MJ/kg.
	grav_ref[c] = la_gref(params.g_si, m, req, r) - la_gref(params.g_si, m, req, params.r_datum);
	if ((cellflag[c] & FLAG_BOUNDARY) != 0u) { phi[c] = 0.0; }
}

void mode_gradient(uint gidx, bool live) {
	float mag = 0.0;
	float outflux = 0.0;
	float m_in = 0.0;
	if (live) {
		vec3 g = -vec3(
			axis_deriv(gidx, 0u, 1u),
			axis_deriv(gidx, 2u, 3u),
			axis_deriv(gidx, 4u, 5u));
		g_field[gidx * 3u] = g.x;
		g_field[gidx * 3u + 1u] = g.y;
		g_field[gidx * 3u + 2u] = g.z;
		mag = length(g);
		// GAUSS'S LAW ON THE SOLVER'S OWN SURFACE: summing the interior stencil equations telescopes to
		// the one-sided flux through the interface with the Dirichlet ring, equal to -4 pi G times the
		// mass the solve relaxed — an identity at convergence, so the ratio audits the solve itself.
		if ((cellflag[gidx] & FLAG_BOUNDARY) == 0u) {
			m_in = density[gidx] * cell_volume(gidx);
			for (uint f2 = la_face_lo(gidx); f2 < la_face_hi(gidx); ++f2) {
				int nb2 = nbr[f2];
				if (nb2 >= 0 && (cellflag[uint(nb2)] & FLAG_BOUNDARY) != 0u) {
					outflux += (phi[gidx] - phi[uint(nb2)] - ref_drop(gidx, uint(nb2)))
						* la_face_area(gidx, nb2) / la_face_dist(gidx, nb2);
				}
			}
		}
	}
	float acc = wg_sum(mag);
	float hits = wg_sum(mag > 0.0 ? 1.0 : 0.0);
	float flux = wg_sum(outflux);
	float mass_in = wg_sum(m_in);
	if (gl_LocalInvocationID.x == 0u) {
		uint b = gl_WorkGroupID.x * PART_STRIDE;
		partials[b + 4u] = acc;
		partials[b + 5u] = hits;
		partials[b + 8u] = flux;
		partials[b + 9u] = mass_in;
	}
}

// One workgroup: the field readings the drain publishes.
void mode_field_stats() {
	uint t = gl_LocalInvocationID.x;
	float acc = 0.0;
	float hits = 0.0;
	float flux = 0.0;
	float m_in = 0.0;
	for (uint g = t; g < params.groups; g += 64u) {
		uint b = g * PART_STRIDE;
		acc += partials[b + 4u];
		hits += partials[b + 5u];
		flux += partials[b + 8u];
		m_in += partials[b + 9u];
	}
	float sum_g = wg_sum(acc);
	float n = wg_sum(hits);
	float sum_flux = wg_sum(flux);
	float mass_in = wg_sum(m_in);
	if (t == 0u) {
		moments[4] = n > 0.0 ? sum_g / n : 0.0;
		// Interface flux over the -4 pi G M of the relaxed interior: 1 when the solve satisfies its own
		// discrete law, -1 when g points away from the mass.
		float want = -4.0 * acos(-1.0) * params.g_si * mass_in;
		moments[6] = want != 0.0 ? sum_flux / want : 0.0;
	}
}

// The cell the plumb line through `c` runs into along `dir`: the neighbour least off that line, so a
// coarse cell's four fine neighbours do not put another column's ground over this one.
int plumb_step(uint c, vec3 dir) {
	int d = la_slot_toward(dir);
	if (d < 0) {
		return -1;
	}
	int best = -1;
	float off = 0.0;
	vec3 here = pos_at(c);
	for (uint f = la_slot_lo(c, uint(d)); f < la_slot_hi(c, uint(d)); ++f) {
		int nb = nbr[f];
		if (nb < 0) {
			continue;
		}
		vec3 r = pos_at(uint(nb)) - here;
		float lat = length(r - dir * dot(r, dir));
		if (best < 0 || lat < off) {
			best = nb;
			off = lat;
		}
	}
	return best;
}

vec3 la_up_at(uint c, out bool ok) {
	vec3 g = vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
	float mag = length(g);
	ok = mag > 0.0;
	return ok ? -g / mag : vec3(0.0);
}

void mode_vert_up(uint gidx) {
	bool ok = false;
	vec3 up = la_up_at(gidx, ok);
	vert_up[gidx] = ok ? plumb_step(gidx, up) : -1;
	vert_down[gidx] = 0xFFFFFFFFu;
}

// Invert the table above, so every `below` read walks the column the pressure march built. The key is
// the claimant's offset from the plumb line over its own edge, the index below it to break a tie.
void mode_vert_down(uint gidx) {
	int u = vert_up[gidx];
	if (u < 0 || gidx >= VERT_INDEX_LIMIT) {
		return;
	}
	bool ok = false;
	vec3 up = la_up_at(uint(u), ok);
	float lat = 0.0;
	if (ok) {
		vec3 r = pos_at(gidx) - pos_at(uint(u));
		lat = length(r - up * dot(r, up)) / max(cell_edge[uint(u)], 1.0e-30);
	}
	uint q = uint(clamp(lat, 0.0, 1.0) * float(VERT_KEY_STEPS - 1u));
	atomicMin(vert_down[uint(u)], (q * VERT_INDEX_LIMIT) + gidx);
}

// Strip the offset key, leaving the cell index the audit and every `below` read want.
void mode_vert_down_key(uint gidx) {
	uint v = vert_down[gidx];
	vert_down[gidx] = v == 0xFFFFFFFFu ? v : (v % VERT_INDEX_LIMIT);
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	bool live = gidx < params.cell_count;
	switch (params.mode) {
		case MODE_VERT_UP:
			if (live) { mode_vert_up(gidx); }
			return;
		case MODE_VERT_DOWN:
			if (live) { mode_vert_down(gidx); }
			return;
		case MODE_VERT_DOWN_KEY:
			if (live) { mode_vert_down_key(gidx); }
			return;
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
		case MODE_GRADIENT:
			mode_gradient(gidx, live);
			return;
		case MODE_FIELD_STATS:
			mode_field_stats();
			return;
	}
}
