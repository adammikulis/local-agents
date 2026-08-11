// Natural triplanar terrain shader for the from-scratch voxel showcase.
// Colors by world height + world normal (slope), no UVs, no external textures.
//   - sand near sea level (y ~= 0)
//   - grass on gentle low ground
//   - rock on steep slopes
//   - snow up high on flatter ground
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float sea_level = 0.0;
uniform float snow_height = 90.0;

// --- Spherical planet mode -------------------------------------------------------------------
// On a sphere, climate must band by RADIAL height-above-sea, not world-Y (else all "snow" piles
// at the +Y pole). When planet_enabled > 0.5, altitude = length(world_pos - planet_center) -
// planet_sea_radius, and "up" is the radial direction normalize(world_pos - planet_center).
// When planet_enabled <= 0.5, behavior is EXACTLY the old flat (world-Y) banding.
uniform vec3 planet_center = vec3(0.0);
uniform float planet_sea_radius = 0.0;
uniform float planet_enabled = 0.0;

uniform vec3 sand_color : source_color = vec3(0.76, 0.70, 0.50);
uniform vec3 grass_color : source_color = vec3(0.33, 0.44, 0.22);
uniform vec3 grass_dark : source_color = vec3(0.22, 0.32, 0.15);
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.97);

// --- Radial geology (planet mode): exposed INTERIOR rock (revealed by carving / meteor impacts) grades
// crust -> mantle -> molten magma by actual RADIUS toward the hot core, and glows from the geothermal
// gradient. Banded by radius so the natural surface (high radius) is untouched — only dug-out deep rock
// shows layers. Makes blasting the planet reveal real geology instead of a uniform crust over water. ---
uniform float planet_mantle_radius = 175.0;   // at/below this radius exposed rock reads as mantle
uniform float planet_core_radius = 92.0;      // at/below this radius it is molten magma (glows)
uniform float planet_core_temp = 1300.0;      // core temperature driving the radial incandescence
uniform vec3 mantle_color : source_color = vec3(0.30, 0.12, 0.09);
uniform vec3 magma_color : source_color = vec3(0.95, 0.35, 0.05);

// --- Temperature field (baked by LAMaterialField into an R-float texture over world XZ). ---
// The ground reads the temperature at its position and GLOWS incandescently when hot (a meteor
// strike, lava, a wildfire) — emergent blackbody radiation, no per-event code. heat_debug flips the
// whole surface to a temperature heatmap for the debug view.
uniform sampler2D heat_tex : hint_default_black, filter_linear;
uniform vec2 heat_world_min = vec2(-300.0, -300.0);
uniform vec2 heat_world_size = vec2(600.0, 600.0);
uniform float heat_debug = 0.0;      // 0 = normal + incandescence, 1 = temperature heatmap

// --- BIOME COLORATION (Keystone B) — the ground reads by CLIMATE, not altitude alone. LABiomeTextureBaker
// bakes the field's near-ground moisture + temperature into a 6-layer texel-per-surface-column texture; the
// shader recovers the texel with the SAME inverse-gnomonic math the water renderer uses. So a dry plateau
// self-differentiates into savanna/desert and a humid coast into jungle — emergent, no per-place scripting.
// R = relative humidity (0 arid .. 1 humid), G = warmth (0 tundra-cold .. 1 tropical-hot), B = frost/snow,
// A = valid flag (0 before the first bake -> FALL BACK to the legacy altitude-only look, never a broken color).
uniform sampler2DArray biome_tex : filter_linear;
uniform float biome_enabled = 0.0;
uniform vec3 desert_color : source_color = vec3(0.80, 0.69, 0.44);   // hot + very dry -> arid sand/desert
uniform vec3 savanna_color : source_color = vec3(0.60, 0.57, 0.30);  // warm + semi-dry -> dry-grass steppe
uniform vec3 jungle_color : source_color = vec3(0.16, 0.38, 0.12);   // warm + very wet -> lush deep green
uniform vec3 tundra_color : source_color = vec3(0.52, 0.53, 0.47);   // cold -> sparse grey-brown / frost

// --- CEL SHADING (toon light) — quantize the sun's diffuse into hard bands + a crisp terminator + a flat
// toon spec, and a cheap fresnel dark rim as a fake outline (no separate pass). Tunable so the style reads
// well at orbit AND on the ground. See the light() function.
uniform float cel_shadow : hint_range(0.0, 1.0) = 0.34;   // brightness of the shadow band
uniform float cel_mid : hint_range(0.0, 1.0) = 0.72;      // brightness of the mid band
uniform float cel_term : hint_range(0.0, 1.0) = 0.50;     // shadow<->mid terminator position (in 0..1 wrap)
uniform float cel_mid_term : hint_range(0.0, 1.0) = 0.82; // mid<->lit terminator position
uniform float cel_soft : hint_range(0.001, 0.2) = 0.035;  // terminator softness (small = crisp, still AA'd)
uniform float rim_dark : hint_range(0.0, 1.0) = 0.45;     // how dark the silhouette rim gets (fake outline)
uniform float rim_power : hint_range(1.0, 8.0) = 3.5;     // rim tightness (higher = thinner edge)

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

// SphereGrid cube-face frames — MUST match sphere/SphereGrid.gd _FACE_N/_FACE_R/_FACE_U (and
// WaterParticles.gdshader) so the biome texel selection is IDENTICAL to grid.world_to_cell.
const vec3 BFACE_N[6] = vec3[6](vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0));
const vec3 BFACE_R[6] = vec3[6](vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0));
const vec3 BFACE_U[6] = vec3[6](vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0));

int biome_face_of(vec3 d) {
	vec3 a = abs(d);
	if (a.x >= a.y && a.x >= a.z) {
		return d.x >= 0.0 ? 0 : 1;
	}
	if (a.y >= a.z) {
		return d.y >= 0.0 ? 2 : 3;
	}
	return d.z >= 0.0 ? 4 : 5;
}

// Sample the baked climate texel for the surface column under radial direction `dir`.
vec4 sample_biome(vec3 dir) {
	int f = biome_face_of(dir);
	float denom = dot(dir, BFACE_N[f]);
	if (denom < 0.0001) {
		return vec4(0.0);
	}
	vec3 p = dir / denom;
	float a = dot(p, BFACE_R[f]);
	float b = dot(p, BFACE_U[f]);
	float u = clamp((a + 1.0) * 0.5, 0.0, 0.99999);
	float v = clamp((b + 1.0) * 0.5, 0.0, 0.99999);
	return textureLod(biome_tex, vec3(u, v, float(f)), 0.0);
}

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
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

	// Climate basis. Flat world: "up" is +Y and "altitude" is world-Y. Planet: "up" is the radial
	// outward direction and "altitude" is radial height above the sea-level sphere. Everything that
	// used to key off world-Y-vs-sea for climate banding keys off `altitude` instead, and slope tests
	// key off `up_dir`, so bands are correct all over a sphere (beaches at the coast everywhere, snow
	// on high peaks everywhere) rather than dumped at the pole.
	vec3 up_dir = vec3(0.0, 1.0, 0.0);
	float altitude = wp.y;
	float lat_cold = 0.0; // 0 at equator, 1 at poles (planet mode only)
	if (planet_enabled > 0.5) {
		vec3 radial = wp - planet_center;
		up_dir = normalize(radial);
		altitude = length(radial) - planet_sea_radius;
		lat_cold = abs(up_dir.y); // radial up aligns with +Y at the poles
	}

	float slope = 1.0 - clamp(dot(wn, up_dir), 0.0, 1.0); // 0 flat, 1 vertical

	// Distance fade: micro detail (mottle + normal bump) only reads up close, so far
	// terrain stays clean and doesn't shimmer/alias as LODs stream. Cheap perf win too.
	float cam_dist = length(wp - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(70.0, 260.0, cam_dist);

	// Triplanar-style procedural mottle sampled from world position, plus a slow macro
	// tint so the grass isn't a single flat green over the whole map.
	float n = vnoise(wp * 0.08) * 0.6 + vnoise(wp * 0.4) * 0.4;
	float macro = vnoise(wp * 0.012);

	// Grass with tonal + macro-patch variation (some cool, some warmer/drier patches).
	vec3 grass = mix(grass_dark, grass_color, n);
	grass = mix(grass, grass * vec3(1.10, 1.06, 0.86), smoothstep(0.55, 0.85, macro) * 0.6);
	grass = mix(grass, grass_dark * 0.9, smoothstep(0.45, 0.15, macro) * 0.4);

	// BIOME: repaint the vegetated band by the emergent climate (moisture + temperature) so the world reads
	// as distinct places. Deserts/savanna where the air is dry, jungle where it is warm+wet, tundra where it
	// is cold — all from the baked field, not per-place code. Falls back to plain grass when the texture is
	// unbaked (A<=0.5) or in flat/island mode, so the legacy look is preserved exactly.
	vec3 veg = grass;
	if (biome_enabled > 0.5 && planet_enabled > 0.5) {
		vec4 bio = sample_biome(up_dir);
		if (bio.a > 0.5) {
			float wet = bio.r;                                  // 0 arid .. 1 humid
			float warm = clamp(bio.g - 0.55 * lat_cold, 0.0, 1.0); // field warmth, cooled toward the poles
			float frost = bio.b;
			// Aridity axis: very dry -> desert, semi-dry -> dry-grass savanna, temperate -> grass, wet -> jungle.
			vec3 dry = mix(desert_color, savanna_color, smoothstep(0.12, 0.48, wet));
			vec3 wetv = mix(grass, jungle_color, smoothstep(0.62, 1.0, wet));
			vec3 climate = mix(dry, wetv, smoothstep(0.34, 0.60, wet));
			// Cold overrides moisture toward tundra; real snowpack pushes a touch further to frosted ground.
			climate = mix(climate, tundra_color, smoothstep(0.34, 0.14, warm));
			climate = mix(climate, tundra_color * 1.12, frost * 0.5);
			// Keep micro tonal variation so biomes still mottle instead of reading as flat paint.
			veg = climate * (0.90 + 0.22 * n);
		}
	}

	// Beach/sand near sea level, then the (biome-tinted) vegetation above. `altitude` is world-Y (flat) or
	// radial height-above-sea (planet), so the coastline sits at the right band all around a sphere.
	float beach = smoothstep(sea_level - 2.0, sea_level + 3.5, altitude);
	vec3 low = mix(sand_color, veg, beach);

	// Rock takes over on steep faces, with cooler/warmer strata from the macro noise.
	float rockf = smoothstep(0.35, 0.62, slope);
	vec3 rock = rock_color * (0.78 + 0.44 * n);
	rock = mix(rock, rock * vec3(1.06, 1.02, 0.96), macro);
	vec3 col = mix(low, rock, rockf);

	// Snow high up, but only on flatter ground. Uses radial `altitude` on a planet so peaks
	// everywhere get snow (not just the pole). A mild latitude bias lowers the snow line toward
	// the poles (colder) — subtle, planet-mode only (lat_cold is 0 in flat mode, so no change).
	float snow_line = snow_height - 30.0 * lat_cold;
	float snowf = smoothstep(snow_line - 18.0, snow_line + 12.0, altitude)
		* (1.0 - smoothstep(0.5, 0.8, slope));
	col = mix(col, snow_color, clamp(snowf, 0.0, 1.0));

	// Radial GEOLOGY (planet): exposed interior rock grades crust -> mantle -> molten magma by actual
	// radius toward the hot core, and picks up a geothermal glow. The natural surface sits at a high
	// radius (crust band), so this only reshapes DUG-OUT deep rock — carving/blasting reveals real layers.
	float radial_temp = 0.0;
	if (planet_enabled > 0.5) {
		float r = length(wp - planet_center);
		float mantle_f = smoothstep(planet_mantle_radius + 45.0, planet_mantle_radius, r);
		float magma_f = smoothstep(planet_core_radius + 40.0, planet_core_radius, r);
		col = mix(col, mantle_color * (0.75 + 0.5 * n), mantle_f);
		col = mix(col, magma_color, magma_f);
		float depth_f = clamp((planet_sea_radius - r) / max(planet_sea_radius - planet_core_radius, 1.0), 0.0, 1.0);
		radial_temp = depth_f * depth_f * planet_core_temp;   // squared: glow stays deep, not at the crust
	}

	// Sample the temperature field at this world XZ.
	vec2 huv = (wp.xz - heat_world_min) / heat_world_size;
	float temp = texture(heat_tex, huv).r;

	// Scorched earth: ground that has been strongly heated — a volcano's flanks and crater, a wildfire
	// burn, a meteor crater — chars toward dark basalt/ash BEFORE it starts to glow. Driven purely by
	// the temperature field, so volcanic/burnt terrain reads correctly with no per-event code.
	float scorch = smoothstep(70.0, 340.0, temp);
	col = mix(col, vec3(0.055, 0.05, 0.045), scorch);

	// Procedural normal detail: perturb the smooth surface normal with the gradient of a
	// high-frequency noise so near terrain gains gentle micro relief instead of reading as
	// a flat painted surface. Faded with distance and softened on rock/snow.
	float e = 0.75;
	float gx = vnoise((wp + vec3(e, 0.0, 0.0)) * 0.55) - vnoise((wp - vec3(e, 0.0, 0.0)) * 0.55);
	float gz = vnoise((wp + vec3(0.0, 0.0, e)) * 0.55) - vnoise((wp - vec3(0.0, 0.0, e)) * 0.55);
	float bump_amt = detail * 0.35 * (1.0 - 0.5 * snowf);
	vec3 wn_detail = normalize(wn - vec3(gx, 0.0, gz) * bump_amt);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn_detail, 0.0)).xyz);

	// Toon dark rim: darken the ALBEDO at grazing view angles for a cheap fresnel silhouette "outline"
	// (no extra pass). Emission is untouched, so glowing lava keeps its edge. Skipped in the heat debug view.
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - wp);
	float rim = pow(1.0 - clamp(dot(wn, view_dir), 0.0, 1.0), rim_power);
	col *= mix(1.0, rim_dark, rim);

	if (heat_debug > 0.5) {
		// Debug view: paint the whole surface by temperature.
		ALBEDO = heat_ramp(temp);
		ROUGHNESS = 0.9;
		METALLIC = 0.0;
		EMISSION = incandescence(temp) * 2.0;
	} else {
		ALBEDO = col;
		// Snow is smoother/brighter-specular; grass matte; rock in between.
		ROUGHNESS = mix(mix(0.92, 0.6, rockf), 0.5, snowf);
		SPECULAR = 0.5 - 0.3 * (1.0 - rockf) * (1.0 - snowf);
		METALLIC = 0.0;
		// Hot ground glows — a meteor crater, lava, or a wildfire front lights the terrain itself. This
		// SMOOTH (linear-filtered heat field) glow is the main visual of molten lava; the lava surface
		// mesh on top is a subtler crust, so the flow reads smooth, not as blocky per-cell squares. The
		// radial geothermal temp adds the deep-rock/magma glow revealed by carving, even with no strike.
		EMISSION = incandescence(max(temp, radial_temp)) * 3.8;
	}
}

// CEL SHADING: quantize the sun's diffuse into hard bands with a crisp (but AA-softened) terminator, and a
// flat toon specular glint. Defining light() overrides the default BRDF, so the whole terrain reads as a
// stylized, banded toon planet at orbit AND on the ground — while ambient/GI still fills the shadow side.
void light() {
	vec3 nrm = normalize(NORMAL);
	float ndl = dot(nrm, normalize(LIGHT));
	float t = ndl * 0.5 + 0.5;                                  // remap -1..1 -> 0..1 (wrapped, softer terminator)
	float b_shadow = smoothstep(cel_term - cel_soft, cel_term + cel_soft, t);       // shadow -> mid
	float b_lit = smoothstep(cel_mid_term - cel_soft, cel_mid_term + cel_soft, t);  // mid -> lit
	float shade = cel_shadow + (cel_mid - cel_shadow) * b_shadow + (1.0 - cel_mid) * b_lit;
	DIFFUSE_LIGHT += ATTENUATION * LIGHT_COLOR * ALBEDO * shade;

	// Flat toon specular: a small crisp highlight thresholded into one band, gated by smoothness
	// (1 - ROUGHNESS) so only the smoother surfaces (snow, wet rock) glint — grass stays matte. (SPECULAR is
	// not in the light() scope; ROUGHNESS carries from fragment.) No plastic GGX falloff.
	vec3 h = normalize(normalize(LIGHT) + normalize(VIEW));
	float ndh = max(dot(nrm, h), 0.0);
	float spec = smoothstep(0.55, 0.62, pow(ndh, 42.0));
	SPECULAR_LIGHT += ATTENUATION * LIGHT_COLOR * spec * (1.0 - ROUGHNESS) * 0.5;
}
