shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded, shadows_disabled, depth_draw_never;

// DRAW shader for LAWaterParticles — reads INSTANCE_CUSTOM (phase, density, brightness) written by the
// process shader and picks the appearance per phase from ONE billboarded quad: soft white cloud puff,
// flatter fog haze, thin blue rain streak, small white snow flake. Brightness carries the day/night
// terminator (dot(cloud_dir, sun_dir)) so the lit hemisphere's clouds glow and the night side darkens.

uniform vec4 sky_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3 planet_center;   // rain/snow streaks fall radially INWARD toward this, not screen-down

// INSTANCE_CUSTOM is only readable in vertex() — carry (phase, density, brightness) to the fragment.
varying vec4 v_custom;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	// Keep the per-particle (non-uniform) scale from MODEL_MATRIX.
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 wpos = MODEL_MATRIX[3].xyz;
	mat4 bill;
	float ph = INSTANCE_CUSTOM.x;
	if (ph > 1.5 && ph < 2.5) {
		// RAIN — AXIS-ALIGNED billboard: the long axis (local Y) points along the RADIAL-INWARD fall
		// direction (toward the planet core), and the quad rotates around that axis to face the camera.
		// So on a sphere the streaks slant toward the core (correct), not straight down on screen.
		vec3 fall = normalize(planet_center - wpos);
		vec3 to_cam = normalize(INV_VIEW_MATRIX[3].xyz - wpos);
		vec3 right = normalize(cross(fall, to_cam));
		vec3 fwd = normalize(cross(right, fall));
		bill = mat4(vec4(right, 0.0), vec4(fall, 0.0), vec4(fwd, 0.0), MODEL_MATRIX[3]);
	} else {
		// Round phases (cloud / fog / snow flake): camera-facing billboard.
		bill = mat4(
			vec4(normalize(INV_VIEW_MATRIX[0].xyz), 0.0),
			vec4(normalize(INV_VIEW_MATRIX[1].xyz), 0.0),
			vec4(normalize(INV_VIEW_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
	}
	VERTEX.x *= sx;
	VERTEX.y *= sy;
	MODELVIEW_MATRIX = VIEW_MATRIX * bill;
}

void fragment() {
	float ph = v_custom.x;
	float dens = v_custom.y;
	float bright = v_custom.z;
	if (ph < -0.5) {
		discard;
	}
	vec2 c = UV - vec2(0.5);
	float soft;
	vec3 col;
	float a;
	if (ph < 0.5) {              // cloud
		soft = smoothstep(1.0, 0.1, length(c) * 2.0);
		col = vec3(1.0);
		a = 0.36;
	} else if (ph < 1.5) {       // fog
		soft = smoothstep(1.0, 0.1, length(c) * 2.0);
		col = vec3(0.86, 0.88, 0.92);
		a = 0.26;
	} else if (ph < 2.5) {       // rain streak
		soft = smoothstep(0.5, 0.0, abs(c.x)) * smoothstep(0.5, 0.32, abs(c.y));
		col = vec3(0.72, 0.80, 0.92);
		a = 0.6;
	} else {                     // snow flake
		soft = smoothstep(1.0, 0.1, length(c) * 2.0);
		col = vec3(1.0);
		a = 0.9;
	}
	ALBEDO = col * sky_tint.rgb * bright;
	// CLOUD alpha fades thin cloud toward transparent (ramp from ~the phase threshold), so only DENSE
	// cells read as cloud → distinct formations with clear sky between, not a uniform blanket. Fog/rain/
	// snow keep a visibility floor.
	float dfac = (ph < 0.5) ? clamp((dens - 0.08) * 3.0, 0.15, 1.0) : clamp(dens * 4.0, 0.3, 1.0);
	ALPHA = a * soft * dfac;
}
