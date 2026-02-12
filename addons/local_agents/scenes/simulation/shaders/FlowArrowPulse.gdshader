shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque;

uniform vec4 base_color : source_color = vec4(0.22, 0.84, 1.0, 1.0);
uniform float pulse_speed : hint_range(0.0, 8.0) = 2.8;
uniform float pulse_width : hint_range(0.05, 1.0) = 0.26;
uniform float pulse_boost : hint_range(0.0, 4.0) = 1.5;
uniform float strength : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	float phase = fract((UV.y * 1.35) - (TIME * pulse_speed));
	float pulse = smoothstep(0.0, pulse_width, phase) * (1.0 - smoothstep(pulse_width, pulse_width * 2.0, phase));
	float glow = 0.35 + pulse * pulse_boost + strength * 0.45;
	vec3 col = base_color.rgb * glow;
	ALBEDO = col;
	EMISSION = col * (0.9 + strength * 0.8);
	ROUGHNESS = 0.2;
	ALPHA = base_color.a;
}
