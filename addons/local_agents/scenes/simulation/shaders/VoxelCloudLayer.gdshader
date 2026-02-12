shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform vec3 cloud_tint : source_color = vec3(0.93, 0.96, 1.0);
uniform vec3 sky_tint : source_color = vec3(0.42, 0.56, 0.78);
uniform vec2 weather_wind_dir = vec2(1.0, 0.0);
uniform float weather_wind_speed : hint_range(0.0, 2.0) = 0.5;
uniform float weather_cloud_scale : hint_range(0.001, 0.1) = 0.02;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_density : hint_range(0.0, 1.0) = 0.55;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float layer_variation : hint_range(0.0, 1.0) = 0.4;
uniform sampler2D weather_field_tex;
uniform vec2 weather_field_world_size = vec2(1.0, 1.0);
uniform float weather_field_blend : hint_range(0.0, 1.0) = 1.0;
varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 456.21));
	p += dot(p, p + 34.45);
	return fract(p.x * p.y);
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
	for (int i = 0; i < 5; i++) {
		v += noise21(q) * a;
		q = q * 2.01 + vec2(7.3, 5.1);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 weather_uv_px = clamp(world_pos.xz / max(weather_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 weather_px = texture(weather_field_tex, weather_uv_px);
	float cover_mix = mix(cloud_cover, weather_px.r, weather_field_blend);
	float rain_mix = mix(rain_intensity, weather_px.g, weather_field_blend);
	float humidity_mix = mix(cloud_density, weather_px.b, weather_field_blend);
	vec2 wind = normalize(weather_wind_dir);
	vec2 base_uv = world_pos.xz * weather_cloud_scale;
	float advect = TIME * weather_wind_speed * 0.05;
	float n0 = fbm(base_uv + wind * advect);
	float n1 = fbm(base_uv * 1.67 - wind.yx * advect * (0.55 + layer_variation * 0.45));
	float shape = clamp(n0 * 0.64 + n1 * 0.36, 0.0, 1.0);

	float cover_threshold = mix(0.78, 0.34, cover_mix);
	float cloud_mask = smoothstep(cover_threshold - 0.08, cover_threshold + 0.15, shape);
	float density = clamp(cloud_mask * humidity_mix * (0.75 + rain_mix * 0.25), 0.0, 1.0);

	vec3 color = mix(sky_tint, cloud_tint, cloud_mask);
	color *= 0.92 + 0.08 * n1;
	ALBEDO = color;
	EMISSION = color * 0.1;
	ALPHA = density * (0.58 + cover_mix * 0.32);
}
