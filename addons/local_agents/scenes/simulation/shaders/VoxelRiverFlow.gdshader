shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.09, 0.39, 0.71);
uniform vec3 deep_color : source_color = vec3(0.03, 0.14, 0.33);
uniform vec3 foam_color : source_color = vec3(0.85, 0.93, 1.0);
uniform float flow_speed : hint_range(0.0, 4.0) = 1.2;
uniform float wave_scale : hint_range(0.1, 12.0) = 5.0;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow : hint_range(0.0, 1.0) = 0.0;
uniform float lightning_flash : hint_range(0.0, 2.0) = 0.0;

varying float v_strength;
varying vec2 v_dir;

float hash21(vec2 p) {
	p = fract(p * vec2(173.13, 197.77));
	p += dot(p, p + 31.32);
	return fract(p.x * p.y);
}

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	vec2 dir = normalize(vec2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0));
	if (length(dir) < 0.0001) {
		dir = vec2(1.0, 0.0);
	}
	float strength = clamp(c.b, 0.0, 1.0);
	float width = mix(0.35, 0.9, strength);
	float length_scale = mix(0.7, 1.6, strength);
	vec2 local = vec2(VERTEX.x * width, VERTEX.z * length_scale);
	vec2 rz = vec2(
		local.x * dir.x - local.y * dir.y,
		local.x * dir.y + local.y * dir.x
	);
	VERTEX.x = rz.x;
	VERTEX.z = rz.y;
	VERTEX.y += 0.01 + strength * 0.03;
	v_strength = strength;
	v_dir = dir;
}

void fragment() {
	float t = TIME * flow_speed * (0.8 + v_strength * 0.9);
	float wave = sin((UV.y * wave_scale) - t * (2.0 + rain_intensity * 1.6)) * 0.5 + 0.5;
	float streak = hash21(floor(UV * 14.0 + t * v_dir * 2.0));
	float depth_mix = clamp(v_strength * 0.65 + wave * 0.25 + streak * 0.1, 0.0, 1.0);
	vec3 base = mix(deep_color, shallow_color, depth_mix);
	float foam = smoothstep(0.72 - rain_intensity * 0.16, 1.0, wave * v_strength + streak * 0.35);
	vec3 color = mix(base, foam_color, foam * (0.25 + v_strength * 0.6));
	color *= (1.0 - cloud_shadow * 0.28);
	color += foam_color * lightning_flash * 0.35;
	ALBEDO = color;
	ROUGHNESS = 0.08 + (1.0 - depth_mix) * 0.12;
	SPECULAR = 0.9;
	METALLIC = 0.0;
	ALPHA = 0.2 + v_strength * 0.55;
}
