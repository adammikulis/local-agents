#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer Elevation { float v[]; } elevation;
layout(set = 0, binding = 1, std430) readonly buffer Moisture { float v[]; } moisture;
layout(set = 0, binding = 2, std430) readonly buffer Temperature { float v[]; } temperature;
layout(set = 0, binding = 3, std430) readonly buffer Shade { float v[]; } shade;
layout(set = 0, binding = 4, std430) readonly buffer AspectX { float v[]; } aspect_x;
layout(set = 0, binding = 5, std430) readonly buffer AspectY { float v[]; } aspect_y;
layout(set = 0, binding = 6, std430) readonly buffer Albedo { float v[]; } albedo;
layout(set = 0, binding = 7, std430) readonly buffer WeatherCloud { float v[]; } weather_cloud;
layout(set = 0, binding = 8, std430) readonly buffer WeatherFog { float v[]; } weather_fog;
layout(set = 0, binding = 9, std430) readonly buffer WeatherHumidity { float v[]; } weather_humidity;
layout(set = 0, binding = 10, std430) readonly buffer Activity { float v[]; } activity;
layout(set = 0, binding = 11, std430) restrict buffer Sunlight { float v[]; } sunlight;
layout(set = 0, binding = 12, std430) restrict buffer UvIndex { float v[]; } uv_index;
layout(set = 0, binding = 13, std430) restrict buffer HeatLoad { float v[]; } heat_load;
layout(set = 0, binding = 14, std430) restrict buffer Growth { float v[]; } growth;
layout(set = 0, binding = 15, std430) readonly buffer Params {
	float sun_dir_x;
	float sun_dir_y;
	float sun_alt;
	float idle_cadence;
	float tick;
	float seed;
	float reserved;
	float reserved2;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= sunlight.v.length()) {
		return;
	}
	float cloud = clamp(weather_cloud.v[idx], 0.0, 1.0);
	float fog = clamp(weather_fog.v[idx], 0.0, 1.0);
	float humidity = clamp(weather_humidity.v[idx], 0.0, 1.0);
	float moist = clamp(moisture.v[idx], 0.0, 1.0);
	float temp = clamp(temperature.v[idx], 0.0, 1.0);
	float elev = clamp(elevation.v[idx], 0.0, 1.0);
	float sh = clamp(shade.v[idx], 0.0, 1.0);
	float alb = clamp(albedo.v[idx], 0.02, 0.9);
	float act = clamp(activity.v[idx], 0.0, 1.0);
	int idle = max(1, int(round(params.idle_cadence)));
	int cadence = clamp(int(round(mix(float(idle), 1.0, act))), 1, idle);
	int phase = int((uint(idx) * 22695477u + uint(params.seed * 131.0)) % uint(max(1, cadence)));
	if (((int(params.tick) + phase) % cadence) != 0) {
		return;
	}

	vec2 grad = vec2(aspect_x.v[idx], aspect_y.v[idx]);
	float aspect_factor = 1.0;
	if (dot(grad, grad) > 0.00001) {
		vec2 downhill = normalize(-grad);
		vec2 sun_dir = normalize(vec2(params.sun_dir_x, params.sun_dir_y));
		float facing = clamp(dot(downhill, sun_dir), -1.0, 1.0);
		aspect_factor = clamp(0.62 + 0.38 * (facing * 0.5 + 0.5), 0.3, 1.0);
	}

	float cloud_atten = 1.0 - cloud * 0.72;
	float fog_atten = 1.0 - fog * 0.45;
	float direct = params.sun_alt * cloud_atten * fog_atten * (1.0 - sh * 0.75) * aspect_factor;
	float diffuse = (0.18 + cloud * 0.5) * (1.0 - fog * 0.35);
	float insolation = clamp(direct + diffuse * 0.5, 0.0, 1.0);
	float absorbed = insolation * (1.0 - alb);
	float uv = clamp((direct * 1.1 + (1.0 - cloud) * 0.25) * (0.65 + elev * 0.7) * (0.75 + params.sun_alt * 0.5), 0.0, 2.0);
	float heat = clamp(absorbed * (0.78 + (1.0 - cloud) * 0.26) + uv * 0.15 - moist * 0.08, 0.0, 1.5);
	float temp_optimal = 1.0 - clamp(abs(temp - 0.56) * 1.2, 0.0, 1.0);
	float uv_stress = clamp(max(0.0, uv - 1.15) * 0.45, 0.0, 1.0);
	float plant_growth = clamp((absorbed * 0.7 + insolation * 0.3) * (0.35 + moist * 0.65) * temp_optimal * (1.0 - uv_stress), 0.0, 1.0);

	sunlight.v[idx] = insolation;
	uv_index.v[idx] = uv;
	heat_load.v[idx] = heat;
	growth.v[idx] = plant_growth;
}
