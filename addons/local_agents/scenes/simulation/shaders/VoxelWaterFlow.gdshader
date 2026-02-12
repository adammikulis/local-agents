shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.16, 0.53, 0.84, 0.62);
uniform vec4 deep_color : source_color = vec4(0.03, 0.16, 0.43, 0.72);
uniform vec3 foam_color : source_color = vec3(0.84, 0.94, 1.0);
uniform vec2 flow_dir = vec2(1.0, 0.25);
uniform float flow_speed : hint_range(0.0, 4.0) = 0.9;
uniform float noise_scale : hint_range(0.05, 4.0) = 0.45;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.34;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.28;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 456.21));
	p += dot(p, p + 34.45);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	vec2 dir = normalize(flow_dir);
	float t = TIME * flow_speed;
	vec2 uv = UV * (noise_scale * 3.0);
	float n1 = value_noise(uv + dir * t);
	float n2 = value_noise((uv * 1.9) - dir.yx * t * 0.73);
	float n = clamp((n1 * 0.68) + (n2 * 0.32), 0.0, 1.0);
	float wave = sin((UV.x + UV.y) * 7.0 + t * 4.2) * 0.5 + 0.5;
	float depth_blend = clamp(n * 0.8 + wave * 0.2, 0.0, 1.0);
	vec3 color = mix(deep_color.rgb, shallow_color.rgb, depth_blend);
	float foam = smoothstep(0.74, 1.0, n + wave * wave_strength);
	color = mix(color, foam_color, foam * foam_strength);
	float fresnel = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), 2.6);

	ALBEDO = color;
	EMISSION = color * (0.06 + 0.1 * fresnel);
	ROUGHNESS = 0.09 + (1.0 - n) * 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.85;
	ALPHA = mix(deep_color.a, shallow_color.a, depth_blend) + fresnel * 0.12;
}
