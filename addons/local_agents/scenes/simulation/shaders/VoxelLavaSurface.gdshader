shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 lava_deep_color : source_color = vec4(0.35, 0.06, 0.02, 1.0);
uniform vec4 lava_hot_color : source_color = vec4(1.0, 0.44, 0.08, 1.0);
uniform float flow_speed : hint_range(0.0, 8.0) = 1.8;
uniform float pulse_strength : hint_range(0.0, 2.0) = 1.0;
uniform float crack_scale : hint_range(0.25, 12.0) = 2.4;
uniform float cooling : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
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

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	vec2 q = p;
	for (int i = 0; i < 4; i++) {
		v += value_noise(q) * a;
		q = q * 2.02 + vec2(6.4, 2.7);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * flow_speed;
	vec2 uv = world_pos.xz * crack_scale;
	float n = fbm(uv + vec2(t * 0.11, -t * 0.08));
	float veins = smoothstep(0.68, 0.94, n + sin((uv.x + uv.y + t) * 2.0) * 0.12);
	float hot = clamp(veins * pulse_strength * (1.0 - cooling), 0.0, 1.0);
	vec3 lava = mix(lava_deep_color.rgb, lava_hot_color.rgb, hot);
	float emit = hot * (2.2 - cooling * 1.5);
	ALBEDO = lava;
	EMISSION = lava * emit;
	ROUGHNESS = mix(0.58, 0.22, hot);
	METALLIC = 0.02;
}
