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
//
// CONDENSATION WARMS THE AIR, which until 2026-08-03 it did not — this kernel moved mass and nothing else,
// so water left the atmosphere without ever giving back the heat that lifted it. Paired with an evaporation
// leg that did not cool, the whole water cycle was free on energy. See the LATENT HEAT block below for
// where in this model the release happens and why it has to be here. `Temp` was `readonly`; it is written
// now, in the cell that sheds the rain.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float aw_in[]; };    // post-transport
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };               // WARMED in place by the released condensation enthalpy
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer AirOut { float aw_out[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer Rain { float rain_out[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };    // heat-capacity term only
layout(set = 0, binding = 6, std430) restrict readonly buffer Snow { float snow[]; };      // heat-capacity term only
layout(set = 0, binding = 7, std430) restrict readonly buffer RockFill { float rock_fill[]; };  // heat-capacity term only

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Saturation curve + rain constants — MUST match MaterialField3D.gd's _sat()/derivation.
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_TEMP_REF = 22.0;
// RAIN is the atmosphere's moisture SINK. It was too weak to balance the infinite static-sea evaporation SOURCE,
// so a large reservoir of sub-threshold condensate piled up cell-by-cell and total moisture ran away (cloud deck
// grew without bound → snow-out). Lowered threshold + faster rate so the sink SCALES with load and drains the
// condensate that clouds are made of → atmospheric moisture reaches a STEADY cover instead of climbing forever.
const float RAIN_MASS_THRESHOLD = 0.14;   // start raining once condensate exceeds a thin margin over saturation
const float RAIN_RATE = 0.24;             // fraction of the excess condensate shed as rain per step

// ===== LATENT HEAT OF CONDENSATION =================================================================
// The unit derivation, the enthalpy convention and the areal heat capacities are stated ONCE, in
// atmos_evap_sphere3d.glsl. Read that block; this is the release leg of the absorption that happens there.
//
// WHY THE RELEASE IS BOOKED AT THE RAIN SHED AND NOT AT SATURATION. Phase 2a collapsed vapour/cloud/fog
// into one `moisture` channel whose liquid part is DERIVED at read time (`condensed = max(0, moisture -
// sat(T))`). So there is no stored vapour->liquid transition anywhere in this substrate to hang the
// enthalpy on: a cell's condensate changes every time its temperature does, with no event recorded. The
// ONE explicit, mass-moving vapour->liquid step in the whole model is the line below, where moisture
// leaves the air as rain. Booking L_v there puts the heat in the right CELL (the raining one, where the
// cloud is) and makes the cycle close exactly — every unit that paid L_v on evaporating collects it back
// on leaving the air, whether as rain here or as snow in snowice_sphere3d.
//
// WHAT THIS COSTS, said plainly so nobody reads more into it than is there: the release is lumped at the
// moment of shedding rather than spread over the supersaturation that preceded it, so a cell that hovers
// just under RAIN_MASS_THRESHOLD holds condensate that has not yet warmed anything. The total is right and
// the timing is early-by-nothing/late-by-a-few-steps. Fixing that properly means storing the liquid
// fraction as its own channel, which is a substrate change, not a kernel one.
const float CAP_AIR = 345600.0;      // MUST equal heat3d_solar_sphere3d.glsl:135-138
const float CAP_ROCK = 604800.0;
const float CAP_WATER = 3888000.0;
const float CAP_SNOW = 1080000.0;
const float WATER_SPECIFIC_HEAT = 4184.0;   // LAPhysical.WATER_SPECIFIC_HEAT_J_KGK
const float LATENT_VAP = 2.45e6;            // LAPhysical.LATENT_HEAT_VAPORISATION_J_KG — liquid<->vapour at 20 C
const float H2O_KG_PER_M2_PER_UNIT = CAP_WATER / WATER_SPECIFIC_HEAT;

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
	float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (temp[g] - EVAP_TEMP_REF));
	float condensed = max(0.0, aw - sat);
	float rain = max(0.0, condensed - RAIN_MASS_THRESHOLD) * RAIN_RATE;

	aw_out[g] = aw - rain;
	rain_out[g] = rain;

	// LATENT HEAT RELEASED: the water that just left the air as liquid gives back its vaporisation
	// enthalpy, here, over the same areal heat capacity the energy balance assembles for this cell.
	if (rain > 0.0) {
		float cap = CAP_AIR
			+ CAP_ROCK  * clamp(rock_fill[g], 0.0, 1.0)
			+ CAP_WATER * clamp(water[g], 0.0, 1.0)
			+ CAP_WATER * max(aw, 0.0)          // the suspended water is most of a cloud cell's inertia — see (4)
			+ CAP_SNOW  * max(snow[g], 0.0);    // in atmos_evap_sphere3d for why neither is clamped away
		temp[g] = temp[g] + (rain * H2O_KG_PER_M2_PER_UNIT * LATENT_VAP) / cap;
	}
}
