#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer BaseMoisture { float v[]; } base_moisture;
layout(set = 0, binding = 1, std430) readonly buffer BaseTemp { float v[]; } base_temp;
layout(set = 0, binding = 2, std430) readonly buffer WaterReliability { float v[]; } water_reliability;
layout(set = 0, binding = 3, std430) readonly buffer Elevation { float v[]; } elevation;
layout(set = 0, binding = 4, std430) readonly buffer Slope { float v[]; } slope;
layout(set = 0, binding = 5, std430) restrict buffer Cloud { float v[]; } cloud;
layout(set = 0, binding = 6, std430) restrict buffer Humidity { float v[]; } humidity;
layout(set = 0, binding = 7, std430) restrict buffer Rain { float v[]; } rain;
layout(set = 0, binding = 8, std430) restrict buffer Wetness { float v[]; } wetness;
layout(set = 0, binding = 9, std430) restrict buffer Fog { float v[]; } fog;
layout(set = 0, binding = 10, std430) restrict buffer Orographic { float v[]; } orographic;
layout(set = 0, binding = 11, std430) restrict buffer RainShadow { float v[]; } rain_shadow;
layout(set = 0, binding = 12, std430) readonly buffer Activity { float v[]; } activity;
layout(set = 0, binding = 13, std430) readonly buffer Params {
	float dt;
	float wind_speed;
	float evap_scale;
	float condense_scale;
	float cloud_decay;
	float fog_wind_decay;
	float seed_jitter;
	float tick;
	float idle_cadence;
	float phase_seed;
	float reserved;
	float count;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(params.count)) {
		return;
	}
	float c = clamp(cloud.v[idx], 0.0, 1.0);
	float h = clamp(humidity.v[idx], 0.0, 1.0);
	float w = clamp(wetness.v[idx], 0.0, 1.0);
	float bm = clamp(base_moisture.v[idx], 0.0, 1.0);
	float bt = clamp(base_temp.v[idx], 0.0, 1.0);
	float wr = clamp(water_reliability.v[idx], 0.0, 1.0);
	float elev = clamp(elevation.v[idx], 0.0, 1.0);
	float sl = clamp(slope.v[idx], 0.0, 1.0);
	float act = clamp(activity.v[idx], 0.0, 1.0);
	int idle = max(1, int(round(params.idle_cadence)));
	int cadence = clamp(int(round(mix(float(idle), 1.0, act))), 1, idle);
	int phase = int((uint(idx) * 1664525u + uint(params.phase_seed * 131.0)) % uint(max(1, cadence)));
	if (((int(params.tick) + phase) % cadence) != 0) {
		return;
	}

	float uplift = clamp(sl * 0.35 + elev * 0.16, 0.0, 1.0);
	float cool_air = max(0.0, 0.55 - bt);
	float local_dt = params.dt * float(cadence);
	float evaporation = clamp((0.008 + bt * 0.025 + (1.0 - w) * 0.02) * params.evap_scale * local_dt, 0.003, 0.08);
	float moisture_source = 0.012 + bm * 0.028 + wr * 0.04;
	float condense = max(0.0, c * h * (0.68 + uplift * 0.95) - (0.44 - cool_air * 0.18 - uplift * 0.08));
	condense *= params.condense_scale;
	float sh = clamp(max(0.0, elev * 0.34 - sl * 0.16) * (0.45 + params.wind_speed * 0.35), 0.0, 1.0);
	float r = clamp(condense * (1.05 + cool_air * 0.25) * (1.0 - sh * 0.72), 0.0, 1.0);
	float nh = clamp(h + moisture_source + evaporation - r * 0.19, 0.0, 1.0);
	float nc = clamp(c + nh * 0.06 + uplift * 0.04 - r * 0.16 - params.cloud_decay, 0.0, 1.0);
	float nw = clamp(w * 0.95 + r * 0.52, 0.0, 1.0);
	float nf = clamp(nh * 0.52 + nw * 0.38 + cool_air * 0.22 - params.fog_wind_decay * params.wind_speed, 0.0, 1.0);

	cloud.v[idx] = nc;
	humidity.v[idx] = nh;
	rain.v[idx] = r;
	wetness.v[idx] = nw;
	fog.v[idx] = nf;
	orographic.v[idx] = uplift;
	rain_shadow.v[idx] = sh;
}
