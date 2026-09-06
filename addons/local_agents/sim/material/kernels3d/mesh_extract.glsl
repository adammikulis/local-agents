#[compute]
#version 450

#include "bindings.glsli"

// THE FREE SURFACE OF THE FIELD'S LIQUID, AS A MESH: a detector the renderer receives and the field
// never reads. One vertex per surface cell, joined by index, so two cells cannot put one point in two
// places. Where a neighbour carries no surface the sheet ends, and that edge is the shoreline.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Nbr { int nbr[]; };
layout(set = 0, binding = LA_BIND_POS, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = LA_BIND_CELL_EDGE, std430) restrict readonly buffer CellEdge { float cell_edge[]; };
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict readonly buffer VertUp { int vert_up[]; };
layout(set = 0, binding = LA_BIND_VERT_DOWN, std430) restrict readonly buffer VertDown { int vert_down[]; };
layout(set = 0, binding = LA_BIND_GROUND_D, std430) restrict readonly buffer GroundD { float ground_d[]; };
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = LA_BIND_H2O, std430) restrict readonly buffer H2O { float h2o[]; };
layout(set = 0, binding = LA_BIND_H2O_LIQUID, std430) restrict readonly buffer H2OLiquid { float h2o_liquid[]; };

// 0 vertices claimed, 1 indices claimed.
layout(set = 0, binding = LA_BIND_MESH_COUNT, std430) restrict buffer MeshCount { uint mesh_count[]; };
layout(set = 0, binding = LA_BIND_MESH_SLOT, std430) restrict buffer MeshSlot { int mesh_slot[]; };
layout(set = 0, binding = LA_BIND_MESH_VERT, std430) restrict writeonly buffer MeshVert { float mesh_vert[]; };
layout(set = 0, binding = LA_BIND_MESH_ATTR, std430) restrict writeonly buffer MeshAttr { float mesh_attr[]; };
layout(set = 0, binding = LA_BIND_MESH_INDEX, std430) restrict writeonly buffer MeshIndex { uint mesh_index[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float centre_x;      // the body centre every radius here is measured from
	float centre_y;
	float centre_z;
	float full_amount;   // mol/m^3 of a cell full of liquid
	uint max_verts;      // vertices the buffers hold
	float r_step_m;      // one float32 step at this body's radius: the resolution every height here has
	uint mode;           // 0 place the vertices, 1 clear, 2 join them
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

// Cells a column walk climbs before it gives up on finding that column's own free surface.
const uint LA_COLUMN_MARCH = 64u;

// THE FREE SURFACE OF THE COLUMN `n` STANDS IN. A sheet is a height field, so the neighbour that joins it
// is the surface of the column beside this one, which need not be the cell beside this one.
int la_column_surface(int n) {
	if (n < 0 || uint(n) >= params.cell_count) {
		return -1;
	}
	int at = n;
	for (uint k = 0u; k < LA_COLUMN_MARCH; ++k) {
		if (mesh_slot[uint(at)] >= 0) {
			return at;
		}
		int u = vert_up[at];
		if (u < 0 || uint(u) >= params.cell_count) {
			break;
		}
		at = u;
	}
	at = vert_down[n];
	for (uint k = 0u; k < LA_COLUMN_MARCH; ++k) {
		if (at < 0 || uint(at) >= params.cell_count) {
			break;
		}
		if (mesh_slot[uint(at)] >= 0) {
			return at;
		}
		at = vert_down[at];
	}
	return -1;
}

// The axis a cell's own radial leans on hardest; the other two are its lateral pair.
uint la_vert_axis(vec3 up) {
	return abs(up.x) >= abs(up.y) && abs(up.x) >= abs(up.z) ? 0u
			: (abs(up.y) >= abs(up.z) ? 1u : 2u);
}

vec3 la_axis_vec(uint i) {
	return vec3(i == 0u ? 1.0 : 0.0, i == 1u ? 1.0 : 0.0, i == 2u ? 1.0 : 0.0);
}

// Lateral columns one cell can stand beside: four slots, and four fine ones across a coarse face.
#define LA_RING_MAX 16

// Three claimed slots as one triangle of the sheet.
void la_triangle(uint v0, uint v1, uint v2) {
	uint ibase = atomicAdd(mesh_count[1], 3u);
	if (ibase + 3u > params.max_verts * 3u * uint(LA_RING_MAX - 1)) {
		return;
	}
	mesh_index[ibase] = v0;
	mesh_index[ibase + 1u] = v1;
	mesh_index[ibase + 2u] = v2;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (params.mode == 1u) {
		if (g < 4u) {
			mesh_count[g] = 0u;
		}
		if (g < params.cell_count) {
			mesh_slot[g] = -1;
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

	if (params.mode == 0u) {
		uint slot = atomicAdd(mesh_count[0], 1u);
		if (slot >= params.max_verts) {
			return;   // the buffers hold no more surface; nothing is written past their end
		}
		mesh_slot[g] = int(slot);
		vec3 v = centre + up * r_top;
		mesh_vert[slot * 3u] = v.x;
		mesh_vert[slot * 3u + 1u] = v.y;
		mesh_vert[slot * 3u + 2u] = v.z;
		// The depth of water under this vertex, the cell's own fill, and the cell it came from.
		mesh_attr[slot * 3u] = r_top - (length(p - centre) - ground_d[g]);
		mesh_attr[slot * 3u + 1u] = clamp(la_liquid(g) / max(params.full_amount, 1.0), 0.0, 1.0);
		mesh_attr[slot * 3u + 2u] = float(g);
		return;
	}

	// THE UMBRELLA AROUND THIS VERTEX: every lateral column carrying a surface, in the order they stand
	// around it, fanned from this cell. A coarse cell meets four fine ones on a slot and joins all four,
	// so the sheet closes across a 2:1 boundary instead of opening along it.
	int mine = mesh_slot[g];
	if (mine < 0) {
		return;
	}
	uint v_axis = la_vert_axis(up);
	uint ax0 = (v_axis + 1u) % 3u;
	uint ax1 = (v_axis + 2u) % 3u;
	vec3 ea = la_axis_vec(ax0);
	vec3 eb = la_axis_vec(ax1);
	if (dot(cross(ea, eb), up) < 0.0) {
		eb = -eb;   // a right-handed pair about the cell's own vertical, so the ring runs one way round
	}
	int ring[LA_RING_MAX];
	float ang[LA_RING_MAX];
	uint m = 0u;
	for (uint axis = 0u; axis < 2u && m < uint(LA_RING_MAX); ++axis) {
		uint ax = axis == 0u ? ax0 : ax1;
		for (uint h = 0u; h < 2u && m < uint(LA_RING_MAX); ++h) {
			uint d = ax * 2u + h;
			for (uint f = la_slot_lo(g, d); f < la_slot_hi(g, d) && m < uint(LA_RING_MAX); ++f) {
				int s = la_column_surface(nbr[f]);
				if (s < 0 || s == int(g)) {
					continue;
				}
				bool seen = false;
				for (uint k = 0u; k < m; ++k) {
					seen = seen || ring[k] == s;
				}
				if (seen) {
					continue;
				}
				vec3 rel = la_pos(uint(s)) - p;
				ring[m] = s;
				ang[m] = atan(dot(rel, eb), dot(rel, ea));
				m += 1u;
			}
		}
	}
	if (m < 2u) {
		return;
	}
	for (uint i = 1u; i < m; ++i) {
		for (uint j = i; j > 0u && ang[j - 1u] > ang[j]; --j) {
			float ta = ang[j - 1u];
			ang[j - 1u] = ang[j];
			ang[j] = ta;
			int ti = ring[j - 1u];
			ring[j - 1u] = ring[j];
			ring[j] = ti;
		}
	}
	for (uint i = 0u; i + 1u < m; ++i) {
		la_triangle(uint(mine), uint(mesh_slot[uint(ring[i])]), uint(mesh_slot[uint(ring[i + 1u])]));
	}
}
