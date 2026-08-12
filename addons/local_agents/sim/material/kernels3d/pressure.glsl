#[compute]
#version 450

// Pressure at every cell. A GAS answers with its equation of state, p = nRT: heat it and it pushes
// harder, so a warm core makes a low and converging wind builds a high. CONDENSED matter is nearly
// incompressible and instead transmits the load, so it adds the weight of the condensed column above.
// The atmosphere's own hydrostatic profile is not added here -- it emerges, because gravity is what
// puts more gas in the cells nearer the ground.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer RhoCond { float rho_cond[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer GasMol { float n_gas_m3[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
#include "march.glsli"
// Solved gravity, flat cell*3, m/s^2.
layout(set = 0, binding = 3, std430) restrict readonly buffer Grav { float g_field[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float cell_m;
	float p_top;      // pressure above the outermost cell: vacuum unless something stands there
	uint max_steps;   // march bound; a column cannot be longer than the grid
	float gas_r;      // LAPhysical.GAS_CONSTANT_J_MOL_K
	float kelvin_0;   // LAPhysical.KELVIN_OFFSET
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
		int nx = la_step(c, up);
		if (nx < 0) {
			break;
		}
		uint n = uint(nx);
		acc += rho_cond[n] * length(g_at(n)) * la_step_len(up, params.cell_m);
		c = n;
	}
	// Half this cell's own condensed weight: the reading is at its centre, not its top face.
	vec3 gh = g_at(gidx);
	acc += 0.5 * rho_cond[gidx] * length(gh) * params.cell_m;
	float t_k = max(temp[gidx] + params.kelvin_0, 0.0);
	pressure[gidx] = acc + n_gas_m3[gidx] * params.gas_r * t_k;
}
