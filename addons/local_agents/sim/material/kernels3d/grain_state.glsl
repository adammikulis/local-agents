#[compute]
#version 450

// Where a cell's loose mineral grains are: carried by water, carried by air, or on the bed. The three
// shares sum to (1 - melt) * (1 - cement). Derived, never stored.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Silicate { float silicate[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Cement { float cement[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer GrainBuf { float grain[]; };
layout(set = 0, binding = 9, std430) restrict readonly buffer H2OBuf { float h2o[]; };
layout(set = 0, binding = 10, std430) restrict readonly buffer H2OSolidBuf { float h2o_solid[]; };
layout(set = 0, binding = 11, std430) restrict readonly buffer H2OLiquidBuf { float h2o_liquid[]; };
layout(set = 0, binding = 12, std430) restrict readonly buffer MeltBuf { float silicate_melt[]; };

layout(set = 0, binding = 13, std430) restrict writeonly buffer SuspWater { float silicate_susp_water[]; };
layout(set = 0, binding = 14, std430) restrict writeonly buffer SuspAir { float silicate_susp_air[]; };
layout(set = 0, binding = 15, std430) restrict writeonly buffer Bed { float silicate_bed[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float cell_m;
	float grain_seed_m;   // diameter for a cell whose grain field is unset, m
	float rho_grain;      // kg/m^3 of the mineral — LASubstances silicate density
	float rho_water;      // LAPhysical.WATER_DENSITY_KG_M3
	float mu_water;       // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
	float rho_air;        // LAPhysical.AIR_DENSITY_KG_M3
	float mu_air;         // LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S
} params;

const float SMAGORINSKY_COEFF = 0.1650789493;   // LAPhysical.SMAGORINSKY_COEFF

vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

vec3 vel_at(uint c) {
	return vec3(vel_x[c], vel_y[c], vel_z[c]);
}

// |S| = sqrt(2 S_ij S_ij), 1/s, from the resolved velocity gradient.
float strain_rate(uint c) {
	uint base = c * N_SLOTS;
	mat3 grad = mat3(0.0);
	for (uint a = 0u; a < 3u; ++a) {
		uint slot = a * 2u;
		int lo = nbr[base + slot];
		int hi = nbr[base + opposite_slot(slot)];
		vec3 vlo = lo >= 0 ? vel_at(uint(lo)) : vel_at(c);
		vec3 vhi = hi >= 0 ? vel_at(uint(hi)) : vel_at(c);
		vec3 d = (vhi - vlo) / (2.0 * params.cell_m);
		grad[0][a] = d.x;
		grad[1][a] = d.y;
		grad[2][a] = d.z;
	}
	float s2 = 0.0;
	for (uint i = 0u; i < 3u; ++i) {
		for (uint j = 0u; j < 3u; ++j) {
			float sij = 0.5 * (grad[i][j] + grad[j][i]);
			s2 += 2.0 * sij * sij;
		}
	}
	return sqrt(s2);
}

// Share of grains a fluid holds up. u* = sqrt(nu_t |S|) is the friction velocity, which in a boundary
// layer is the scale of the vertical turbulent fluctuations (Bagnold: suspension once u* > w_s).
float suspended_share(uint c, float d, float rho, float mu) {
	float w_s = max(params.rho_grain - rho, 0.0) * length(g_at(c)) * d * d / (18.0 * max(mu, 1.0e-30));
	if (w_s <= 0.0) {
		return 1.0;      // no denser than its fluid, so nothing pulls it out
	}
	float mixing = SMAGORINSKY_COEFF * params.cell_m;
	float nu_t = (rho > 0.0 ? mu / rho : 0.0) + mixing * mixing * strain_rate(c);
	return clamp(sqrt(max(nu_t * strain_rate(c), 0.0)) / w_s, 0.0, 1.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	float loose = (1.0 - clamp(silicate_melt[g], 0.0, 1.0)) * (1.0 - clamp(cement[g], 0.0, 1.0));
	if (loose <= 0.0) {
		silicate_susp_water[g] = 0.0;
		silicate_susp_air[g] = 0.0;
		silicate_bed[g] = 0.0;
		return;
	}
	float amt = max(h2o[g], 0.0);
	float water = amt * clamp(h2o_liquid[g], 0.0, 1.0);
	float condensed = clamp((solid[g] != 0.0 ? 1.0 : 0.0) + max(silicate[g], 0.0)
		+ water + amt * clamp(h2o_solid[g], 0.0, 1.0), 0.0, 1.0);
	float air = 1.0 - condensed;
	float tot = water + air;
	float f_water = tot > 0.0 ? water / tot : 0.0;
	float f_air = tot > 0.0 ? air / tot : 0.0;

	float d = grain[g] > 0.0 ? grain[g] : params.grain_seed_m;
	float in_water = f_water * suspended_share(g, d, params.rho_water, params.mu_water);
	float in_air = f_air * suspended_share(g, d, params.rho_air, params.mu_air);

	silicate_susp_water[g] = loose * in_water;
	silicate_susp_air[g] = loose * in_air;
	silicate_bed[g] = loose * clamp(1.0 - in_water - in_air, 0.0, 1.0);
}
