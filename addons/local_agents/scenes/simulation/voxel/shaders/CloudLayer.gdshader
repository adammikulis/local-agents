// CloudLayer — renders a horizontal condensate sheet from the MaterialField's cloud (or fog) density
// grid. The density texture is world-aligned (its cells map 1:1 to field cells), so where the field
// grows clouds/fog, they appear here and drift as the field advects them downwind. An fbm detail
// layer (scrolled by wind) breaks the grid into fluffy shapes; a soft density threshold gives wispy
// edges. Unshaded + a tint uniform driven by the day/night cycle keeps clouds white by day, orange at
// dusk, and dark at night without fighting the lighting.
shader_type spatial;
render_mode cull_disabled, unshaded, blend_mix, depth_draw_opaque, shadows_disabled;

uniform sampler2D density_tex : filter_linear, hint_default_black;
uniform float world_extent = 300.0;    // field half-extent; density uv = (worldXZ + extent)/(2*extent)
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform vec2 wind = vec2(0.0, 0.0);
uniform float detail_scale = 0.03;      // world-space frequency of the fbm detail
uniform float edge_lo = 0.09;           // density where the sheet starts to appear
uniform float edge_hi = 0.45;           // density where it reaches full opacity
uniform float max_alpha = 0.7;

varying vec3 v_world;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		s += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return s;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (v_world.xz + vec2(world_extent)) / (2.0 * world_extent);
	float density = texture(density_tex, uv).r;
	// fbm detail scrolled slowly by the wind; carves the smooth field density into puffs.
	vec2 np = v_world.xz * detail_scale + wind * TIME * 0.015;
	float n = fbm(np);
	float shaped = density * (0.55 + 0.9 * n);
	float a = smoothstep(edge_lo, edge_hi, shaped) * max_alpha;
	// Grazing fade: near the horizon the line of sight skims along this flat sheet, so its alpha would
	// smear into a bright band across the whole horizon. Fade the sheet out where the view grazes it
	// (small |view.y|) and keep it only where we actually look up/down at it.
	vec3 view_dir = normalize(v_world - CAMERA_POSITION_WORLD);
	a *= smoothstep(0.035, 0.22, abs(view_dir.y));
	if (a < 0.003) {
		discard;
	}
	ALBEDO = tint;
	ALPHA = a;
}
