shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

#include "res://addons/local_agents/game/render/FieldRamp.gdshaderinc"

// INSTANCE_CUSTOM per glyph: x = magnitude (m/s, or m/s^2), y = stripe phase 0..1,
// z = height over the ground under the glyph (m), w = the glyph's own world length (m).
uniform float v_ref = 1.0;          // magnitude the ramp saturates at, in the source's own unit
uniform float alt_fade_m = 1.0;     // altitude over which a glyph darkens, so a deep stack reads in depth
uniform int stripes = 6;            // stripes along one glyph

varying float v_mag;
varying float v_phase;
varying float v_alt;
varying float v_len;
varying float v_along;

void vertex() {
	v_mag = INSTANCE_CUSTOM.x;
	v_phase = INSTANCE_CUSTOM.y;
	v_alt = INSTANCE_CUSTOM.z;
	v_len = INSTANCE_CUSTOM.w;
	v_along = VERTEX.z;
}

void fragment() {
	// One stripe crosses one stripe-length of shaft per stripe-length/magnitude seconds, so the pattern
	// travels at the cell's own speed and a still glyph is a calm cell.
	float travel = v_mag * TIME / max(v_len, 1.0e-3);
	float s = fract((v_along - travel) * float(stripes) + v_phase);
	// OPAQUE. A stack of translucent glyphs thirty deep composites to a white wash and the world behind
	// it disappears; an opaque one occludes and the lattice reads in depth.
	vec3 col = la_field_ramp(v_mag / max(v_ref, 1.0e-6));
	float depth = mix(1.0, 0.55, clamp(v_alt / max(alt_fade_m, 1.0), 0.0, 1.0));
	ALBEDO = col * mix(0.45, 1.0, step(0.5, s)) * depth;
}
