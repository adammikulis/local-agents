shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// INSTANCE_CUSTOM per piece: x = fade at the piece's low end, y = fade at its high end, both 0..1.
uniform vec3 glow : source_color = vec3(0.30, 0.90, 1.00);

varying float v_fade;

void vertex() {
	v_fade = mix(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, VERTEX.y + 0.5);
}

void fragment() {
	ALBEDO = glow;
	ALPHA = v_fade;
}
