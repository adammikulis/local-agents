#[compute]
#version 450

// Poisson's equation for the potential of the mass that is there, relaxed red-black in place.
// One dispatch per colour: a colour's cells are never neighbours, so each reads only the other.

#include "cellvol.glsli"
#include "neighbours.glsli"
#include "matter_channels.glsli"

layout(local_size_x = 64) in;

// kg/mol per channel: amounts are mol/m^3, so amount times this is kg/m^3. The mass every other pass weighs.
layout(set = 0, binding = 14, std430) restrict readonly buffer Props { float mol_mass[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };
#include "march.glsli"
layout(set = 0, binding = 16, std430) restrict readonly buffer Pos { float pos[]; };
// bit 0 = the cell touches the outside of the box, bits 1-2 = its Gauss-Seidel colour.
layout(set = 0, binding = 17, std430) restrict buffer Flags { uint cellflag[]; };
layout(set = 0, binding = 18, std430) restrict buffer Phi { float phi[]; };          // J/kg
layout(set = 0, binding = 19, std430) restrict buffer Density { float density[]; };  // kg/m^3
layout(set = 0, binding = 20, std430) restrict buffer Grav { float g_field[]; };     // flat cell*3, m/s^2
// 0 total mass kg · 1..3 centre of mass · 4 mean |g| · 5 residual over its source · 6 Gauss ratio
layout(set = 0, binding = 21, std430) restrict buffer Moments { float moments[]; };
layout(set = 0, binding = 22, std430) restrict buffer Partials { float partials[]; };
// The one vertical relation. vert_down is the scattered inverse of vert_up; an unset entry means no cell below.
layout(set = 0, binding = 23, std430) restrict buffer VertUp { int vert_up[]; };
layout(set = 0, binding = 24, std430) restrict buffer VertDown { uint vert_down[]; };

const uint MODE_FLAGS = 0u;
const uint MODE_DENSITY = 1u;
const uint MODE_MOMENTS = 2u;
const uint MODE_SEED = 3u;
const uint MODE_RELAX = 4u;
const uint MODE_GRADIENT = 5u;
const uint MODE_RESIDUAL = 6u;
const uint MODE_FIELD_STATS = 7u;
const uint MODE_MONOPOLE = 8u;
const uint MODE_VERT_UP = 9u;
const uint MODE_VERT_DOWN = 10u;
const uint MODE_VERT_DOWN_KEY = 11u;

// Cells the packed vertical key can hold, and the offset steps stacked above them.
const uint VERT_INDEX_LIMIT = 2097152u;
const uint VERT_KEY_STEPS = 1024u;

const uint FLAG_BOUNDARY = 1u;
const uint FLAG_COLOUR_SHIFT = 1u;

const uint PART_STRIDE = 10u;    // GravityPass.PART_STRIDE

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint mode;
	uint colour;
	uint groups;
	float g_si;
	float base_edge;   // a LEVEL 0 cell's edge, m
	float ox;          // the box's minimum corner, m
	float oy;
	float oz;       // LAPhysical.GRAVITATIONAL_CONSTANT
	// MODE_MONOPOLE only: the DECLARED body's centre, radius and mass. A slice is a partial slab, so its
	// own mass is not the field's source and Poisson is never relaxed over it.
	float mono_cx;
	float mono_cy;
	float mono_cz;
	float mono_r;     // declared body radius, m
	float mono_m;     // declared body mass, kg
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

// 4 pi G times the mass in the cell: the source term of the finite-volume Poisson equation.
float source_of(uint c) {
	return 4.0 * acos(-1.0) * params.g_si * density[c] * cell_volume(c);
}

// The finite-volume Laplacian at any refinement: face conductance summed, and summed against each
// neighbour's potential. On a uniform grid it is the seven-point stencil.
void la_stencil(uint c, out float w_sum, out float w_phi) {
	w_sum = 0.0;
	w_phi = 0.0;
	for (uint f = la_face_lo(c); f < la_face_hi(c); ++f) {
		int nb = nbr[f];
		if (nb < 0) { continue; }
		float w = la_face_area(c, nb) / la_face_dist(c, nb);
		w_sum += w;
		w_phi += w * phi[uint(nb)];
	}
}

// Area-weighted potential across one slot and the centre distance to it; false at the box face.
bool la_slot_mean(uint c, uint d, out float p, out float dist) {
	float a = 0.0;
	float ap = 0.0;
	float ad = 0.0;
	for (uint f = la_slot_lo(c, d); f < la_slot_hi(c, d); ++f) {
		int nb = nbr[f];
		if (nb < 0) { continue; }
		float w = la_face_area(c, nb);
		a += w;
		ap += w * phi[uint(nb)];
		ad += w * la_face_dist(c, nb);
	}
	if (a <= 0.0) { return false; }
	p = ap / a;
	dist = ad / a;
	return true;
}

// d(phi)/d(axis) across a slot pair: central where both sides exist, one-sided at the box face.
float axis_deriv(uint c, uint lo_slot, uint hi_slot) {
	float plo = 0.0;
	float phi_hi = 0.0;
	float dlo = 0.0;
	float dhi = 0.0;
	bool has_lo = la_slot_mean(c, lo_slot, plo, dlo);
	bool has_hi = la_slot_mean(c, hi_slot, phi_hi, dhi);
	if (has_lo && has_hi) { return (phi_hi - plo) / (dlo + dhi); }
	if (has_hi) { return (phi_hi - phi[c]) / dhi; }
	if (has_lo) { return (phi[c] - plo) / dlo; }
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
	uint lvl = e < 0.75 * params.base_edge ? 1u : 0u;
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
	phi[c] = -params.g_si * total / max(r, cell_edge[c]);
}

// Gauss-Seidel in place: one dispatch per colour, and a colour's cells are never neighbours.
void mode_relax(uint c) {
	uint f = cellflag[c];
	if ((f & FLAG_BOUNDARY) != 0u || ((f >> FLAG_COLOUR_SHIFT) & 3u) != params.colour) {
		return;
	}
	float w_sum = 0.0;
	float w_phi = 0.0;
	la_stencil(c, w_sum, w_phi);
	if (w_sum > 0.0) { phi[c] = (w_phi - source_of(c)) / w_sum; }
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
					outflux += (phi[gidx] - phi[uint(nb2)])
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

// |laplacian(phi) - 4 pi G rho| over interior cells, AND the source term it is a residual OF, so the
// drain publishes their ratio. The bare difference carries G, which is small whether the solve worked.
void mode_residual(uint gidx, bool live) {
	float r = 0.0;
	float s = 0.0;
	if (live && (cellflag[gidx] & FLAG_BOUNDARY) == 0u) {
		float v = cell_volume(gidx);
		float src = source_of(gidx);
		float w_sum = 0.0;
		float w_phi = 0.0;
		la_stencil(gidx, w_sum, w_phi);
		r = abs(w_phi - w_sum * phi[gidx] - src) / v;
		s = abs(src) / v;
	}
	float worst = wg_max(r);
	float src_max = wg_max(s);
	if (gl_LocalInvocationID.x == 0u) {
		partials[gl_WorkGroupID.x * PART_STRIDE + 6u] = worst;
		partials[gl_WorkGroupID.x * PART_STRIDE + 7u] = src_max;
	}
}

// The declared body's analytic field: g = -G M(<r) r_hat / r^2, M(<r) the shell theorem inside a uniform
// body. Writes the same g_field and the same mean-|g| partials the Poisson gradient writes.
// LA_APPROX: slice_monopole_gravity
void mode_monopole(uint gidx, bool live) {
	float mag = 0.0;
	if (live) {
		vec3 rv = pos_at(gidx) - vec3(params.mono_cx, params.mono_cy, params.mono_cz);
		float r = length(rv);
		vec3 g = vec3(0.0);
		float ph = 0.0;
		if (r > 0.0 && params.mono_r > 0.0) {
			float frac = min(r / params.mono_r, 1.0);
			float m_eff = params.mono_m * frac * frac * frac;
			mag = params.g_si * m_eff / (r * r);
			g = rv * (-mag / r);
			// The same body's potential, zero at infinity: -GM/r outside, the uniform-sphere form inside.
			float rb = params.mono_r;
			ph = r >= rb ? -params.g_si * params.mono_m / r
				: -params.g_si * params.mono_m * (3.0 * rb * rb - r * r) / (2.0 * rb * rb * rb);
		}
		g_field[gidx * 3u] = g.x;
		g_field[gidx * 3u + 1u] = g.y;
		g_field[gidx * 3u + 2u] = g.z;
		phi[gidx] = ph;
	}
	float acc = wg_sum(mag);
	float hits = wg_sum(mag > 0.0 ? 1.0 : 0.0);
	if (gl_LocalInvocationID.x == 0u) {
		uint b = gl_WorkGroupID.x * PART_STRIDE;
		partials[b + 4u] = acc;
		partials[b + 5u] = hits;
		partials[b + 8u] = 0.0;
	}
}

// One workgroup: the field readings the drain publishes.
void mode_field_stats() {
	uint t = gl_LocalInvocationID.x;
	float acc = 0.0;
	float hits = 0.0;
	float worst = 0.0;
	float src = 0.0;
	float flux = 0.0;
	float m_in = 0.0;
	for (uint g = t; g < params.groups; g += 64u) {
		uint b = g * PART_STRIDE;
		acc += partials[b + 4u];
		hits += partials[b + 5u];
		worst = max(worst, partials[b + 6u]);
		src = max(src, partials[b + 7u]);
		flux += partials[b + 8u];
		m_in += partials[b + 9u];
	}
	float sum_g = wg_sum(acc);
	float n = wg_sum(hits);
	float max_r = wg_max(worst);
	float max_src = wg_max(src);
	float sum_flux = wg_sum(flux);
	float mass_in = wg_sum(m_in);
	if (t == 0u) {
		moments[4] = n > 0.0 ? sum_g / n : 0.0;
		moments[5] = max_src > 0.0 ? max_r / max_src : 0.0;
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
		case MODE_MONOPOLE:
			mode_monopole(gidx, live);
			return;
	}
}
