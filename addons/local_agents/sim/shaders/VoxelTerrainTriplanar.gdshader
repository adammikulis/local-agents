// Triplanar terrain shading: albedo from slope + radial altitude, emission from the field's temperature.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://addons/local_agents/sim/shaders/generated.gdshaderinc"

uniform float sea_level = 0.0;      // world units, relative to planet_sea_radius
uniform float snow_height = 90.0;   // world units above the sea shell

// Up is radial and altitude is height above the sea shell. Set by LARenderLayer from the body.
uniform vec3 planet_center = vec3(0.0);
uniform float planet_sea_radius = 0.0;

uniform vec3 sand_color : source_color = vec3(0.76, 0.70, 0.50);
uniform vec3 grass_color : source_color = vec3(0.33, 0.44, 0.22);
uniform vec3 grass_dark : source_color = vec3(0.22, 0.32, 0.15);
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.97);

// --- Temperature field: the field's per-cell temperature °C as an R-float 3D texture over the field box.
// Sampled at the true world position, so a cave floor and the ridge above it read their own temperature.
uniform sampler3D heat_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec3 heat_box_min = vec3(0.0);
uniform vec3 heat_box_size = vec3(1.0);
uniform float heat_debug = 0.0;      // 0 = normal + incandescence, 1 = temperature heatmap

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

	// Climate basis: up is radial, altitude is radial height above the sea shell.
	vec3 radial = wp - planet_center;
	vec3 up_dir = normalize(radial);
	float altitude = length(radial) - planet_sea_radius;
	float lat_cold = abs(up_dir.y);   // 0 at the equator, 1 at the poles

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

	// Beach/sand near sea level, then vegetation above. `altitude` is radial height above the sea shell.
	float beach = smoothstep(sea_level - 2.0, sea_level + 3.5, altitude);
	vec3 low = mix(sand_color, grass, beach);

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

	// Temperature °C at this world point, read in 3D from the field.
	vec3 huvw = (wp - heat_box_min) / heat_box_size;
	float temp = texture(heat_tex, huvw).r;

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
		EMISSION = incandescence(temp) * 3.8;
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
