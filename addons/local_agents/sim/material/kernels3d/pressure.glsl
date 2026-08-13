#[compute]
#version 450

// p = nRT of this cell's gas, plus the weight of the condensed column above it.
// One thread per column top walking DOWN once, so each cell's load enters the integral exactly once.

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

const uint MODE_UNWRITTEN = 0u;
const uint MODE_COLUMN = 1u;

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float cell_m;
	float p_top;      // pressure above the outermost cell: vacuum unless something stands there
	uint max_steps;   // walk bound; a column cannot be longer than the grid
	float gas_r;      // LAPhysical.GAS_CONSTANT_J_MOL_K
	float kelvin_0;   // LAPhysical.KELVIN_OFFSET
	uint mode;
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

// The cell one step down from `c`: the neighbour whose OWN up-step lands on `c`. The exact inverse of
// the up-map rather than an assumption about it, so a walk cannot leave the column it started on.
int below_of(uint c) {
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int m = nbr[c * N_SLOTS + d];
		if (m < 0) {
			continue;
		}
		vec3 mu;
		float mg;
		if (!la_up(uint(m), mu, mg)) {
			continue;
		}
		if (la_step(uint(m), mu) == int(c)) {
			return m;
		}
	}
	return -1;
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	if (params.mode == MODE_UNWRITTEN) {
		pressure[gidx] = -1.0;   // a real pressure is never negative, so this reads as "no walk came"
		return;
	}
	vec3 up;
	float gmag;
	bool has_up = la_up(gidx, up, gmag);
	if (has_up && la_step(gidx, up) >= 0) {
		return;   // a cell stands above this one, so it is not a column top
	}
	float acc = params.p_top;
	int c = int(gidx);
	for (uint i = 0u; i < params.max_steps; ++i) {
		uint u = uint(c);
		vec3 cu;
		float cg;
		float w = 0.0;
		if (la_up(u, cu, cg)) {
			w = rho_cond[u] * cg * la_step_len(cu, params.cell_m);
		}
		float t_k = max(temp[u] + params.kelvin_0, 0.0);
		pressure[u] = acc + 0.5 * w + n_gas_m3[u] * params.gas_r * t_k;
		acc += w;
		c = below_of(u);
		if (c < 0) {
			break;
		}
	}
}
