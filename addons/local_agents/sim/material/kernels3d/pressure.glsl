#[compute]
#version 450

#include "bindings.glsli"

// LITHOSTATIC PRESSURE, SOLID CELLS ONLY: the weight per unit area standing over the cell. An open
// cell's pressure is state_derive.glsl's; touching one here makes two writers disagree about it.
// LA_APPROX: quasi_static_solid_pressure

#include "cellvol.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_PRESSURE, std430) restrict buffer Pressure { float pressure[]; };
layout(set = 0, binding = LA_BIND_RHO_BULK, std430) restrict readonly buffer RhoBulk { float rho_bulk[]; };
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity, flat cell*3, m/s^2.
layout(set = 0, binding = LA_BIND_G_REST, std430) restrict readonly buffer Grav { float g_field[]; };
// GravityPass's one vertical relation; marching it is what makes the column monotone.
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict readonly buffer VertUp { int vert_up[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float p_top;      // pressure above the outermost cell: vacuum unless something stands there
	uint max_steps;   // walk bound: a staircase takes at most one step per cell on each axis
} params;

vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

// Up at `c` and gravity's magnitude there; false where gravity vanishes and neither exists.
bool la_up(uint c, out vec3 up, out float gmag) {
	vec3 gv = g_at(c);
	gmag = length(gv);
	if (gmag <= 0.0) {
		up = vec3(0.0);
		return false;
	}
	up = -gv / gmag;
	return true;
}

// Weight per unit area of the matter in `c`, Pa: dp/dz = rho g over the step's projection on the vertical.
float la_load(uint c) {
	vec3 up;
	float gmag;
	if (!la_up(c, up, gmag)) {
		return 0.0;
	}
	float m = max(max(abs(up.x), abs(up.y)), abs(up.z));
	return rho_bulk[c] * gmag * cell_edge[c] * m;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	// Rock only. state_derive.glsl owns every open cell.
	if (solid[g] == 0.0) {
		return;
	}
	// Half this cell's own load: the integral evaluated at the cell centre.
	float acc = 0.5 * la_load(g);
	float top = params.p_top;
	int a = vert_up[g];
	for (uint i = 0u; i < params.max_steps && a >= 0; ++i) {
		// Rock stands under whatever fluid is on it: the first open cell ends the march at its pressure.
		if (solid[uint(a)] == 0.0) {
			top = pressure[uint(a)];
			break;
		}
		acc += la_load(uint(a));
		a = vert_up[uint(a)];
	}
	pressure[g] = top + acc;
}
