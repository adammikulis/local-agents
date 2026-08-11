#[compute]
#version 450

#include "neighbours.glsli"

// MaterialReactions3D.gd: FREEZE (liquid water → snow, R21) and MELT (snow → water, R22). The old melt branch
// neighbour (slot 0) is solid ground. That is where FOG (cool near-ground condensate) sits, so cold humid

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Snow { float snow[]; };              // per-cell frozen depth (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };     // settled temp (Thermal back)
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };      // settled moisture (Atmosphere back) — debited
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };      // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Phase-change + saturation constants — MUST match MaterialReactions3D.gd (FREEZE_TEMP) + the atmos kernels (sat curve).
const float FREEZE_TEMP = 0.0;      // LAPhysical.WATER_FREEZE_C — the phase boundary, not a tunable      // water freezes at zero, as it should — see MaterialReactions3D
const float DEPOSIT_FRAC = 0.10;     // fraction of the condensed excess frozen out per step (gradual snowpack build)
const float SNOW_MIN = 1.0e-9;       // clamp numerically-dust-thin snow to 0 (was 1e-3, which is a real 16 mm
                                     // of water equivalent — a threshold in the same units the sky now works
                                     // in would delete an entire season's snowfall as a rounding error)
// The saturation curve, one function — see atmos_precip_sphere3d.glsl's block for what it replaced.
const float MAGNUS_A_PA = 610.94;    // LAPhysical.MAGNUS_A_PA
const float MAGNUS_B = 17.625;       // LAPhysical.MAGNUS_B
const float MAGNUS_C_C = 243.04;     // LAPhysical.MAGNUS_C_C
const float VAPOUR_R = 461.52;       // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float KELVIN_0 = 273.15;       // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;       // LAPhysical.WATER_DENSITY_KG_M3

float sat_mass_frac(float t_c) {
	float t = max(t_c, -80.0);
	float e_sat = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C));
	return (e_sat / (VAPOUR_R * max(t + KELVIN_0, 1.0))) / RHO_WATER;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not a snow surface
	}
	// GROUND-SURFACE air cell: open, and its inward-radial neighbour (slot 0) is solid ground.
	int down = nbr[idx * N_SLOTS + N_IN];
	if (down < 0 || solid[down] == 0.0) {
		return;                                            // no ground directly below -> not a snow surface
	}

	float st = temp[idx];
	if (st < FREEZE_TEMP) {
		// DEPOSITION: freeze the CONDENSED part of the air's water (moisture over saturation) — the fog/low
		// cloud resting on this cold ground — into snow. Conserving: whatever leaves moisture arrives as snow.
		float condensed = max(0.0, moisture[idx] - sat_mass_frac(st));
		if (condensed > 0.0) {
			float x = condensed * DEPOSIT_FRAC;
			moisture[idx] -= x;
			snow[idx] += x;
		}
	}


	if (snow[idx] < SNOW_MIN) {
		moisture[idx] += snow[idx];   // return the dust-thin remnant to the air (CONSERVING) instead of deleting
		snow[idx] = 0.0;              // it — else the conserved water+moisture+snow+soil ledger slowly leaks here
	}
}
