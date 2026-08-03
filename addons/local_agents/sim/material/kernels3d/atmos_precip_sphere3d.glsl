#[compute]
#version 450

// CUBED-SPHERE atmosphere PRECIPITATION — the condensate SHED of the unified water cycle. With the three
// old atmospheric water channels collapsed into ONE conserved `moisture`, condensation/re-evaporation/
// cloud-decay stop existing as stored steps: cloud/fog are just the suspended-liquid part of moisture,
// `condensed = max(0, moisture - sat(T))`, read instantaneously. This kernel is the ONLY water-cycle sink
// aloft — when the condensed part gets heavy it sheds rain: `rain = max(0, condensed - RAIN_MASS_THRESHOLD)
// * RAIN_RATE`; moisture loses that mass here and the existing atmos_rain_sphere3d gather routes it down
// the radial column to the ground water. Purely per-cell (no neighbour reads); the fall is the gather's job.
//
// sat() curve + constants copied from the (now-deleted) atmos_condense math so behaviour matches.

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
// August-Roche-Magnus (Alduchov & Eskridge 1996) + the ideal gas law, expressed in the field's own unit: the
// fraction of a cell that would be full of liquid water. 1.95e-5 at 22 °C.
//
// WHAT THIS REPLACED: `SAT_BASE = 0.06` — a hand-written saturation mass fraction, 3080x the real value, which
// is single-handedly why this planet kept 30% of its mobile water in the sky against Earth's 0.001%. Its slope
// (SAT_TEMP_GAIN = 0.055/°C) was very nearly right; only the magnitude was invented.
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

	// AUTOCONVERSION (Kessler 1969): the condensed part of the cell's water is cloud droplets, which stay
	// aloft; only the part over the critical cloud-water content coalesces into drops heavy enough to fall.
	// Nothing here caps how much water the air holds — that is the saturation curve's job, and it is why the
	// threshold is now 6.1e-7 (a real 0.5 g/kg of cloud water) rather than 0.14, three times saturation.
	float aw = aw_in[g];
	float condensed = max(0.0, aw - sat_mass_frac(temp[g]));
	float rain = max(0.0, condensed - params.rain_threshold) * params.rain_rate;

	aw_out[g] = aw - rain;
	rain_out[g] = rain;
}
