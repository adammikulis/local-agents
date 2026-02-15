shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform vec3 cloud_tint : source_color = vec3(0.92, 0.96, 1.0);
uniform vec3 storm_tint : source_color = vec3(0.46, 0.53, 0.65);
uniform vec2 transform_wind_dir = vec2(1.0, 0.0);
uniform float transform_wind_speed : hint_range(0.0, 2.0) = 0.5;
uniform float transform_coverage : hint_range(0.0, 1.0) = 0.5;
uniform float transform_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_density : hint_range(0.0, 1.0) = 0.55;
uniform float lightning_flash : hint_range(0.0, 2.0) = 0.0;
uniform vec2 world_center_xz = vec2(0.0, 0.0);
uniform float world_span : hint_range(8.0, 10000.0) = 256.0;

varying vec3 v_world_pos;
varying vec4 v_instance_custom;
varying vec4 v_instance_color;

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
	for (int i = 0; i < 4; i++) {
		v += noise21(q) * a;
		q = q * 2.03 + vec2(7.3, 5.1);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_instance_custom = INSTANCE_CUSTOM;
	v_instance_color = COLOR;
}

void fragment() {
	vec2 raw_wind = transform_wind_dir;
	if (dot(raw_wind, raw_wind) <= 0.0001) {
		raw_wind = vec2(1.0, 0.0);
	}
	vec2 wind = normalize(raw_wind);
	float wind_speed = transform_wind_speed;
	float coverage = transform_coverage;
	float intensity = transform_intensity;
	float wind_t = TIME * wind_speed * 0.03;
	vec2 drift = wind * wind_t * (0.8 + v_instance_custom.x * 1.2);
	vec2 uv = (v_world_pos.xz - world_center_xz) / max(world_span, 1.0);
	float n = fbm(uv * 12.0 + drift + vec2(v_instance_custom.x, v_instance_custom.y) * 2.0);
	float detail = fbm(uv * 25.0 - drift * 1.7 + vec2(v_instance_custom.y, v_instance_custom.z) * 1.3);

	float radial = 1.0 - clamp(length(UV * 2.0 - vec2(1.0)), 0.0, 1.0);
	float cover_gate = smoothstep(0.18, 0.92, coverage);
	float density_gate = smoothstep(0.32, 0.86, cloud_density);
	float shape = clamp(n * 0.72 + detail * 0.28, 0.0, 1.0);
	float alpha = radial * smoothstep(0.38, 0.84, shape) * cover_gate * density_gate;
	alpha *= (0.58 + coverage * 0.45) * (0.75 + cloud_density * 0.4);
	alpha *= v_instance_color.a;

	vec3 color = mix(storm_tint, cloud_tint, 1.0 - intensity * 0.7);
	color *= 0.9 + 0.2 * detail;
	color += cloud_tint * lightning_flash * 0.35;
	ALBEDO = color;
	EMISSION = color * (0.06 + lightning_flash * 0.2);
	ALPHA = clamp(alpha, 0.0, 1.0);
}
