#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };          // C/m^3, in place
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CloudIn { float cloud[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelY { float vel_y[]; };    // m/s, outward radial
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;
	uint pad0;
	float pad1;
} params;

const float ZONE_WARM_C = -10.0;                         // LAPhysical.CHARGE_ZONE_WARM_C
const float ZONE_COLD_C = -25.0;                         // LAPhysical.CHARGE_ZONE_COLD_C
const float NIC_CHARGE_RATE_C_M3_S = 1.0e-9;             // LAPhysical.NIC_CHARGE_RATE_C_M3_S
const float CONVECTIVE_UPDRAFT_M_S = 10.0;               // LAPhysical.CONVECTIVE_UPDRAFT_M_S
const float CHARGING_LWC_KG_M3 = 1.0e-3;                 // LAPhysical.CHARGING_LWC_KG_M3
const float WATER_DENSITY_KG_M3 = 997.0;                 // LAPhysical.WATER_DENSITY_KG_M3
const float VACUUM_PERMITTIVITY_F_M = 8.8541878128e-12;  // LAPhysical.VACUUM_PERMITTIVITY_F_M
const float CLOUD_CONDUCTIVITY_S_M = 1.0e-14;            // LAPhysical.CLOUD_CONDUCTIVITY_S_M
const float CLEAR_AIR_CONDUCTIVITY_S_M = 1.0e-13;        // LAPhysical.CLEAR_AIR_CONDUCTIVITY_S_M

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		charge[g] = 0.0;
		return;
	}
	// cloud is a water VOLUME fraction, so liquid water content is that times water's density.
	float wet = clamp(cloud[g] * WATER_DENSITY_KG_M3 / CHARGING_LWC_KG_M3, 0.0, 1.0);
	float rime = clamp((ZONE_WARM_C - temp[g]) / (ZONE_WARM_C - ZONE_COLD_C), 0.0, 1.0);
	float lift = clamp(vel_y[g] / CONVECTIVE_UPDRAFT_M_S, 0.0, 1.0);
	float q = charge[g] + NIC_CHARGE_RATE_C_M3_S * wet * rime * lift * params.dt;

	// Ohmic relaxation, tau = eps0 / sigma. Droplets and ice scavenge the small ions that carry the
	// current, so in-cloud conductivity is an order below clear air.
	float sigma = mix(CLEAR_AIR_CONDUCTIVITY_S_M, CLOUD_CONDUCTIVITY_S_M, wet);
	charge[g] = q * exp(-params.dt * sigma / VACUUM_PERMITTIVITY_F_M);
}
