// ONE unified water shader for the whole sim — the open sea (LAOceanPlane) AND every freshwater body
// (lakes/rivers/streams/floods/cave pools, the CA surface mesh in MaterialFieldRender3D) render with
// THIS shader. There is no fresh-vs-salt shader split: a single `salinity` uniform (0 fresh → 1 salt)
// CONTINUOUSLY drives colour (fresh = clearer teal/green, salt = deeper murkier blue), foam amount and
// opacity, so fresh ↔ brackish ↔ salt is one continuous look and a river blends into the sea seamlessly.
//
// The surface is GPU-reactive with NO CPU CA:
//   • wind-driven swell — crossed Gerstner/sine waves in the vertex stage, amplitude+choppiness scaled
//     by `wind_strength` and aimed along `wind_dir` (calm sea when wind is low, choppy in a storm);
//   • transient impact ripples — a ring buffer of up to RIPPLE_MAX expanding radial waves
//     (`ripples[i] = (centre.x, centre.z, age_seconds, strength)`) summed into the displacement + a foam
//     ring at each crest, so a meteor / tornado / lightning splash ripples the sea for free.
// The CA freshwater mesh feeds a per-vertex FLOW direction (vertex COLOR.rg) + steepness (COLOR.b) so a
// stream scrolls its detail downhill and a waterfall face reads as fast whitewater — falls emerge from
// the mesh geometry, not a special pass. Differences between the sea and a pond are all UNIFORMS
// (salinity / wind / depth_influence / flow_scale), never an identity branch.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, diffuse_burley, depth_draw_always;

const int RIPPLE_MAX = 16;

// --- Salinity-driven palette (0 fresh → 1 salt). shallow/deep are the near-surface + deep-body tints. ---
uniform vec3 fresh_shallow : source_color = vec3(0.14, 0.50, 0.46);   // clear green-teal river shallows
uniform vec3 fresh_deep : source_color = vec3(0.03, 0.24, 0.30);      // fresh pool depth
uniform vec3 salt_shallow : source_color = vec3(0.10, 0.46, 0.58);    // turquoise sea shallows
uniform vec3 salt_deep : source_color = vec3(0.01, 0.11, 0.30);       // deep ocean blue
uniform vec3 sky_tint : source_color = vec3(0.42, 0.62, 0.82);        // reflected at grazing angles
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 0.99);
uniform float salinity : hint_range(0.0, 1.0) = 1.0;                  // ocean sets ~1, CA fresh water ~0
uniform float salinity_from_vertex : hint_range(0.0, 1.0) = 0.0;     // 1 = take salinity per-vertex from COLOR.a (unified sea+lake mesh)

uniform float depth_fade = 14.0;      // world units of water thickness to reach full deep colour
uniform float foam_depth = 2.2;       // shoreline thickness below which foam appears
uniform float depth_influence : hint_range(0.0, 1.0) = 1.0;  // 1 = deep body (sea); ~0.15 = thin CA sheet
uniform float base_alpha = 0.80;      // opacity floor for thin sheets (depth_influence low)

// --- Wind swell ---
uniform float wave_amp = 0.9;         // swell height at full wind (world units)
uniform float wave_scale = 0.045;     // swell spatial frequency
uniform float wave_speed = 0.6;
uniform vec2 wind_dir = vec2(1.0, 0.0);      // set from field.wind() (normalized)
uniform float wind_strength : hint_range(0.0, 2.0) = 0.4;  // field.wind() magnitude, scaled+clamped
uniform float ripple_detail = 0.35;   // fine fragment normal sparkle

// --- Impact ripples (ring buffer, aged on the CPU, uploaded each frame) ---
uniform vec4 ripples[RIPPLE_MAX];     // (centre.x, centre.z, age_seconds, strength)
uniform int ripple_count = 0;
uniform float ripple_speed = 9.0;     // ring expansion speed (world units / s)
uniform float ripple_amp = 0.9;       // crest height per unit strength
uniform float ripple_freq = 0.9;      // radial wavenumber
uniform float ripple_width = 3.2;     // crest thickness (world units)
uniform float ripple_decay = 0.7;     // amplitude e-fold time (1/s)

// --- CA flow (freshwater mesh only; ocean leaves flow_scale = 0) ---
uniform float flow_scale : hint_range(0.0, 1.0) = 0.0;   // 1 = use vertex COLOR flow, 0 = world scroll
uniform float flow_speed = 0.9;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

// --- EMERGENT SEA ICE (near-cap leg): whiten the SALT sea where the field froze it, matching the ocean shell so
// descending onto a frozen pole shows continuous white ice (not a blue near-cap under a white shell). Fed the
// SAME cube-face coverage texture as VoxelWaterSphere by LASeaIceShaderController; sampled by the surface radial
// (mesh origin = planet centre). Off (sea_ice_enabled=0) on the flat island and for all freshwater. ---
uniform sampler2DArray sea_ice_tex : filter_linear;
uniform float sea_ice_enabled = 0.0;
uniform vec3 sea_ice_color : source_color = vec3(0.90, 0.94, 0.97);
uniform float sea_ice_edge = 0.06;
const vec3 ICE_FACE_N[6] = vec3[6](vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0));
const vec3 ICE_FACE_R[6] = vec3[6](vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0));
const vec3 ICE_FACE_U[6] = vec3[6](vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0));

float sea_ice_at(vec3 dir) {
	vec3 a = abs(dir);
	int f = (a.x >= a.y && a.x >= a.z) ? (dir.x >= 0.0 ? 0 : 1) : ((a.y >= a.z) ? (dir.y >= 0.0 ? 2 : 3) : (dir.z >= 0.0 ? 4 : 5));
	float denom = dot(dir, ICE_FACE_N[f]);
	if (denom < 0.0001) { return 0.0; }
	vec3 p = dir / denom;
	float u = clamp((dot(p, ICE_FACE_R[f]) + 1.0) * 0.5, 0.0, 0.99999);
	float v = clamp((dot(p, ICE_FACE_U[f]) + 1.0) * 0.5, 0.0, 0.99999);
	return textureLod(sea_ice_tex, vec3(u, v, float(f)), 0.0).r;
}

varying vec3 v_world;
varying vec2 v_flow;      // world-XZ flow direction for detail scrolling
varying float v_steep;    // CA slope steepness (whitewater on falls)
varying float v_foam_add; // ripple-crest + whitewater foam accumulated in the vertex stage
varying float v_crest;    // normalized swell crest height (for wind whitecaps)
varying float v_salinity; // PER-VERTEX salinity (COLOR.a): sea=1 salt, lake/river=0 fresh — one seamless surface

// Wind swell: three crossed components around the wind direction, amplitude scaled by wind_strength so
// the sea flattens to glass when calm and steepens (choppier, shorter) as the wind rises.
float swell(vec2 p, float t) {
	vec2 d0 = normalize(wind_dir + vec2(1e-4, 0.0));
	vec2 d1 = vec2(-d0.y, d0.x);                       // perpendicular cross-swell
	vec2 d2 = normalize(d0 + d1 * 0.6);
	float amp = wave_amp * wind_strength;
	// Stronger wind = shorter, steeper, choppier waves (a storm sea, not a long ground swell).
	float freq = wave_scale * (1.0 + 1.6 * clamp(wind_strength, 0.0, 1.6));
	float h = 0.0;
	h += sin(dot(p, d0) * freq + t * wave_speed) * 1.0;
	h += sin(dot(p, d1) * freq * 1.7 + t * wave_speed * 1.25) * 0.5;
	h += sin(dot(p, d2) * freq * 3.1 + t * wave_speed * 0.8) * 0.32;
	return h * amp;
}

// Sum of the active expanding impact rings at world-XZ point p. Also returns (out) the foam contributed
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
		float env = exp(-(ring * ring) / (ripple_width * ripple_width));
		float decay = r.w * exp(-age * ripple_decay) / (1.0 + d * 0.02);
		h += sin(ring * ripple_freq) * env * decay * ripple_amp;
		foam += env * decay * 0.5;
	}
	return h;
}

// Combined vertical displacement of the surface at world-XZ p (swell + impact rings).
float water_height(vec2 p, float t, out float ripple_foam) {
	return swell(p, t) + ripple_h(p, ripple_foam);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_flow = mix(vec2(0.35, 0.20), (COLOR.rg * 2.0 - 1.0), flow_scale);  // CA: signed flow; sea: gentle scroll
	v_steep = COLOR.b * flow_scale;
	v_salinity = mix(salinity, COLOR.a, salinity_from_vertex);   // per-vertex salt/fresh when driven by the mesh
	float sh = swell(v_world.xz, TIME);
	float rfoam = 0.0;
	float rh = ripple_h(v_world.xz, rfoam);
	float h = sh + rh;
	VERTEX.y += h;
	v_world.y += h;
	// Normalized swell crest (−1..1) so the fragment can foam the tops of steep wind waves (whitecaps).
	v_crest = sh / max(wave_amp * wind_strength, 1e-3);
	// Whitewater on steep CA falls + foam where an impact ring breaks.
	v_foam_add = clamp(smoothstep(0.35, 0.85, v_steep) * 0.7 + rfoam, 0.0, 1.0);
}

void fragment() {
	// --- Analytic normal from the swell+ripple height gradient (central differences in world XZ). ---
	float e = 1.2;
	float f0;
	float hx = water_height(v_world.xz + vec2(e, 0.0), TIME, f0) - water_height(v_world.xz - vec2(e, 0.0), TIME, f0);
	float hz = water_height(v_world.xz + vec2(0.0, e), TIME, f0) - water_height(v_world.xz - vec2(0.0, e), TIME, f0);
	vec3 wn = normalize(vec3(-hx, 2.0 * e, -hz));
	// Fine sparkle: two scrolling sine lobes, drifting along the flow (CA) or a gentle set (sea).
	vec2 fl = length(v_flow) > 1e-3 ? normalize(v_flow) : vec2(1.0, 0.0);
	vec2 rp = v_world.xz * 0.35 - fl * TIME * flow_speed;
	float rx = sin(rp.x * 1.3 + TIME * 1.7) + sin(rp.y * 0.9 - TIME * 1.1);
	float rz = sin(rp.y * 1.4 - TIME * 1.5) + sin(rp.x * 1.1 + TIME * 0.9);
	wn = normalize(wn + vec3(rx, 0.0, rz) * ripple_detail * 0.15);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// --- Salinity palette: fresh (clear green-teal) ↔ salt (deep blue), continuous. ---
	vec3 shallow_color = mix(fresh_shallow, salt_shallow, v_salinity);
	vec3 deep_color = mix(fresh_deep, salt_deep, v_salinity);

	// --- Water thickness from scene depth (how far below the surface the seabed sits at this pixel). ---
	float scene_d = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, scene_d);
	vec4 view_p = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_p.xyz /= view_p.w;
	float thickness = max((-view_p.z) - (-VERTEX.z), 0.0);
	// PER-VERTEX depth influence: fresh water (lakes/rivers) is a THIN sheet — ignore scene thickness so it stays
	// clear teal instead of turning opaque-white foam; the salt SEA uses it fully for shallow→deep + shoreline foam.
	float di = mix(0.15, depth_influence, v_salinity);
	float deep_t = clamp(thickness / depth_fade, 0.0, 1.0) * di;
	vec3 col = mix(shallow_color, deep_color, deep_t);

	// --- Foam: shoreline (salt seas foam more), impact-ring crests, and CA whitewater. ---
	float foam_edge = (1.0 - smoothstep(0.0, foam_depth, thickness)) * di;
	float foam_wave = 0.5 + 0.5 * sin(v_world.x * 0.5 + v_world.z * 0.5 + TIME * 2.0);
	float shore_foam = foam_edge * (0.55 + 0.45 * foam_wave) * (0.5 + 0.5 * v_salinity);
	// Wind whitecaps: the tops of steep swell break into foam as the wind rises (storm sea goes white).
	float whitecap = smoothstep(0.55, 1.0, v_crest) * smoothstep(0.5, 1.2, wind_strength);
	float foam = clamp(max(max(shore_foam, v_foam_add), whitecap), 0.0, 1.0);
	col = mix(col, foam_color, foam);

	// Fresnel sky sheen at grazing angles.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
	col = mix(col, sky_tint, fres * 0.25);

	// --- EMERGENT SEA ICE: whiten the frozen SALT sea (fresh lakes/rivers never freeze white here). Sampled by
	// the surface radial from the mesh origin (= planet centre). Matches the ocean shell for a seamless cap. ---
	float ice = 0.0;
	if (sea_ice_enabled > 0.5 && v_salinity > 0.5) {
		vec3 centre = MODEL_MATRIX[3].xyz;
		vec3 radial = normalize(v_world - centre);
		ice = smoothstep(sea_ice_edge, sea_ice_edge + 0.35, sea_ice_at(radial)) * smoothstep(0.5, 0.8, v_salinity);
	}
	col = mix(col, sea_ice_color, ice);

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.05, 0.24, deep_t), 0.85, ice);
	METALLIC = 0.0;
	SPECULAR = mix(0.75, 0.2, ice);
	// Fresh + thin water is clearer; salt + deep water is murkier/more opaque; foam + grazing angles solid.
	float body_alpha = mix(base_alpha, mix(0.55, 0.96, deep_t) + fres * 0.35, depth_influence);
	float clarity = mix(0.12, 0.0, v_salinity);        // fresh water a touch more see-through
	ALPHA = clamp(max(max(body_alpha - clarity, foam), ice), 0.0, 1.0);   // frozen ice is opaque white
}
