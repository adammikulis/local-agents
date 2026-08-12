#[compute]
#version 450

#include "neighbours.glsli"

// Pass 1: per radial column, integrate charge density to sigma and test E = sigma/eps0 against the runaway
// threshold. Pass 2: neutralise cells within the stroke's reach, book the energy to temp, stamp DISCHARGE.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 43, std430) restrict buffer Discharge { float discharge[]; };
layout(set = 0, binding = 44, std430) restrict buffer StrikeIdx { uint strike_idx[]; };
layout(set = 0, binding = 45, std430) restrict buffer StrikeArgs { uint strike_args[]; };
layout(set = 0, binding = 46, std430) restrict buffer SigmaCol { float sigma_col[]; };

layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "march.glsli"

layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };

vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}
#include "rc_shared.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint depth;
	uint pass_id;
	float cell_m;        // 0 reset, 1 column scan, 2 neutralise
	float radius_model;  // return-stroke reach, model units
} params;

const float VACUUM_PERMITTIVITY_F_M = 8.8541878128e-12;  // LAPhysical.VACUUM_PERMITTIVITY_F_M
const float RREA_THRESHOLD_V_M = 2.84e5;                 // LAPhysical.RREA_THRESHOLD_V_M
const float AIR_DENSITY_KG_M3 = 1.225;                   // LAPhysical.AIR_DENSITY_KG_M3
const float DRY_AIR_GAS_CONSTANT_J_KGK = 287.0222603;    // LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK
const float KELVIN = 273.15;                             // LAPhysical.KELVIN_OFFSET

vec3 cell_pos(uint c) {
	uint b = c * 3u;
	return vec3(pos[b], pos[b + 1u], pos[b + 2u]);
}

// Field at which a runaway avalanche starts, V/m. Falls with air density, so it is lower aloft.
float threshold_of(uint c) {
	float p = pressure[c];
	if (p <= 0.0) {
		return 0.0;
	}
	float rho = p / (DRY_AIR_GAS_CONSTANT_J_KGK * max(temp[c] + KELVIN, 1.0));
	return RREA_THRESHOLD_V_M * rho / AIR_DENSITY_KG_M3;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	uint depth = max(params.depth, 1u);

	if (params.pass_id == 0u) {
		if (g == 0u) {
			strike_args[0] = 1u;
			strike_args[1] = 1u;
			strike_args[2] = 1u;
			strike_args[3] = 0u;
		}
		return;
	}

	if (params.pass_id == 1u) {
		// Gauss's law along the field line: integrate charge density from this cell outward. The line is
		// -g, not an array stride, so a body that is not a sphere still has columns.
		if (g >= params.cell_count) {
			return;
		}
		float sigma = 0.0;
		uint c = g;
		for (uint step = 0u; step < depth; ++step) {
			if (solid[c] == 0.0) {
				sigma += charge[c] * params.cell_m;
			}
			vec3 gv = g_at(c);
			if (length(gv) <= 0.0) {
				break;
			}
			int nx = la_step(nbr, c, -normalize(gv));
			if (nx < 0) {
				break;
			}
			c = uint(nx);
		}
		sigma_col[g] = sigma;
		if (sigma <= 0.0) {
			return;
		}
		float e_col = sigma / VACUUM_PERMITTIVITY_F_M;
		// The flash starts where the threshold is lowest, i.e. highest in the charged part of the column.
		for (uint r = depth; r > 0u; --r) {
			uint c = base + r - 1u;
			if (solid[c] != 0.0 || charge[c] <= 0.0) {
				continue;
			}
			float eth = threshold_of(c);
			if (eth > 0.0 && e_col >= eth) {
				uint slot = atomicAdd(strike_args[3], 1u);
				if (slot < params.cell_count) {
					strike_idx[slot] = c;
				}
				return;
			}
		}
		return;
	}

	// ---- pass 2: neutralise ------------------------------------------------------------------------
	if (g >= params.cell_count || solid[g] != 0.0 || charge[g] <= 0.0) {
		return;
	}
	uint n = min(strike_args[3], params.cell_count);
	if (n == 0u) {
		return;
	}
	vec3 here = cell_pos(g);
	float r2 = params.radius_model * params.radius_model;
	bool hit = false;
	for (uint i = 0u; i < n; ++i) {
		vec3 d = cell_pos(strike_idx[i]) - here;
		if (dot(d, d) <= r2) {
			hit = true;
			break;
		}
	}
	if (!hit) {
		return;
	}
	float e = sigma_col[g / depth] / VACUUM_PERMITTIVITY_F_M;
	float u = 0.5 * VACUUM_PERMITTIVITY_F_M * e * e;   // J/m^3 the field held here
	charge[g] = 0.0;
	discharge[g] += u;
	temp[g] += u / max(rc_of(g), 1.0);
}
