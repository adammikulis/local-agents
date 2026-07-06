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

uniform vec3 sand_color : source_color = vec3(0.76, 0.70, 0.50);
uniform vec3 grass_color : source_color = vec3(0.33, 0.44, 0.22);
uniform vec3 grass_dark : source_color = vec3(0.22, 0.32, 0.15);
uniform vec3 rock_color : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.97);

// --- Temperature field (baked by LAMaterialField into an R-float texture over world XZ). ---
// The ground reads the temperature at its position and GLOWS incandescently when hot (a meteor
// strike, lava, a wildfire) — emergent blackbody radiation, no per-event code. heat_debug flips the
// whole surface to a temperature heatmap for the debug view.
uniform sampler2D heat_tex : hint_default_black, filter_linear;
uniform vec2 heat_world_min = vec2(-300.0, -300.0);
uniform vec2 heat_world_size = vec2(600.0, 600.0);
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
	float slope = 1.0 - clamp(wn.y, 0.0, 1.0); // 0 flat, 1 vertical

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

	// Beach/sand near sea level, then grass above.
	float beach = smoothstep(sea_level - 2.0, sea_level + 3.5, wp.y);
	vec3 low = mix(sand_color, grass, beach);

	// Rock takes over on steep faces, with cooler/warmer strata from the macro noise.
	float rockf = smoothstep(0.35, 0.62, slope);
	vec3 rock = rock_color * (0.78 + 0.44 * n);
	rock = mix(rock, rock * vec3(1.06, 1.02, 0.96), macro);
	vec3 col = mix(low, rock, rockf);

	// Snow high up, but only on flatter ground.
	float snowf = smoothstep(snow_height - 18.0, snow_height + 12.0, wp.y)
		* (1.0 - smoothstep(0.5, 0.8, slope));
	col = mix(col, snow_color, clamp(snowf, 0.0, 1.0));

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
		// mesh on top is a subtler crust, so the flow reads smooth, not as blocky per-cell squares.
		EMISSION = incandescence(temp) * 3.8;
	}
}
