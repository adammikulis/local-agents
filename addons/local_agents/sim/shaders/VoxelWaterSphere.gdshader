// VoxelWaterSphere — the open sea on the shell cap LAOceanPlane meshes under the eye. Each vertex
// carries its own outward radial as its normal, and the swell displaces along it.
shader_type spatial;
render_mode specular_schlick_ggx, diffuse_burley, cull_back;

#include "res://addons/local_agents/sim/shaders/generated.gdshaderinc"

// Reflectance of the open sea and of the foam on it. Set from LAPhysical by LAOceanPlane; the hue is
// water's own (it absorbs red first), the magnitude is the measured albedo.
uniform vec3 deep_color : source_color = vec3(0.01, 0.11, 0.30);
uniform vec3 shallow_color : source_color = vec3(0.05, 0.30, 0.46);
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 0.99);

uniform float wave_amp = 1.4;          // crest height near the surface (world units)
uniform float wave_scale = 0.020;      // spatial frequency of the swell
uniform float wave_speed = 0.5;
uniform float detail_fade_start = 55.0;   // eye altitude above the shell where waves start to flatten
uniform float detail_fade_end = 850.0;    // altitude by which the sea is a smooth lit sphere (orbit)
uniform float eye_altitude_m = 0.0;       // the eye's height over the shell, from LAOceanPlane
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
	// The cap's vertices are offsets from a node standing on the shell under the eye, and NORMAL is each
	// one's own outward radial: no planet-sized coordinate ever enters the mesh.
	vec3 radial_m = normalize(NORMAL);
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// LOD: the swell fades with the eye's altitude over the shell, so up close is choppy and orbit is a
	// smooth marble.
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, eye_altitude_m);
	float amp = wave_amp * detail;

	float h = wave_h(wp, TIME) * amp;
	VERTEX += radial_m * h;

	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_radial = radial_m;
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

	// The sky the sea reflects is the sky the environment holds: a smooth surface reflecting a radiance
	// cubemap, never a painted tint.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);

	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.18, crest);
	METALLIC = 0.0;
	SPECULAR = 0.8;
	ALPHA = clamp(max(shell_alpha, fres * 0.4 + whitecap), 0.0, 1.0);
}
