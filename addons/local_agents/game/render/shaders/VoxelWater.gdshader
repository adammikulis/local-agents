// The free surface of the field's liquid water: wind swell and impact rings in the vertex stage, the
// mesh's per-vertex flow (COLOR.rg) and steepness (COLOR.b) in the detail and the whitewater. Swell, rings,
// flow and normals are in the model frame, whose +Y is the local vertical.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, diffuse_burley, depth_draw_always;

#include "res://addons/local_agents/game/render/shaders/generated.gdshaderinc"

// --- Palette: the near-surface and deep-body tints ---
uniform vec3 shallow_tint : source_color = vec3(0.14, 0.50, 0.46);
uniform vec3 deep_tint : source_color = vec3(0.03, 0.24, 0.30);
uniform vec3 sky_tint : source_color = vec3(0.42, 0.62, 0.82);        // reflected at grazing angles
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 0.99);

uniform float depth_fade = 14.0;      // world units of water thickness to reach full deep colour
uniform float foam_depth = 2.2;       // shoreline thickness below which foam appears
uniform float thickness_share : hint_range(0.0, 1.0) = 0.15;  // share of scene thickness in tint and foam
uniform float depth_influence : hint_range(0.0, 1.0) = 0.7;   // share of thickness and Fresnel in opacity
uniform float base_alpha = 0.80;      // opacity floor

// --- Wind swell ---
uniform float wave_amp = 0.9;         // swell height at full wind (world units)
uniform float wave_scale = 0.045;     // swell spatial frequency
uniform float wave_speed = 0.6;
uniform vec2 wind_dir = vec2(1.0, 0.0);      // wind in the model frame's xz, normalized
uniform float wind_strength : hint_range(0.0, 2.0) = 0.4;  // local wind speed, scaled+clamped
uniform float ripple_detail = 0.35;   // fine fragment normal sparkle

// --- Impact ripples (ring buffer, aged on the CPU, uploaded each frame) ---
uniform vec4 ripples[RIPPLE_MAX];     // (model x, model z of the centre, age s, cavity radius m)
uniform int ripple_count = 0;
uniform float ripple_speed;           // ring expansion speed (world units / s); set from RIPPLE_SPEED
uniform float ripple_amp = 0.9;       // crest height per metre of cavity radius
uniform float ripple_freq = 0.9;      // radial wavenumber at the narrowest crest
uniform float ripple_width = 3.2;     // narrowest crest thickness (world units); a wider cavity widens it
uniform float ripple_decay;           // amplitude e-fold time (1/s); set from RIPPLE_DECAY

uniform float flow_speed = 0.9;       // detail scroll along the mesh's flow

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

varying vec3 v_model;     // displaced model-frame position
varying vec2 v_flow;      // model-XZ flow direction for detail scrolling
varying float v_steep;    // mesh slope steepness (whitewater on falls)
varying float v_foam_add; // ripple-crest + whitewater foam accumulated in the vertex stage
varying float v_crest;    // normalized swell crest height (for wind whitecaps)

// Wind swell: three crossed components around the wind direction, amplitude scaled by wind_strength so
// the surface flattens to glass when calm and steepens (choppier, shorter) as the wind rises.
float swell(vec2 p, float t) {
	vec2 d0 = normalize(wind_dir + vec2(1e-4, 0.0));
	vec2 d1 = vec2(-d0.y, d0.x);                       // perpendicular cross-swell
	vec2 d2 = normalize(d0 + d1 * 0.6);
	float amp = wave_amp * wind_strength;
	// Stronger wind = shorter, steeper, choppier waves.
	float freq = wave_scale * (1.0 + 1.6 * clamp(wind_strength, 0.0, 1.6));
	float h = 0.0;
	h += sin(dot(p, d0) * freq + t * wave_speed) * 1.0;
	h += sin(dot(p, d1) * freq * 1.7 + t * wave_speed * 1.25) * 0.5;
	h += sin(dot(p, d2) * freq * 3.1 + t * wave_speed * 0.8) * 0.32;
	return h * amp;
}

// Sum of the active expanding impact rings at model-XZ point p. Also returns (out) the foam contributed
// at ring crests so the caller can whiten the water where a ripple breaks.
float ripple_h(vec2 p, out float foam) {
	float h = 0.0;
	foam = 0.0;
	for (int i = 0; i < RIPPLE_MAX; i++) {
		if (i >= ripple_count) {
			break;
		}
		vec4 r = ripples[i];
		float age = r.z;
		float radius = age * ripple_speed;
		float d = distance(p, r.xy);
		float ring = d - radius;                       // 0 at the expanding crest
		float width = max(ripple_width, r.w);
		float env = exp(-(ring * ring) / (width * width));
		float decay = r.w * exp(-age * ripple_decay) / (1.0 + d * 0.02);
		h += sin(ring * ripple_freq * ripple_width / width) * env * decay * ripple_amp;
		foam += env * decay * 0.5;
	}
	return h;
}

// Combined vertical displacement of the surface at model-XZ p (swell + impact rings).
float water_height(vec2 p, float t, out float ripple_foam) {
	return swell(p, t) + ripple_h(p, ripple_foam);
}

void vertex() {
	v_flow = COLOR.rg * 2.0 - 1.0;
	v_steep = COLOR.b;
	float sh = swell(VERTEX.xz, TIME);
	float rfoam = 0.0;
	float rh = ripple_h(VERTEX.xz, rfoam);
	VERTEX.y += sh + rh;
	v_model = VERTEX;
	// Normalized swell crest (−1..1) so the fragment can foam the tops of steep wind waves (whitecaps).
	v_crest = sh / max(wave_amp * wind_strength, 1e-3);
	// Whitewater on steep falls + foam where an impact ring breaks.
	v_foam_add = clamp(smoothstep(0.35, 0.85, v_steep) * 0.7 + rfoam, 0.0, 1.0);
}

void fragment() {
	// --- Analytic normal from the swell+ripple height gradient (central differences in model XZ). ---
	float e = 1.2;
	float f0;
	float hx = water_height(v_model.xz + vec2(e, 0.0), TIME, f0) - water_height(v_model.xz - vec2(e, 0.0), TIME, f0);
	float hz = water_height(v_model.xz + vec2(0.0, e), TIME, f0) - water_height(v_model.xz - vec2(0.0, e), TIME, f0);
	vec3 wn = normalize(vec3(-hx, 2.0 * e, -hz));
	// Fine sparkle: two scrolling sine lobes, drifting along the mesh's flow.
	vec2 fl = length(v_flow) > 1e-3 ? normalize(v_flow) : vec2(1.0, 0.0);
	vec2 rp = v_model.xz * 0.35 - fl * TIME * flow_speed;
	float rx = sin(rp.x * 1.3 + TIME * 1.7) + sin(rp.y * 0.9 - TIME * 1.1);
	float rz = sin(rp.y * 1.4 - TIME * 1.5) + sin(rp.x * 1.1 + TIME * 0.9);
	wn = normalize(wn + vec3(rx, 0.0, rz) * ripple_detail * 0.15);
	NORMAL = normalize((VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * wn, 0.0)).xyz);

	// --- Water thickness from scene depth (how far below the surface the seabed sits at this pixel). ---
	float scene_d = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, scene_d);
	vec4 view_p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_p.xyz /= view_p.w;
	float thickness = max((-view_p.z) - (-VERTEX.z), 0.0);
	float deep_t = clamp(thickness / depth_fade, 0.0, 1.0) * thickness_share;
	vec3 col = mix(shallow_tint, deep_tint, deep_t);

	// --- Foam: shoreline, impact-ring crests, and whitewater. ---
	float foam_edge = (1.0 - smoothstep(0.0, foam_depth, thickness)) * thickness_share;
	float foam_wave = 0.5 + 0.5 * sin(v_model.x * 0.5 + v_model.z * 0.5 + TIME * 2.0);
	float shore_foam = foam_edge * (0.55 + 0.45 * foam_wave) * 0.5;
	// Wind whitecaps: the tops of steep swell break into foam as the wind rises.
	float whitecap = smoothstep(0.55, 1.0, v_crest) * smoothstep(0.5, 1.2, wind_strength);
	float foam = clamp(max(max(shore_foam, v_foam_add), whitecap), 0.0, 1.0);
	col = mix(col, foam_color, foam);

	// Fresnel sky sheen at grazing angles.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
	col = mix(col, sky_tint, fres * 0.25);

	ALBEDO = col;
	ROUGHNESS = mix(0.05, 0.24, deep_t);
	METALLIC = 0.0;
	SPECULAR = 0.75;
	float body_alpha = mix(base_alpha, mix(0.55, 0.96, deep_t) + fres * 0.35, depth_influence);
	ALPHA = clamp(max(body_alpha - 0.12, foam), 0.0, 1.0);
}
