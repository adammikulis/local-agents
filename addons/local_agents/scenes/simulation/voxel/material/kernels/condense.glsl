#[compute]
#version 450

// GPU condensation for the MaterialField atmosphere — a per-cell (no-neighbour) port of the body of
// MaterialAtmosphere.step(): vapor the cool air aloft can't hold CONDENSES to cloud (or, over cool
// surfaces, pools as FOG); sub-saturated air lets cloud/fog RE-EVAPORATE; both decay a little; thick
// cloud RAINS water back to the ground. Reads the POST-TRANSPORT vapor/cloud/fog (separate in buffers)
// plus temp, and writes the final vapor/cloud/fog + rain into water. Constants copied EXACTLY from
// MaterialAtmosphere.gd. Cover means are reduced on the CPU from the downloaded cloud/fog grids; only
// the "did it rain" flag is returned here (atomic), to set the water render-dirty flag.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer VaporIn { float vapor_in[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CloudIn { float cloud_in[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer FogIn { float fog_in[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer VaporOut { float vapor_out[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer CloudOut { float cloud_out[]; };
layout(set = 0, binding = 6, std430) restrict writeonly buffer FogOut { float fog_out[]; };
layout(set = 0, binding = 7, std430) buffer Water { float water[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Sampled { float sampled[]; };
layout(set = 0, binding = 9, std430) buffer Stats { uint rained; } stats;

layout(push_constant, std430) uniform Params {
	float evap_temp_ref;   // LAMaterialField.EVAP_TEMP_REF (22.0)
	uint cell_count;
	uint pad0;
	uint pad1;
} params;

// Constants — MUST match MaterialAtmosphere.gd exactly.
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float CONDENSE_RATE = 0.30;
const float CLOUD_REEVAP_RATE = 0.12;
const float CLOUD_DECAY = 0.006;
const float RAIN_CLOUD_THRESHOLD = 0.45;
const float RAIN_RATE = 0.16;
const float CLOUD_AIR_COOLING = 7.0;
const float FOG_MAX_TEMP = 12.0;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (sampled[idx] == 0.0) {
		// Untouched cells pass through unchanged (mirror the CPU `if sampled == 0: continue`).
		vapor_out[idx] = vapor_in[idx];
		cloud_out[idx] = cloud_in[idx];
		fog_out[idx] = fog_in[idx];
		return;
	}

	float t = temp[idx];
	float vap = vapor_in[idx];
	float new_cloud = cloud_in[idx];
	float new_fog = fog_in[idx];
	float new_vapor;

	float ref = params.evap_temp_ref;
	float sat_surface = SAT_BASE * exp(SAT_TEMP_GAIN * (t - ref));
	float sat_aloft = SAT_BASE * exp(SAT_TEMP_GAIN * ((t - CLOUD_AIR_COOLING) - ref));
	bool cool = t < FOG_MAX_TEMP;

	if (cool && vap > sat_surface) {
		float fcond = (vap - sat_surface) * CONDENSE_RATE;
		new_vapor = vap - fcond;
		new_fog = new_fog + fcond;
	} else {
		float fr = new_fog * CLOUD_REEVAP_RATE;
		new_fog = new_fog - fr;
		vap = vap + fr;
		if (vap > sat_aloft) {
			float ccond = (vap - sat_aloft) * CONDENSE_RATE;
			new_vapor = vap - ccond;
			new_cloud = new_cloud + ccond;
		} else {
			float cr = new_cloud * CLOUD_REEVAP_RATE;
			new_cloud = new_cloud - cr;
			new_vapor = vap + cr;
		}
	}

	new_cloud = new_cloud * (1.0 - CLOUD_DECAY);
	new_fog = new_fog * (1.0 - CLOUD_DECAY);

	if (new_cloud > RAIN_CLOUD_THRESHOLD) {
		float rain = (new_cloud - RAIN_CLOUD_THRESHOLD) * RAIN_RATE;
		new_cloud = new_cloud - rain;
		water[idx] = water[idx] + rain;
		atomicMax(stats.rained, 1u);
	}

	vapor_out[idx] = new_vapor;
	cloud_out[idx] = new_cloud;
	fog_out[idx] = new_fog;
}
