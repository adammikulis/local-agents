shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.16, 0.53, 0.84, 0.62);
uniform vec4 deep_color : source_color = vec4(0.03, 0.16, 0.43, 0.72);
uniform vec3 foam_color : source_color = vec3(0.84, 0.94, 1.0);
uniform vec2 flow_dir = vec2(1.0, 0.25);
uniform float flow_speed : hint_range(0.0, 4.0) = 0.9;
uniform float noise_scale : hint_range(0.05, 4.0) = 0.45;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.34;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.28;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow : hint_range(0.0, 1.0) = 0.0;
uniform vec2 weather_wind_dir = vec2(1.0, 0.0);
uniform float weather_wind_speed : hint_range(0.0, 2.0) = 0.5;
uniform float weather_cloud_scale : hint_range(0.002, 0.25) = 0.045;
uniform float weather_cloud_strength : hint_range(0.0, 1.0) = 0.55;

uniform vec2 moon_dir = vec2(1.0, 0.0);
uniform float moon_phase : hint_range(0.0, 1.0) = 0.5;
uniform float moon_tidal_strength : hint_range(0.0, 3.0) = 1.0;
uniform float moon_tide_range : hint_range(0.0, 3.0) = 0.26;
uniform float lunar_wave_boost : hint_range(0.0, 2.0) = 0.4;

uniform vec2 gravity_source_pos = vec2(0.0, 0.0);
uniform float gravity_source_strength : hint_range(0.0, 4.0) = 1.0;
uniform float gravity_source_radius : hint_range(1.0, 4096.0) = 96.0;

uniform float ocean_wave_amplitude : hint_range(0.0, 2.0) = 0.18;
uniform float ocean_wave_frequency : hint_range(0.05, 6.0) = 0.65;
uniform float ocean_chop : hint_range(0.0, 2.0) = 0.55;
uniform float ocean_detail : hint_range(0.0, 1.0) = 0.66;
uniform vec3 camera_world_pos = vec3(0.0);
uniform float far_simplify_start : hint_range(1.0, 4096.0) = 24.0;
uniform float far_simplify_end : hint_range(1.0, 4096.0) = 96.0;
uniform float far_detail_min : hint_range(0.0, 1.0) = 0.28;

uniform sampler2D weather_field_tex;
uniform vec2 weather_field_world_size = vec2(1.0, 1.0);
uniform float weather_field_blend : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D surface_field_tex;
uniform vec2 surface_field_world_size = vec2(1.0, 1.0);
uniform float surface_field_blend : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D solar_field_tex;
uniform vec2 solar_field_world_size = vec2(1.0, 1.0);
uniform float solar_field_blend : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;
varying float tide_mask;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 456.21));
	p += dot(p, p + 34.45);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	vec2 q = p;
	for (int i = 0; i < 4; i++) {
		v += value_noise(q) * a;
		q = q * 2.03 + vec2(9.2, 3.7);
		a *= 0.5;
	}
	return v;
}

float tidal_component(vec2 world_xz, vec2 moon_n, float phase) {
	float align = dot(normalize(world_xz + vec2(0.0001)), moon_n);
	float semidiurnal = sin(align * 3.14159265 + phase * 6.2831853);
	float quarter = sin(phase * 12.5663706) * 0.18;
	return semidiurnal + quarter;
}

void vertex() {
	vec3 base_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 moon_n = normalize(moon_dir);
	float cam_dist = distance(base_world, camera_world_pos);
	float far_t = clamp((cam_dist - far_simplify_start) / max(1.0, far_simplify_end - far_simplify_start), 0.0, 1.0);
	float detail_lod = mix(1.0, max(0.0, far_detail_min), far_t) * clamp(ocean_detail, 0.0, 1.0);
	vec2 grav_delta = base_world.xz - gravity_source_pos;
	float grav_dist = length(grav_delta);
	float grav_falloff = exp(-pow(grav_dist / max(1.0, gravity_source_radius), 2.0));
	float grav_phase = sin((TIME * 0.17) + grav_dist * 0.015 + moon_phase * 6.2831853);
	float tide = tidal_component(base_world.xz, moon_n, moon_phase) * moon_tidal_strength;
	tide += grav_phase * gravity_source_strength * grav_falloff;
	tide_mask = clamp(0.5 + tide * 0.5, 0.0, 1.0);

	vec2 wind = normalize(weather_wind_dir);
	vec2 dir = normalize(flow_dir);
	float wave_base = ocean_wave_amplitude * (0.7 + wave_strength * 0.85) * detail_lod;
	float lunar_boost = 1.0 + lunar_wave_boost * tide_mask;
	float rain_boost = 1.0 + rain_intensity * 0.42;
	float amp = wave_base * lunar_boost * rain_boost;
	float freq = ocean_wave_frequency * (0.85 + tide_mask * 0.65);
	float phase_1 = dot(base_world.xz, dir * freq) + TIME * (1.3 + flow_speed * 1.8);
	float phase_2 = dot(base_world.xz, wind * (freq * 0.72)) + TIME * (0.9 + weather_wind_speed * 1.6);
	float phase_3 = dot(base_world.xz, normalize(dir + wind * 0.5) * (freq * 1.46)) - TIME * (0.55 + flow_speed * 1.2);
	float wave = sin(phase_1) * 0.55 + sin(phase_2) * 0.3 + sin(phase_3) * 0.15;
	float chop = sin(phase_1 * 1.8 + phase_2) * ocean_chop * 0.08 * detail_lod;
	float displacement = tide * moon_tide_range + wave * amp + chop;

	VERTEX.y += displacement;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 weather_uv_px = clamp(world_pos.xz / max(weather_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 weather_px = texture(weather_field_tex, weather_uv_px);
	vec2 surface_uv = clamp(world_pos.xz / max(surface_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 surface_px = texture(surface_field_tex, surface_uv);
	vec2 solar_uv = clamp(world_pos.xz / max(solar_field_world_size, vec2(1.0, 1.0)), vec2(0.0), vec2(1.0));
	vec4 solar_px = texture(solar_field_tex, solar_uv);
	float rain_mix = mix(rain_intensity, weather_px.g, weather_field_blend);
	float cloud_mix = mix(cloud_shadow, weather_px.r, weather_field_blend);
	float flow_mask = mix(0.5, surface_px.b, surface_field_blend);
	float erosion_mask = mix(0.0, surface_px.a, surface_field_blend);
	float solar_absorbed = mix(0.45, solar_px.r, solar_field_blend);
	float heat_norm = mix(0.35, solar_px.b, solar_field_blend);
	vec2 dir = normalize(flow_dir);
	float t = TIME * flow_speed * (0.85 + flow_mask * 0.9 + tide_mask * 0.4);
	float cam_dist = distance(world_pos, camera_world_pos);
	float far_t = clamp((cam_dist - far_simplify_start) / max(1.0, far_simplify_end - far_simplify_start), 0.0, 1.0);
	float detail_lod = mix(1.0, max(0.0, far_detail_min), far_t) * clamp(ocean_detail, 0.0, 1.0);
	float detail_mix = mix(0.65, 1.0, detail_lod);
	vec2 uv = UV * (noise_scale * 3.0);
	float n1 = value_noise(uv + dir * t * detail_mix);
	float n2 = value_noise((uv * mix(1.2, 1.9, detail_lod)) - dir.yx * t * 0.73);
	float n = clamp((n1 * 0.68) + (n2 * 0.32), 0.0, 1.0);
	float wave = sin((UV.x + UV.y) * 7.0 + t * (4.2 + rain_mix * 2.8)) * 0.5 + 0.5;
	float depth_blend = clamp(n * 0.72 + wave * 0.18 + tide_mask * 0.1, 0.0, 1.0);
	vec3 color = mix(deep_color.rgb, shallow_color.rgb, depth_blend);
	float foam = smoothstep(0.72 - rain_mix * 0.12, 1.0, n + wave * wave_strength + flow_mask * 0.16 + tide_mask * 0.1);
	color = mix(color, foam_color, foam * foam_strength);
	vec2 wind = normalize(weather_wind_dir);
	vec2 cloud_uv = world_pos.xz * weather_cloud_scale + wind * TIME * weather_wind_speed * 0.06;
	float cloud_mask = smoothstep(0.42, 0.82, fbm(cloud_uv));
	float dynamic_shadow = cloud_mask * weather_cloud_strength * cloud_mix;
	color *= (1.0 - (cloud_mix * 0.2 + dynamic_shadow * 0.38));
	color = mix(color, color * vec3(0.75, 0.74, 0.7), erosion_mask * 0.2);
	color *= (0.92 + solar_absorbed * 0.16);
	color += vec3(0.03, 0.02, 0.01) * heat_norm * 0.2;
	color += vec3(0.01, 0.014, 0.02) * tide_mask * 0.35;
	float fresnel = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), 2.6);

	ALBEDO = color;
	EMISSION = color * (0.06 + 0.1 * fresnel + tide_mask * 0.03);
	ROUGHNESS = 0.09 + (1.0 - n) * 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.85;
	ALPHA = mix(deep_color.a, shallow_color.a, depth_blend) + fresnel * 0.12;
}
