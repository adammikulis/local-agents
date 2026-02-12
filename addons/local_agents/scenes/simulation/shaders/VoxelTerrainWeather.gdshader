shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.4, 0.4, 0.4, 1.0);
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow : hint_range(0.0, 1.0) = 0.0;
uniform float humidity : hint_range(0.0, 1.0) = 0.0;
uniform float wet_darkening : hint_range(0.0, 0.5) = 0.16;
uniform vec2 weather_wind_dir = vec2(1.0, 0.0);
uniform float weather_wind_speed : hint_range(0.0, 2.0) = 0.5;
uniform float weather_cloud_scale : hint_range(0.002, 0.25) = 0.045;
uniform float weather_cloud_strength : hint_range(0.0, 1.0) = 0.55;
uniform sampler2D weather_field_tex;
uniform vec2 weather_field_world_size = vec2(1.0, 1.0);
uniform float weather_field_blend : hint_range(0.0, 1.0) = 1.0;
varying vec3 world_pos;

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float hash21(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p + 33.33);
	return fract((p.x + p.y) * p.x);
}

float noise21(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	vec2 q = p;
	for (int i = 0; i < 4; i++) {
		v += noise21(q) * a;
		q = q * 2.02 + vec2(4.7, 9.2);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 weather_uv = clamp(world_pos.xz / max(weather_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 weather_px = texture(weather_field_tex, weather_uv);
	float rain_mix = mix(rain_intensity, weather_px.g, weather_field_blend);
	float cloud_mix = mix(cloud_shadow, weather_px.r, weather_field_blend);
	float humidity_mix = mix(humidity, weather_px.b, weather_field_blend);
	float wetness = clamp(rain_mix * 0.78 + humidity_mix * 0.22, 0.0, 1.0);
	vec2 wind = normalize(weather_wind_dir);
	vec2 cloud_uv = world_pos.xz * weather_cloud_scale + wind * TIME * weather_wind_speed * 0.06;
	float cloud_mask = smoothstep(0.42, 0.82, fbm(cloud_uv));
	float dynamic_shadow = cloud_mask * weather_cloud_strength * cloud_mix;
	float shadow = 1.0 - (cloud_mix * 0.16 + dynamic_shadow * 0.42);
	float darken = 1.0 - wetness * wet_darkening;

	float grain = hash31(vec3(UV * 16.0, NORMAL.y * 5.0));
	float micro_variation = mix(0.96, 1.04, grain);
	vec3 color = base_color.rgb * shadow * darken * micro_variation;

	ALBEDO = color;
	ROUGHNESS = clamp(0.95 - wetness * 0.58, 0.18, 1.0);
	SPECULAR = clamp(0.24 + wetness * 0.48, 0.0, 1.0);
	METALLIC = 0.0;
}
