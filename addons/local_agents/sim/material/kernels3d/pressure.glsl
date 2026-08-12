#[compute]
#version 450

// Pressure at every cell: the weight of everything standing over it.
// p(c) = sum over the column above c of rho * |g| * ds, marched along -g.

#include "march.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Density { float density[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
// Solved gravity, flat cell*3, m/s^2.
layout(set = 0, binding = 3, std430) restrict readonly buffer Grav { float g_field[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float cell_m;
	float p_top;      // pressure above the outermost cell: vacuum unless something stands there
	uint max_steps;   // march bound; a column cannot be longer than the grid
} params;

vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	float acc = params.p_top;
	uint c = gidx;
	for (uint i = 0u; i < params.max_steps; ++i) {
		vec3 gv = g_at(c);
		float gmag = length(gv);
		if (gmag <= 0.0) {
			break;
		}
		vec3 up = -gv / gmag;
		int nx = la_step(nbr, c, up);
		if (nx < 0) {
			break;
		}
		uint n = uint(nx);
		acc += density[n] * length(g_at(n)) * la_step_len(up, params.cell_m);
		c = n;
	}
	// Half this cell's own weight: the reading is at its centre, not its top face.
	vec3 gh = g_at(gidx);
	pressure[gidx] = acc + 0.5 * density[gidx] * length(gh) * params.cell_m;
}
