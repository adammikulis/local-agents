#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float aw_in[]; };    // post-transport
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer AirOut { float aw_out[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer Rain { float rain_out[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float rain_threshold;   // Kessler q_crit in cell-fill units — DERIVED in AtmospherePass.rain_threshold()
	float rain_rate;        // Kessler k_auto x real seconds per step — AtmospherePass.rain_rate_per_step()
	uint pad2;
} params;

// --- THE SATURATION CURVE IS THE PHASE RULE, AND IT IS ONE FUNCTION -----------------------------------------
const float MAGNUS_A_PA = 610.94;        // LAPhysical.MAGNUS_A_PA
const float MAGNUS_B = 17.625;           // LAPhysical.MAGNUS_B
const float MAGNUS_C_C = 243.04;         // LAPhysical.MAGNUS_C_C
const float VAPOUR_R = 461.52;           // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float KELVIN_0 = 273.15;           // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;           // LAPhysical.WATER_DENSITY_KG_M3

float sat_mass_frac(float t_c) {
	float t = max(t_c, -80.0);
	float e_sat = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C));
	return (e_sat / (VAPOUR_R * max(t + KELVIN_0, 1.0))) / RHO_WATER;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}

	if (solid[g] != 0.0) {
		aw_out[g] = aw_in[g];
		rain_out[g] = 0.0;
		return;
	}

	float aw = aw_in[g];
	float condensed = max(0.0, aw - sat_mass_frac(temp[g]));
	float rain = max(0.0, condensed - params.rain_threshold) * params.rain_rate;

	aw_out[g] = aw - rain;
	rain_out[g] = rain;
}
