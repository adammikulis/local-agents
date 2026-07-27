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
}
