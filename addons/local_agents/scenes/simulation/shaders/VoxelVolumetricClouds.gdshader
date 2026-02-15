shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_front, unshaded, fog_disabled;

uniform vec3 cloud_tint : source_color = vec3(0.92, 0.95, 1.0);
uniform vec3 storm_tint : source_color = vec3(0.45, 0.5, 0.6);
uniform vec2 atmosphere_flow_dir = vec2(1.0, 0.0);
uniform float atmosphere_flow_speed : hint_range(0.0, 2.0) = 0.5;
uniform float atmosphere_cover : hint_range(0.0, 1.0) = 0.5;
uniform float atmosphere_density : hint_range(0.0, 1.0) = 0.55;
uniform float atmosphere_precipitation : hint_range(0.0, 1.0) = 0.0;
uniform float lightning_flash : hint_range(0.0, 2.0) = 0.0;
uniform float shell_radius : hint_range(32.0, 10000.0) = 400.0;

varying vec3 v_world_pos;

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(n000, n100, f.x);
	float x10 = mix(n010, n110, f.x);
	float x01 = mix(n001, n101, f.x);
	float x11 = mix(n011, n111, f.x);
	float y0 = mix(x00, x10, f.y);
	float y1 = mix(x01, x11, f.y);
	return mix(y0, y1, f.z);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - v_world_pos);
	vec2 wind = normalize(atmosphere_flow_dir);
	float t = TIME * atmosphere_flow_speed * 0.045;
	vec3 p = vec3(v_world_pos.xz * 0.002 + wind * t, (v_world_pos.y / shell_radius) * 3.0);
	float accum = 0.0;
	float weight = 1.0;
	vec3 ray = normalize(vec3(to_camera.x, 0.35 + atmosphere_precipitation * 0.2, to_camera.z));
	vec3 sample_p = p;
	for (int i = 0; i < 10; i++) {
		float n = noise3(sample_p);
		accum += smoothstep(0.45, 0.82, n) * weight;
		weight *= 0.76;
		sample_p += ray * 0.12;
	}
	float density = clamp(accum * 0.35, 0.0, 1.0);
	float cover_gate = smoothstep(0.3, 0.95, atmosphere_cover);
	density *= atmosphere_density * cover_gate;
	vec3 c = mix(storm_tint, cloud_tint, 1.0 - atmosphere_precipitation * 0.65);
	c += cloud_tint * lightning_flash * 0.42;
	ALBEDO = c;
	EMISSION = c * (0.05 + lightning_flash * 0.18);
	ALPHA = density * 0.72;
}
