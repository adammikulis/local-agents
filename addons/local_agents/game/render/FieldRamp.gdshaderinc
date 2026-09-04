// Perceptual magnitude ramp, 0..1 -> colour. Included by the arrow glyphs AND by the HUD legend bar, so
// the picture and the key it is read against are one declaration.
vec3 la_field_ramp(float t) {
	float u = clamp(t, 0.0, 1.0);
	vec3 c = mix(vec3(0.16, 0.20, 0.34), vec3(0.12, 0.52, 0.72), smoothstep(0.0, 0.25, u));
	c = mix(c, vec3(0.24, 0.76, 0.44), smoothstep(0.25, 0.50, u));
	c = mix(c, vec3(0.92, 0.80, 0.22), smoothstep(0.50, 0.78, u));
	return mix(c, vec3(0.90, 0.24, 0.18), smoothstep(0.78, 1.0, u));
}
