shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.4, 0.4, 0.4, 1.0);
uniform float atmosphere_precipitation : hint_range(0.0, 1.0) = 0.0;
uniform float atmosphere_occlusion : hint_range(0.0, 1.0) = 0.0;
uniform float atmosphere_moisture : hint_range(0.0, 1.0) = 0.0;
uniform float wet_darkening : hint_range(0.0, 0.5) = 0.16;
uniform vec2 atmosphere_flow_dir = vec2(1.0, 0.0);
uniform float atmosphere_flow_speed : hint_range(0.0, 2.0) = 0.5;
uniform float atmosphere_pattern_scale : hint_range(0.002, 0.25) = 0.045;
uniform float atmosphere_occlusion_strength : hint_range(0.0, 1.0) = 0.55;
uniform sampler2D transform_field_tex;
uniform vec2 transform_field_world_size = vec2(1.0, 1.0);
uniform float transform_field_blend : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D surface_field_tex;
uniform vec2 surface_field_world_size = vec2(1.0, 1.0);
uniform float surface_field_blend : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D exposure_field_tex;
uniform vec2 exposure_field_world_size = vec2(1.0, 1.0);
uniform float exposure_field_blend : hint_range(0.0, 1.0) = 1.0;
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
	vec2 transform_uv = clamp(world_pos.xz / max(transform_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 transform_px = texture(transform_field_tex, transform_uv);
	vec2 surface_uv = clamp(world_pos.xz / max(surface_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 surface_px = texture(surface_field_tex, surface_uv);
	vec2 exposure_uv = clamp(world_pos.xz / max(exposure_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 exposure_px = texture(exposure_field_tex, exposure_uv);
	float rain_mix = mix(atmosphere_precipitation, transform_px.g, transform_field_blend);
	float cloud_mix = mix(atmosphere_occlusion, transform_px.r, transform_field_blend);
	float humidity_mix = mix(atmosphere_moisture, transform_px.b, transform_field_blend);
	float wetness = clamp(rain_mix * 0.78 + humidity_mix * 0.22, 0.0, 1.0);
	wetness = mix(wetness, max(wetness, surface_px.r), surface_field_blend);
	float snow = clamp(surface_px.g, 0.0, 1.0) * surface_field_blend;
	float surface_wear = clamp(surface_px.a, 0.0, 1.0) * surface_field_blend;
	float exposure_absorbed = mix(0.5, exposure_px.r, exposure_field_blend);
	float exposure_uv_norm = mix(0.2, exposure_px.g, exposure_field_blend);
	float exposure_heat_norm = mix(0.4, exposure_px.b, exposure_field_blend);
	vec2 wind = normalize(atmosphere_flow_dir);
	vec2 cloud_uv = world_pos.xz * atmosphere_pattern_scale + wind * TIME * atmosphere_flow_speed * 0.06;
	float cloud_mask = smoothstep(0.42, 0.82, fbm(cloud_uv));
	float dynamic_shadow = cloud_mask * atmosphere_occlusion_strength * cloud_mix;
	float shadow = 1.0 - (cloud_mix * 0.16 + dynamic_shadow * 0.42);
	float darken = 1.0 - wetness * wet_darkening;

	float grain = hash31(vec3(UV * 16.0, NORMAL.y * 5.0));
	float micro_variation = mix(0.96, 1.04, grain);
	vec3 color = base_color.rgb * shadow * darken * micro_variation;
	color *= (0.88 + exposure_absorbed * 0.18);
	color += vec3(0.06, 0.045, 0.015) * exposure_heat_norm * 0.22;
	color = mix(color, color * vec3(0.96, 0.97, 1.0), exposure_uv_norm * 0.08);
	color = mix(color, vec3(0.92, 0.95, 0.98), snow * 0.8);
	color = mix(color, color * vec3(0.72, 0.66, 0.62), surface_wear * 0.28);

	ALBEDO = color;
	ROUGHNESS = clamp(0.95 - wetness * 0.58 + snow * 0.12, 0.12, 1.0);
	SPECULAR = clamp(0.24 + wetness * 0.48, 0.0, 1.0);
	METALLIC = 0.0;
}
