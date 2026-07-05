// GPU ocean surface for the island sim. ONE camera-following plane at sea level renders the whole sea:
// large summed swells displace the vertices (world-space, so the waves stay put as the plane follows the
// camera), a scrolling normal detail adds ripple sparkle, depth against the scene gives shallow->deep
// colour and an automatic FOAM line where the seabed rises to meet the surface (the beaches). No CA, no
// per-cell mesh — the sea is effectively free. Companion to the freshwater surface in MaterialRender.gd.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, diffuse_burley, depth_draw_always;

uniform vec3 shallow_color : source_color = vec3(0.13, 0.52, 0.60);
uniform vec3 deep_color : source_color = vec3(0.01, 0.13, 0.33);
uniform vec3 sky_tint : source_color = vec3(0.42, 0.62, 0.82);   // colour reflected at grazing angles
uniform vec3 foam_color : source_color = vec3(0.92, 0.96, 0.98);
uniform float depth_fade = 14.0;      // world units of water thickness to reach full deep_color
uniform float foam_depth = 2.2;       // thickness below which shoreline foam appears
uniform float wave_amp = 0.55;        // swell height (world units)
uniform float wave_scale = 0.045;     // swell spatial frequency
uniform float wave_speed = 0.6;
uniform float ripple_strength = 0.35; // fragment normal detail

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world;

// Three crossed directional swells (different angles/frequencies) summed into a height field, so the
// surface reads as rolling ocean rather than a regular grid. Returns height; caller derives the normal.
float swell(vec2 p, float t) {
	float h = 0.0;
	h += sin(dot(p, vec2(1.0, 0.35)) * wave_scale + t * wave_speed) * 1.0;
	h += sin(dot(p, vec2(-0.4, 1.0)) * wave_scale * 1.7 + t * wave_speed * 1.25) * 0.55;
	h += sin(dot(p, vec2(0.7, -0.7)) * wave_scale * 3.1 + t * wave_speed * 0.8) * 0.28;
	return h * wave_amp;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = swell(v_world.xz, TIME);
	VERTEX.y += h;
	// Recompute world pos with the displacement so the fragment shader and depth match the crest.
	v_world.y += h;
}

void fragment() {
	// --- Analytic normal from the swell height gradient (central differences in world XZ). ---
	float e = 1.5;
	float hx = swell(v_world.xz + vec2(e, 0.0), TIME) - swell(v_world.xz - vec2(e, 0.0), TIME);
	float hz = swell(v_world.xz + vec2(0.0, e), TIME) - swell(v_world.xz - vec2(0.0, e), TIME);
	vec3 wn = normalize(vec3(-hx, 2.0 * e, -hz));
	// Fine ripple detail: two scrolling value-noise-ish sine lobes perturbing the normal for sparkle.
	vec2 rp = v_world.xz * 0.35;
	float rx = sin(rp.x * 1.3 + TIME * 1.7) + sin(rp.y * 0.9 - TIME * 1.1);
	float rz = sin(rp.y * 1.4 - TIME * 1.5) + sin(rp.x * 1.1 + TIME * 0.9);
	wn = normalize(wn + vec3(rx, 0.0, rz) * ripple_strength * 0.15);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// --- Water thickness from scene depth: how far below the surface the seabed sits at this pixel. ---
	float scene_d = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, scene_d);
	vec4 view_p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_p.xyz /= view_p.w;
	float scene_view_z = -view_p.z;              // positive distance to the seabed along the view
	float surf_view_z = -VERTEX.z;               // this fragment's own view-space depth
	float thickness = max(scene_view_z - surf_view_z, 0.0);

	// Shallow water shows the sandy bottom tint; deep water goes dark blue.
	float deep_t = clamp(thickness / depth_fade, 0.0, 1.0);
	vec3 col = mix(shallow_color, deep_color, deep_t);

	// Foam where the bottom nearly reaches the surface (shoreline) — animated so it laps the beach.
	float foam_edge = 1.0 - smoothstep(0.0, foam_depth, thickness);
	float foam_wave = 0.5 + 0.5 * sin(v_world.x * 0.5 + v_world.z * 0.5 + TIME * 2.0);
	float foam = clamp(foam_edge * (0.55 + 0.45 * foam_wave), 0.0, 1.0);
	col = mix(col, foam_color, foam);

	// Fresnel: glancing angles reflect the sky (brighter, more opaque); straight down is clearer.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);

	ALBEDO = col;
	ROUGHNESS = mix(0.04, 0.22, deep_t);
	METALLIC = 0.0;
	SPECULAR = 0.75;
	// Clear in the shallows, opaque in the deep and at grazing angles; foam is solid.
	ALPHA = clamp(max(mix(0.55, 0.96, deep_t) + fres * 0.35, foam), 0.0, 1.0);
}
