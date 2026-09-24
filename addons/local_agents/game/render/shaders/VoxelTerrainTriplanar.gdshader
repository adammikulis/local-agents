// Terrain shading: bare ground, whitened where the field holds frozen water, glowing where it is hot.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

// Reflectance of the two surfaces this body has at the bottom rung, from LAPhysical.
uniform float albedo_bare_ground;
uniform float albedo_snow_ice;
uniform float heat_debug = 0.0;      // 0 = the ground as it is, 1 = painted by temperature
uniform float block_view = 0.0;      // 1 = each voxel block its own flat colour, unlit

// THE FIELD AT THE FRAGMENT'S OWN PLACE IN THE BODY, one texel per leaf of the graded grid, the leaf found
// the way LAGridGeometry.cell_at finds it: a cave floor and the ridge above it read their own cells.
uniform ivec3 field_dims;            // base cells per axis
uniform float field_cell_m;          // base cell edge, m
uniform vec3 field_box_min;          // the box's lowest corner in the terrain's own frame, m
uniform int field_morton_side;       // full-depth Morton steps along one base cell edge
uniform sampler2D field_base_head : hint_default_black, filter_nearest;     // int32 bytes: first leaf of each base cell
uniform sampler2D field_base_leaves : hint_default_black, filter_nearest;   // int32 bytes: leaves in each base cell
uniform sampler2D field_leaf_codes : hint_default_black, filter_nearest;    // int32 bytes: each leaf's full-depth Morton code
uniform sampler2D field_temp : hint_default_black, filter_nearest;          // °C
uniform sampler2D field_h2o : hint_default_black, filter_nearest;           // mol/m^3
uniform sampler2D field_h2o_solid : hint_default_black, filter_nearest;     // the frozen share of that water
uniform float kelvin_offset;
// The field's own thresholds for snow lying and for ice standing deep, mol/m^3.
uniform float snow_present;
uniform float ice_depth;

// THE STAR AS THE BODY SEES IT: photosphere temperature K (r), sine squared of its angular radius (g).
uniform sampler2D star_tex : hint_default_black, filter_nearest;
// The eye's response per band (LAHeatFieldTexture.observer_table): linear-sRGB weight times 2 h c^2 over
// lambda^5 times the band, W m^-2 sr^-1 (rgb), and h c / k over lambda, K (a).
uniform sampler2D planck_observer : hint_default_black, filter_nearest;

// A block's flat colour: one of twelve hues hashed from its origin, washed toward white.
vec3 block_colour(ivec3 origin) {
	uint h = (uint(origin.x) * 0x8da6b343u) ^ (uint(origin.y) * 0xd8163841u) ^ (uint(origin.z) * 0xcb1ab31fu);
	h = (h ^ (h >> 16u)) * 0x7feb352du;
	h = (h ^ (h >> 15u)) * 0x846ca68bu;
	h ^= h >> 16u;
	float hue = float(h % 12u) / 12.0;
	vec3 rgb = clamp(abs(mod(hue * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return mix(vec3(1.0), rgb, 0.6);
}

// Cold(blue) -> mild(green) -> hot(red) ramp for the debug heatmap, mapped over -20..1200 °C.
vec3 heat_ramp(float t) {
	float h = clamp((t + 20.0) / 1220.0, 0.0, 1.0);
	vec3 c = mix(vec3(0.10, 0.25, 0.75), vec3(0.20, 0.80, 0.35), smoothstep(0.0, 0.45, h));
	c = mix(c, vec3(0.95, 0.85, 0.15), smoothstep(0.35, 0.7, h));
	c = mix(c, vec3(0.9, 0.15, 0.08), smoothstep(0.65, 1.0, h));
	return c;
}

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

// The block's origin in the terrain's own frame, whole voxels, set on each block's material by the terrain.
uniform mat4 u_block_local_transform;
// Where the terrain's own frame has its origin in the world, m.
uniform vec3 terrain_origin;

// The mottle repeats over this many metres of the body, so it is read at full precision anywhere on it.
const int NOISE_PERIOD_M = 1000;

varying vec3 v_body_normal;
varying vec3 v_noise_pos;            // m, the body's frame wrapped at NOISE_PERIOD_M
varying vec3 v_box_pos;              // m from the field box's lowest corner, the body's frame

void vertex() {
	vec3 v = get_transvoxel_position(VERTEX, CUSTOM0);
	// EVERY BLOCK IS PLACED FROM ONE EYE. A world position at this body's radius carries half a metre of
	// float32 rounding, and a block rounded on its own tears a line against its neighbour: the eye is taken
	// into the terrain's frame once, and each vertex is its block's exact whole-voxel offset from it.
	mat3 to_world = mat3(MODEL_MATRIX);
	vec3 eye = inverse(to_world) * (INV_VIEW_MATRIX[3].xyz - terrain_origin);
	vec3 eye_whole = floor(eye);
	ivec3 block = ivec3(round(u_block_local_transform[3].xyz));
	vec3 rel = vec3(block - ivec3(eye_whole)) + (v - (eye - eye_whole));
	VERTEX = mat3(VIEW_MATRIX) * (to_world * rel);
	v_body_normal = NORMAL;
	NORMAL = mat3(VIEW_MATRIX) * (to_world * NORMAL);
	v_noise_pos = mod(vec3(block), float(NOISE_PERIOD_M)) + v;
	v_box_pos = (u_block_local_transform[3].xyz - field_box_min) + v;
}

// Cheap value noise so albedo does not read as flat plastic.
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Value noise with `cycles` lattice cells over NOISE_PERIOD_M, repeating exactly there.
float mottle(vec3 p, float cycles) {
	vec3 x = p * (cycles / float(NOISE_PERIOD_M));
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(mod(i + vec3(0, 0, 0), cycles)), hash(mod(i + vec3(1, 0, 0), cycles)), f.x),
			mix(hash(mod(i + vec3(0, 1, 0), cycles)), hash(mod(i + vec3(1, 1, 0), cycles)), f.x), f.y),
		mix(mix(hash(mod(i + vec3(0, 0, 1), cycles)), hash(mod(i + vec3(1, 0, 1), cycles)), f.x),
			mix(hash(mod(i + vec3(0, 1, 1), cycles)), hash(mod(i + vec3(1, 1, 1), cycles)), f.x), f.y),
		f.z);
}

int texel_int(sampler2D tex, int i) {
	int w = textureSize(tex, 0).x;
	ivec4 b = ivec4(round(texelFetch(tex, ivec2(i % w, i / w), 0) * 255.0));
	return b.r | (b.g << 8) | (b.b << 16) | (b.a << 24);
}

float texel_float(sampler2D tex, int i) {
	int w = textureSize(tex, 0).x;
	return texelFetch(tex, ivec2(i % w, i / w), 0).r;
}

// LAGridGeometry's morton3, bit for bit.
int spread3(int v) {
	v &= 0x3ff;
	v = (v | (v << 16)) & 0x030000ff;
	v = (v | (v << 8)) & 0x0300f00f;
	v = (v | (v << 4)) & 0x030c30c3;
	v = (v | (v << 2)) & 0x09249249;
	return v;
}

// The leaf holding `p`, m from the box's lowest corner in the body's frame; -1 outside the box. The leaves
// of a base cell tile it in Morton order, so the one holding a point is the last whose code is not above it.
int field_leaf(vec3 p) {
	vec3 local = p / field_cell_m;
	ivec3 base = ivec3(floor(local));
	if (any(lessThan(base, ivec3(0))) || any(greaterThanEqual(base, field_dims))) {
		return -1;
	}
	int b = base.x + field_dims.x * (base.y + field_dims.y * base.z);
	ivec3 f = clamp(ivec3(floor(fract(local) * float(field_morton_side))), ivec3(0),
		ivec3(field_morton_side - 1));
	int code = spread3(f.x) | (spread3(f.y) << 1) | (spread3(f.z) << 2);
	int lo = texel_int(field_base_head, b);
	int hi = lo + texel_int(field_base_leaves, b) - 1;
	while (lo < hi) {
		int mid = (lo + hi + 1) / 2;
		if (texel_int(field_leaf_codes, mid) <= code) {
			lo = mid;
		} else {
			hi = mid - 1;
		}
	}
	return lo;
}

// Linear-sRGB radiance of a Planck emitter at `t_k`, W m^-2 sr^-1 through the eye's response: each band's
// weight times 1 / (exp(c2 / (lambda T)) - 1), written in exp(-x) so a cold emitter underflows to nothing.
vec3 planck_srgb(float t_k) {
	vec3 rgb = vec3(0.0);
	int bands = textureSize(planck_observer, 0).x;
	for (int i = 0; i < bands; i++) {
		vec4 w = texelFetch(planck_observer, ivec2(i, 0), 0);
		float e = exp(-w.a / t_k);
		rgb += w.rgb * (e / (1.0 - e));
	}
	return rgb;
}

void fragment() {
	// Distance fade: micro detail (mottle + normal bump) only reads up close, so far terrain stays clean
	// and doesn't shimmer as LODs stream.
	float detail = 1.0 - smoothstep(70.0, 260.0, length(VERTEX));

	// The field at this point of the body: temperature °C, and the frozen water lying here.
	int leaf = field_leaf(v_box_pos);
	float temp_c = 0.0;
	float cover = 0.0;
	if (leaf >= 0) {
		temp_c = texel_float(field_temp, leaf);
		float ice = max(texel_float(field_h2o, leaf), 0.0) * clamp(texel_float(field_h2o_solid, leaf), 0.0, 1.0);
		cover = clamp((ice - snow_present) / (ice_depth - snow_present), 0.0, 1.0);
	}

	// Ground reflectance about its measured mean, mottled so it does not read as one flat surface.
	vec3 np = v_noise_pos;
	float n = mottle(np, 80.0) * 0.6 + mottle(np, 400.0) * 0.4;
	vec3 col = mix(vec3(albedo_bare_ground * (0.85 + 0.30 * n)), vec3(albedo_snow_ice), cover);

	// Procedural normal detail: the gradient of a high-frequency noise, taken along the surface, tilts the
	// normal so near terrain gains gentle micro relief instead of reading as a flat painted surface.
	float e = 0.75;
	vec3 g = vec3(mottle(np + vec3(e, 0.0, 0.0), 550.0) - mottle(np - vec3(e, 0.0, 0.0), 550.0),
		mottle(np + vec3(0.0, e, 0.0), 550.0) - mottle(np - vec3(0.0, e, 0.0), 550.0),
		mottle(np + vec3(0.0, 0.0, e), 550.0) - mottle(np - vec3(0.0, 0.0, e), 550.0));
	vec3 nb = normalize(v_body_normal);
	float bump_amt = detail * 0.35 * (1.0 - 0.5 * cover);
	vec3 nb_detail = normalize(nb - (g - nb * dot(g, nb)) * bump_amt);
	NORMAL = normalize(mat3(VIEW_MATRIX) * (mat3(MODEL_MATRIX) * nb_detail));

	// KIRCHHOFF: an opaque surface emits what it does not reflect, at the Planck radiance of its own
	// temperature. The unit is the renderer's sunlit one, a white Lambertian surface under this star's full
	// beam, whose radiance is the star's own times the sine squared of its angular radius.
	vec3 glow = vec3(0.0);
	vec4 star = texelFetch(star_tex, ivec2(0), 0);
	if (leaf >= 0 && star.g > 0.0) {
		glow = (1.0 - col) * planck_srgb(temp_c + kelvin_offset) / (planck_srgb(star.r) * star.g);
	}

	if (heat_debug > 0.5 && leaf >= 0) {
		// Debug view: paint the surface by temperature.
		ALBEDO = heat_ramp(temp_c);
		ROUGHNESS = 0.9;
		METALLIC = 0.0;
	} else {
		ALBEDO = col;
		// Snow is smoother and brighter-specular than bare rock.
		ROUGHNESS = mix(0.85, 0.5, cover);
		SPECULAR = 0.5;
		METALLIC = 0.0;
	}
	// The display emits no negative primary: a colour outside its gamut loses that part.
	EMISSION = max(glow, vec3(0.0));
	if (block_view > 0.5) {
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
		EMISSION = block_colour(ivec3(round(u_block_local_transform[3].xyz)));
	}
}
