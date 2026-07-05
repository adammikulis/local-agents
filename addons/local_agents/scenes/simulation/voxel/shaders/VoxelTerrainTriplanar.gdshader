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

	// Triplanar-style procedural mottle sampled from world position.
	float n = vnoise(wp * 0.08) * 0.6 + vnoise(wp * 0.4) * 0.4;

	// Grass with tonal variation.
	vec3 grass = mix(grass_dark, grass_color, n);

	// Beach/sand near sea level, then grass above.
	float beach = smoothstep(sea_level - 2.0, sea_level + 3.5, wp.y);
	vec3 low = mix(sand_color, grass, beach);

	// Rock takes over on steep faces.
	float rockf = smoothstep(0.35, 0.62, slope);
	vec3 col = mix(low, rock_color * (0.8 + 0.4 * n), rockf);

	// Snow high up, but only on flatter ground.
	float snowf = smoothstep(snow_height - 18.0, snow_height + 12.0, wp.y)
		* (1.0 - smoothstep(0.5, 0.8, slope));
	col = mix(col, snow_color, clamp(snowf, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = mix(0.92, 0.6, rockf);
	METALLIC = 0.0;
}
