// VoxelSky — procedural day/night sky with a starfield and a phase-shaded moon.
//
// Replaces ProceduralSkyMaterial so the night sky has real content: stars that fade in
// after dusk and a moon disc whose crescent/gibbous shape tracks the lunar cycle. Every
// value is driven from VoxelWorld._update_day_night() via the uniforms below, so daytime
// looks the same as before. The sun/moon directions come in as uniforms (not the LIGHTn_*
// built-ins) because Godot drops zero-energy directional lights from the sky at night, which
// would otherwise reshuffle which light index the moon maps to.
shader_type sky;

// Gradient — driven per-frame (day<->night lerp lives in VoxelWorld).
uniform vec3 sky_top_color : source_color = vec3(0.36, 0.56, 0.86);
uniform vec3 sky_horizon_color : source_color = vec3(0.72, 0.80, 0.88);
uniform vec3 ground_horizon_color : source_color = vec3(0.62, 0.66, 0.62);
uniform vec3 ground_bottom_color : source_color = vec3(0.30, 0.34, 0.30);

// Night visibility of stars + moon (0 day .. 1 night) and overall star brightness.
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float star_intensity = 1.0;

// ALTITUDE fade: 0 = down at the surface (blue atmosphere), 1 = up in space (black sky + stars everywhere).
// Driven per-frame from the camera's surface_blend so the sky CROSSFADES atmosphere<->space instead of the
// environment hard-switching background_mode (which read as an instant flip + white-out).
uniform float space_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 space_color : source_color = vec3(0.012, 0.016, 0.03);

// Sun: direction toward the sun in the sky, tint, and energy (0 hides it).
uniform vec3 sun_dir = vec3(0.4, 0.7, 0.4);
uniform vec3 sun_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float sun_energy = 1.0;

// Moon: direction toward the moon, tint, disc brightness, and lunar phase.
uniform vec3 moon_dir = vec3(-0.4, 0.7, -0.4);
uniform vec3 moon_color : source_color = vec3(0.85, 0.90, 1.0);
uniform float moon_energy = 1.0;
uniform float moon_phase : hint_range(0.0, 1.0) = 0.5;   // 0 new, 0.5 full
uniform float moon_size = 0.9985;   // cos(angular radius): larger -> smaller disc

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
	float n = sin(dot(p, vec2(41.0, 289.0)));
	return fract(vec2(262144.0, 32768.0) * n);
}

// One star per grid cell of the (azimuth, elevation) sky, at a hashed sub-position with
// hashed size/brightness and a gentle twinkle. Point-like, so the azimuth seam is invisible.
float starfield(vec3 dir) {
	float az = atan(dir.z, dir.x);
	float el = asin(clamp(dir.y, -1.0, 1.0));
	vec2 guv = vec2(az, el) * 42.0;
	vec2 cell = floor(guv);
	vec2 f = fract(guv);
	float present = step(0.82, hash21(cell + 3.7));      // ~18% of cells have a star
	vec2 starpos = 0.25 + 0.5 * hash22(cell);
	float d = length(f - starpos);
	float bright = hash21(cell + 11.3);
	float radius = mix(0.03, 0.09, bright);
	float s = present * bright * smoothstep(radius, 0.0, d);
	s *= 0.55 + 0.45 * sin(TIME * (1.0 + bright * 2.0) + hash21(cell) * 6.2831853);
	return s;
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// --- Base gradient: sky above the horizon, ground band below ---
	vec3 sky_col = mix(sky_horizon_color, sky_top_color, smoothstep(0.0, 0.4, dir.y));
	vec3 ground_col = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, -0.4, dir.y));
	vec3 col = mix(ground_col, sky_col, step(0.0, dir.y));

	// Crossfade the whole sky toward black space as the camera climbs (no hard background-mode flip).
	col = mix(col, space_color, space_amount);

	// --- Stars: at night above the horizon, and everywhere once out in space (as the atmosphere fades) ---
	float above = smoothstep(0.0, 0.15, dir.y);
	float star_gate = mix(above, 1.0, space_amount);       // in space stars fill the sphere, not just overhead
	float star_vis = max(night, space_amount);             // visible at night OR in space
	float stars = starfield(dir) * star_vis * star_intensity * star_gate;
	col += stars * vec3(0.90, 0.95, 1.0);

	// --- Sun disc + glow (energy ~0 at night, so it self-hides) ---
	if (sun_energy > 0.001) {
		float sd = dot(dir, normalize(sun_dir));
		float disc = smoothstep(0.9992, 0.9995, sd);
		float glow = pow(max(sd, 0.0), 220.0) * 0.30 + pow(max(sd, 0.0), 8.0) * 0.04;
		col += sun_color * sun_energy * (disc + glow);
	}

	// --- Moon disc, shaded by the lunar phase (visible at night) ---
	if (night > 0.001) {
		vec3 tomoon = normalize(moon_dir);
		float md = dot(dir, tomoon);
		float disc = smoothstep(moon_size, moon_size + 0.0004, md);   // filled, soft edge
		// Disc-local coordinates, normalized so the rim is at radius ~1.
		vec3 mu = normalize(cross(vec3(0.0, 1.0, 0.0), tomoon));
		vec3 mv = normalize(cross(tomoon, mu));
		vec3 rel = dir - tomoon * md;
		float rr = sqrt(max(1.0e-6, 1.0 - moon_size * moon_size));
		float un = dot(rel, mu) / rr;
		float vn = dot(rel, mv) / rr;
		// Terminator: lit where un > cos(theta)*edge; the edge curve makes it an ellipse.
		// Illuminated fraction depends only on theta, so phase brightness is correct.
		float theta = moon_phase * 6.2831853;
		float edge = sqrt(max(0.0, 1.0 - vn * vn));
		float un_s = mix(un, -un, step(0.5, moon_phase));   // flip lit limb when waning
		float lit = smoothstep(-0.04, 0.04, un_s - cos(theta) * edge);
		float shade = mix(0.06, 1.0, lit);                   // faint earthshine on dark limb
		float halo = pow(max(md, 0.0), 900.0) * 0.12;        // subtle glow
		col = mix(col, moon_color * moon_energy * shade, disc * night);
		col += moon_color * halo * moon_energy * night;
	}

	COLOR = col;
}
