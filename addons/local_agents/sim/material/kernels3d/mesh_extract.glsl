#[compute]
#version 450

#include "bindings.glsli"

// THE FREE SURFACE OF THE FIELD'S LIQUID, AS A MESH: a detector the renderer receives and the field
// never reads. A corner is the mean over the surface cells meeting there, so the sheet is continuous;
// where none meets it the sheet ends, and that edge is the shoreline.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Nbr { int nbr[]; };
layout(set = 0, binding = LA_BIND_POS, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = LA_BIND_CELL_EDGE, std430) restrict readonly buffer CellEdge { float cell_edge[]; };
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict readonly buffer VertUp { int vert_up[]; };
layout(set = 0, binding = LA_BIND_GROUND_D, std430) restrict readonly buffer GroundD { float ground_d[]; };
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = LA_BIND_H2O, std430) restrict readonly buffer H2O { float h2o[]; };
layout(set = 0, binding = LA_BIND_H2O_LIQUID, std430) restrict readonly buffer H2OLiquid { float h2o_liquid[]; };

// 0 vertices claimed, 1 indices claimed, 2 shared corners two cells disagree about, 3 seams examined.
layout(set = 0, binding = LA_BIND_MESH_COUNT, std430) restrict buffer MeshCount { uint mesh_count[]; };
layout(set = 0, binding = LA_BIND_MESH_VERT, std430) restrict writeonly buffer MeshVert { float mesh_vert[]; };
layout(set = 0, binding = LA_BIND_MESH_ATTR, std430) restrict writeonly buffer MeshAttr { float mesh_attr[]; };
layout(set = 0, binding = LA_BIND_MESH_INDEX, std430) restrict writeonly buffer MeshIndex { uint mesh_index[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float centre_x;      // the body centre every radius here is measured from
	float centre_y;
	float centre_z;
	float full_amount;   // mol/m^3 of a cell full of liquid
	uint max_quads;      // vertices the buffers hold, over four
	float r_step_m;      // one float32 step at this body's radius: the resolution every height here has
	uint mode;           // 0 extract, 1 zero the counters, 2 examine the seams
} params;

vec3 la_pos(uint c) { return vec3(pos[c * 3u], pos[c * 3u + 1u], pos[c * 3u + 2u]); }

// Liquid water in a cell, mol/m^3.
float la_liquid(uint c) { return max(h2o[c], 0.0) * clamp(h2o_liquid[c], 0.0, 1.0); }

// Water thinner than the precision a radius carries here has no top a vertex could stand at.
bool la_has_water(uint c) {
	if (c >= params.cell_count || solid[c] != 0.0) {
		return false;
	}
	float fill = clamp(la_liquid(c) / max(params.full_amount, 1.0), 0.0, 1.0);
	return fill * cell_edge[c] >= params.r_step_m;
}

// The radius of `c`'s free surface, -1 where none: water stands on the ground inside the cell, which is
// what makes a coarse cell and a fine one agree about where the same sheet is.
float la_surface_r(uint c, vec3 centre) {
	if (!la_has_water(c)) {
		return -1.0;
	}
	int hi = vert_up[c];
	if (hi >= 0 && uint(hi) < params.cell_count && (solid[hi] != 0.0 || la_has_water(uint(hi)))) {
		return -1.0;   // not the free surface: more liquid or rock stands over it
	}
	float fill = clamp(la_liquid(c) / max(params.full_amount, 1.0), 0.0, 1.0);
	float r_c = length(la_pos(c) - centre);
	float e = cell_edge[c];
	float r_bed = max(r_c - ground_d[c], r_c - 0.5 * e);
	return min(r_bed + fill * e, r_c + 0.5 * e);
}

// The neighbour of `c` across slot `d`, or -1. A coarse cell meets four fine ones on a slot; the first
// face of the slot names the one whose corner this cell shares.
int la_neighbour(uint c, uint d) {
	uint lo = la_slot_lo(c, d);
	return lo < la_slot_hi(c, d) ? nbr[lo] : -1;
}

// The axis a cell's own radial leans on hardest; the other two are its lateral pair.
uint la_vert_axis(vec3 up) {
	return abs(up.x) >= abs(up.y) && abs(up.x) >= abs(up.z) ? 0u
			: (abs(up.y) >= abs(up.z) ? 1u : 2u);
}

// The axis it leans on least, which is never parallel to it, so a cross product against it stands.
uint la_least_axis(vec3 up) {
	return abs(up.x) <= abs(up.y) && abs(up.x) <= abs(up.z) ? 0u
			: (abs(up.y) <= abs(up.z) ? 1u : 2u);
}

vec3 la_axis_vec(uint i) {
	return vec3(i == 0u ? 1.0 : 0.0, i == 1u ? 1.0 : 0.0, i == 2u ? 1.0 : 0.0);
}

// Corner (si, sj) of `c`'s quad: the mean surface of the cells meeting there, sorted before summing so
// two cells gathering the same four in different orders reach the same answer.
float la_corner_r(uint c, uint si, uint sj, uint ax0, uint ax1, float r_top, vec3 centre) {
	float v[4] = float[4](r_top, -1.0, -1.0, -1.0);
	int na = la_neighbour(c, ax0 * 2u + si);
	int nb = la_neighbour(c, ax1 * 2u + sj);
	// The diagonal either way round, so a cell against a wall still finds the fourth cell at its corner.
	int nd = na >= 0 ? la_neighbour(uint(na), ax1 * 2u + sj)
					 : (nb >= 0 ? la_neighbour(uint(nb), ax0 * 2u + si) : -1);
	if (na >= 0) {
		v[1] = la_surface_r(uint(na), centre);
	}
	if (nd >= 0) {
		v[2] = la_surface_r(uint(nd), centre);
	}
	if (nb >= 0) {
		v[3] = la_surface_r(uint(nb), centre);
	}
	for (int i = 0; i < 3; ++i) {
		for (int j = 0; j < 3 - i; ++j) {
			if (v[j] > v[j + 1]) {
				float t = v[j];
				v[j] = v[j + 1];
				v[j + 1] = t;
			}
		}
	}
	// Deviations, never absolute radii: a float32 holds half a metre at a planet's radius.
	float sum = 0.0;
	float n = 0.0;
	for (int i = 0; i < 4; ++i) {
		if (v[i] >= 0.0) { sum += v[i] - r_top; n += 1.0; }
	}
	return n > 0.0 ? r_top + sum / n : r_top;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (params.mode == 1u) {
		if (g < 4u) {
			mesh_count[g] = 0u;
		}
		return;
	}
	if (g >= params.cell_count) {
		return;
	}
	vec3 centre = vec3(params.centre_x, params.centre_y, params.centre_z);
	float r_top = la_surface_r(g, centre);
	if (r_top < 0.0) {
		return;
	}
	vec3 p = la_pos(g);
	vec3 up = normalize(p - centre);
	uint v_axis = la_vert_axis(up);
	uint ax0 = (v_axis + 1u) % 3u;
	uint ax1 = (v_axis + 2u) % 3u;

	if (params.mode == 2u) {
		// TWO CELLS OF THE SAME SIZE SHARING A LATERAL FACE SHARE TWO CORNERS. Each computes them from
		// its own side; where the two answers differ the sheet has a hole along that edge.
		for (uint axis = 0u; axis < 2u; ++axis) {
			uint ax = axis == 0u ? ax0 : ax1;
			int nb = la_neighbour(g, ax * 2u + 1u);
			if (nb < 0 || uint(nb) >= params.cell_count || cell_edge[uint(nb)] != cell_edge[g]) {
				continue;
			}
			float r_nb = la_surface_r(uint(nb), centre);
			vec3 up_n = normalize(la_pos(uint(nb)) - centre);
			if (r_nb < 0.0 || la_vert_axis(up_n) != v_axis
					|| la_least_axis(up_n) != la_least_axis(up)) {
				continue;   // no surface there, or the two build different lateral bases
			}
			for (uint t = 0u; t < 2u; ++t) {
				float mine = axis == 0u ? la_corner_r(g, 1u, t, ax0, ax1, r_top, centre)
										: la_corner_r(g, t, 1u, ax0, ax1, r_top, centre);
				float theirs = axis == 0u ? la_corner_r(uint(nb), 0u, t, ax0, ax1, r_nb, centre)
										  : la_corner_r(uint(nb), t, 0u, ax0, ax1, r_nb, centre);
				atomicAdd(mesh_count[3], 1u);
				// Each side rounds its own mean once at the body's radius, so two answers stand at most
				// two steps apart before the sheet has actually opened.
				if (abs(mine - theirs) > 2.0 * params.r_step_m) {
					atomicAdd(mesh_count[2], 1u);
				}
			}
		}
		return;
	}

	// A lateral basis across the cell's own vertical, built the same way in every cell.
	vec3 a = normalize(cross(la_axis_vec(la_least_axis(up)), up));
	vec3 b = normalize(cross(up, a));
	float half_e = 0.5 * cell_edge[g];

	uint base = atomicAdd(mesh_count[0], 4u);
	if (base + 4u > params.max_quads * 4u) {
		return;   // the buffers hold no more surface; nothing is written past their end
	}
	uint ibase = atomicAdd(mesh_count[1], 6u);

	for (uint k = 0u; k < 4u; ++k) {
		uint si = k == 0u || k == 3u ? 0u : 1u;   // corners in winding order: --, +-, ++, -+
		uint sj = k < 2u ? 0u : 1u;
		float rc = la_corner_r(g, si, sj, ax0, ax1, r_top, centre);
		vec3 lateral = a * (si == 0u ? -half_e : half_e) + b * (sj == 0u ? -half_e : half_e);
		vec3 v = centre + normalize(p + lateral - centre) * rc;
		uint o = (base + k) * 3u;
		mesh_vert[o] = v.x;
		mesh_vert[o + 1u] = v.y;
		mesh_vert[o + 2u] = v.z;
		// The depth of water under this corner, the cell's own fill, and the cell the quad came from.
		mesh_attr[o] = rc - (length(p - centre) - cell_edge[g]);
		mesh_attr[o + 1u] = clamp(la_liquid(g) / max(params.full_amount, 1.0), 0.0, 1.0);
		mesh_attr[o + 2u] = float(g);
	}
	mesh_index[ibase] = base;
	mesh_index[ibase + 1u] = base + 1u;
	mesh_index[ibase + 2u] = base + 2u;
	mesh_index[ibase + 3u] = base;
	mesh_index[ibase + 4u] = base + 2u;
	mesh_index[ibase + 5u] = base + 3u;
}
