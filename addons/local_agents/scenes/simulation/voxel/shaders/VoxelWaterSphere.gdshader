// VoxelWaterSphere — the planet-scale open sea drawn on the spherical ocean shell (LAOceanPlane).
//
// The near-cap fluid surface (MaterialFieldRender3D + VoxelWater.gdshader) assumes a flat Y-up world and
// so cannot draw the whole planet sea — from mid distance it hands off to this shell. The old shell was a
// plain StandardMaterial deep-blue ball that POPPED against the animated near-cap water. This shader gives
// the shell the SAME water look but on a sphere: waves displace each vertex along its RADIAL normal (not
// world +Y), and every wavelength/amplitude fades to a smooth lit sphere as the camera pulls back — so the
// sea LODs continuously from choppy-up-close to a calm blue marble at orbit, with zero wave cost when far.
// Cheap by construction: a handful of sines, no textures, no CPU upload; the LOD fade is computed in-shader
// from the camera altitude so distant frames pay almost nothing. (Explicit intent; matches VoxelWater palette.)
shader_type spatial;
render_mode specular_schlick_ggx, diffuse_burley, cull_back;

// Palette — the deep-sea end of VoxelWater.gdshader so the shell and the near-cap surface read as one sea.
uniform vec3 deep_color : source_color = vec3(0.01, 0.11, 0.30);      // deep ocean blue
uniform vec3 shallow_color : source_color = vec3(0.05, 0.30, 0.46);   // wave-crest / shoulder tint
uniform vec3 sky_tint : source_color = vec3(0.44, 0.63, 0.83);        // reflected at grazing angles (fresnel)
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 0.99);

uniform float wave_amp = 1.4;          // crest height near the surface (world units)
uniform float wave_scale = 0.020;      // spatial frequency of the swell
uniform float wave_speed = 0.5;
uniform float detail_fade_start = 55.0;   // camera altitude (world units above the shell) where waves start to flatten
uniform float detail_fade_end = 850.0;    // altitude by which the sea is a smooth lit sphere (orbit)
uniform float shell_alpha : hint_range(0.0, 1.0) = 1.0;   // 1 = opaque (cheap default); <1 = translucent (HIGH preset)

varying vec3 v_world;      // displaced world position
varying vec3 v_radial;     // outward radial (undisplaced sphere normal)
varying float v_amp;       // altitude-faded wave amplitude at this vertex (world units)
varying float v_crest;     // normalized crest height (−1..1) for whitecaps

// Sum of a few directional sines evaluated in WORLD space — consistent across the sphere (no seam), and the
// same "crossed swell" character as VoxelWater's flat swell so the two seas match.
float wave_h(vec3 p, float t) {
	float h = 0.0;
	h += sin(p.x * wave_scale + t * wave_speed);
	h += sin(p.z * wave_scale * 1.3 - t * wave_speed * 1.1) * 0.7;
	h += sin((p.x + p.z) * wave_scale * 2.1 + t * wave_speed * 0.7) * 0.4;
	h += sin((p.y - p.x) * wave_scale * 1.7 + t * wave_speed * 0.9) * 0.45;
	return h;
}

void vertex() {
	// The shell mesh is a SphereMesh centred on the node origin and the node sits at the planet centre, so
	// the world planet centre is the model translation and the model-space radial is just normalize(VERTEX).
	vec3 centre = MODEL_MATRIX[3].xyz;
	float scale = length(MODEL_MATRIX[0].xyz);          // uniform node scale (tide scaling keeps it uniform)
	vec3 radial_m = normalize(VERTEX);
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// LOD: waves fade with CAMERA altitude above THIS shell point (shell radius = distance of the vertex to
	// the centre), so up-close is choppy and orbit is a smooth marble — the pop against the near-cap is gone.
	float shell_r = length(wp - centre);
	float cam_alt = distance(CAMERA_POSITION_WORLD, centre) - shell_r;
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, cam_alt);
	float amp = wave_amp * detail;

	float h = wave_h(wp, TIME) * amp;
	// Displace along the model-space radial; convert the world-unit height into model units via the scale.
	VERTEX += radial_m * (h / max(scale, 1.0e-4));

	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_radial = normalize(v_world - centre);
	v_amp = amp;
	v_crest = h / max(amp, 1.0e-3);
}

void fragment() {
	// --- Displaced normal: perturb the radial by the wave-height gradient in the local tangent plane. ---
	vec3 up_ref = abs(v_radial.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 t1 = normalize(cross(v_radial, up_ref));
	vec3 t2 = cross(v_radial, t1);
	float e = 2.5;
	float dhx = wave_h(v_world + t1 * e, TIME) - wave_h(v_world - t1 * e, TIME);
	float dhz = wave_h(v_world + t2 * e, TIME) - wave_h(v_world - t2 * e, TIME);
	float k = v_amp / (2.0 * e);
	vec3 wn = normalize(v_radial - t1 * (dhx * k) - t2 * (dhz * k));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// --- Colour: deep sea, lifting toward the crest tint on wave shoulders; whitecaps on the steep tops. ---
	float crest = clamp(v_crest * 0.5 + 0.5, 0.0, 1.0);
	vec3 col = mix(deep_color, shallow_color, crest * 0.5);
	float whitecap = smoothstep(0.72, 1.0, crest) * clamp(v_amp / max(wave_amp, 1.0e-3), 0.0, 1.0);
	col = mix(col, foam_color, whitecap * 0.6);

	// Fresnel sky sheen at grazing angles — the calm-water rim that reads as reflective ocean.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
	col = mix(col, sky_tint, fres * 0.3);

	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.18, crest);
	METALLIC = 0.0;
	SPECULAR = 0.8;
	ALPHA = clamp(max(shell_alpha, fres * 0.4 + whitecap), 0.0, 1.0);
}
