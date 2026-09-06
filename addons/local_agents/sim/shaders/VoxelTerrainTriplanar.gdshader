// Terrain shading: bare ground, whitened where the field holds frozen water, glowing where it is hot.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://addons/local_agents/sim/shaders/generated.gdshaderinc"

// Reflectance of the two surfaces this body has at the bottom rung. Set from LAPhysical by the render
// layer; there is no third one until something in the field makes one.
uniform float albedo_bare_ground = 0.15;
uniform float albedo_snow_ice = 0.65;

// --- The field over the box, sampled at the true world position, so a cave floor and the ridge above it
// read their own state: temperature °C, water mol/m^3, and the share of that water which is ice.
uniform sampler3D heat_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler3D h2o_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler3D h2o_solid_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec3 heat_box_min = vec3(0.0);
uniform vec3 heat_box_size = vec3(1.0);
// The field's own thresholds for snow lying and for ice standing deep, mol/m^3.
uniform float snow_present = 1.0;
uniform float ice_depth = 1.0;
uniform float heat_debug = 0.0;      // 0 = normal + incandescence, 1 = temperature heatmap

// Incandescence: temperature (°C) -> emissive glow color. Dull red begins ~500, orange ~800,
// yellow-white ~1200+ (rough blackbody ramp).
vec3 incandescence(float t) {
	if (t < 450.0) {
		return vec3(0.0);
	}
	float g = smoothstep(450.0, 1300.0, t);                       // overall brightness ramp
	vec3 c = mix(vec3(0.75, 0.06, 0.0), vec3(1.0, 0.5, 0.08), smoothstep(450.0, 850.0, t));
	c = mix(c, vec3(1.0, 0.96, 0.82), smoothstep(850.0, 1300.0, t));
	return c * g;
}

// Cold(blue) -> mild(green) -> hot(red) ramp for the debug heatmap, mapped over -20..1200 °C.
vec3 heat_ramp(float t) {
	float h = clamp((t + 20.0) / 1220.0, 0.0, 1.0);
	vec3 c = mix(vec3(0.10, 0.25, 0.75), vec3(0.20, 0.80, 0.35), smoothstep(0.0, 0.45, h));
	c = mix(c, vec3(0.95, 0.85, 0.15), smoothstep(0.35, 0.7, h));
	c = mix(c, vec3(0.9, 0.15, 0.08), smoothstep(0.65, 1.0, h));
	return c;
}

varying vec3 v_world_pos;
varying vec3 v_world_normal;

// TRANSVOXEL'S TRANSITION CELLS, AS THE MESHER BUILT THEM. Each vertex carries a secondary position and
// the sides its cell and it touch; the block's mask says which of those face a coarser neighbour. The
// terrain finds this uniform by name and gives each block its own material to set it on, so declaring it
// `instance` hides it from that search and every transition triangle then collapses onto the block
// origin. Verbatim from godot_voxel's own API shader.
uniform int u_transition_mask;

float get_transvoxel_secondary_factor(int idata) {
	int transition_mask = u_transition_mask & 0xff;
	int cell_border_mask = idata & 63;
	int vertex_border_mask = (idata >> 8) & 63;
	int m = transition_mask & cell_border_mask;
	float t = float(m != 0);
	t *= float((vertex_border_mask & ~transition_mask) == 0);
	return t;
}

vec3 get_transvoxel_position(vec3 vertex_pos, vec4 fdata) {
	int idata = floatBitsToInt(fdata.a);
	vec3 pos = mix(vertex_pos, fdata.xyz, get_transvoxel_secondary_factor(idata));
	// A vertex of a transition the block is not showing collapses, so its triangle is degenerate.
	int itransition = (idata >> 16) & 0xff;
	pos *= float(itransition == 0 || (itransition & u_transition_mask) != 0);
	return pos;
}

void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Cheap value noise so albedo does not read as flat plastic.
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

void fragment() {
	vec3 wp = v_world_pos;
	vec3 wn = normalize(v_world_normal);

	// Distance fade: micro detail (mottle + normal bump) only reads up close, so far terrain stays clean
	// and doesn't shimmer as LODs stream.
	float cam_dist = length(wp - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(70.0, 260.0, cam_dist);

	// The field at this world point: temperature °C, and the frozen water lying here.
	vec3 huvw = (wp - heat_box_min) / heat_box_size;
	float temp = texture(heat_tex, huvw).r;
	float ice = max(texture(h2o_tex, huvw).r, 0.0) * clamp(texture(h2o_solid_tex, huvw).r, 0.0, 1.0);

	// Ground reflectance about its measured mean, mottled so it does not read as one flat surface.
	float n = vnoise(wp * 0.08) * 0.6 + vnoise(wp * 0.4) * 0.4;
	vec3 col = vec3(albedo_bare_ground * (0.85 + 0.30 * n));
	// Snow and ice are what the FIELD holds here: lying snow whitens the ground, deep ice covers it.
	float cover = clamp((ice - snow_present) / max(ice_depth - snow_present, 1.0e-6), 0.0, 1.0);
	col = mix(col, vec3(albedo_snow_ice), cover);

	// Procedural normal detail: perturb the smooth surface normal with the gradient of a
	// high-frequency noise so near terrain gains gentle micro relief instead of reading as
	// a flat painted surface.
	float e = 0.75;
	float gx = vnoise((wp + vec3(e, 0.0, 0.0)) * 0.55) - vnoise((wp - vec3(e, 0.0, 0.0)) * 0.55);
	float gz = vnoise((wp + vec3(0.0, 0.0, e)) * 0.55) - vnoise((wp - vec3(0.0, 0.0, e)) * 0.55);
	float bump_amt = detail * 0.35 * (1.0 - 0.5 * cover);
	vec3 wn_detail = normalize(wn - vec3(gx, 0.0, gz) * bump_amt);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn_detail, 0.0)).xyz);

	if (heat_debug > 0.5) {
		// Debug view: paint the whole surface by temperature.
		ALBEDO = heat_ramp(temp);
		ROUGHNESS = 0.9;
		METALLIC = 0.0;
		EMISSION = incandescence(temp) * 2.0;
	} else {
		ALBEDO = col;
		// Snow is smoother and brighter-specular than bare rock.
		ROUGHNESS = mix(0.85, 0.5, cover);
		SPECULAR = 0.5;
		METALLIC = 0.0;
		EMISSION = incandescence(temp) * 3.8;
	}
}
