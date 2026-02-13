shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_opaque;

uniform vec4 base_color : source_color = vec4(0.22, 0.84, 1.0, 1.0);
uniform float pulse_speed : hint_range(0.0, 8.0) = 2.8;
uniform float pulse_width : hint_range(0.05, 1.0) = 0.26;
uniform float pulse_boost : hint_range(0.0, 4.0) = 1.5;
uniform float strength : hint_range(0.0, 1.0) = 0.6;

varying float v_instance_strength;
varying float v_instance_pulse_speed;
varying vec4 v_instance_color;

void vertex() {
	v_instance_strength = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	if (v_instance_strength <= 0.0) {
		v_instance_strength = strength;
	}
	v_instance_pulse_speed = INSTANCE_CUSTOM.y;
	if (v_instance_pulse_speed <= 0.0) {
		v_instance_pulse_speed = pulse_speed;
	}
	v_instance_color = COLOR;
	if (v_instance_color.a <= 0.0) {
		v_instance_color = base_color;
	}
}

void fragment() {
	float phase = fract((UV.y * 1.35) - (TIME * v_instance_pulse_speed));
	float pulse = smoothstep(0.0, pulse_width, phase) * (1.0 - smoothstep(pulse_width, pulse_width * 2.0, phase));
	float glow = 0.35 + pulse * pulse_boost + v_instance_strength * 0.45;
	vec3 col = v_instance_color.rgb * glow;
	ALBEDO = col;
	EMISSION = col * (0.9 + v_instance_strength * 0.8);
	ROUGHNESS = 0.2;
	ALPHA = v_instance_color.a;
}
