// VoxelSky — this body's own air scattering the star once (Rayleigh), and the star's and the moon's discs
// seen through that air.
//
// Radiance is in the renderer's own unit, where 1.0 is a white Lambertian surface lit by the star above the
// air (radiance E/PI), so the phase function carries PI over its 4-PI-normalised form. The three channels
// sample the wavelengths LASkyView.CHANNEL_WAVELENGTHS_NM declares.
shader_type sky;

// The air: Rayleigh volume-scattering coefficient at the solved ground under the eye, 1/m, per channel, and
// its scale height, m. Zero where the world holds no air, which leaves a black sky.
uniform vec3 rayleigh_beta_ground = vec3(0.0);
uniform float air_scale_height_m = 1.0;

// Where the eye stands: the solved ground radius under it, its height over that ground, its vertical.
uniform float ground_radius_m = 1.0;
uniform float eye_height_m = 0.0;
uniform vec3 planet_up = vec3(0.0, 1.0, 0.0);

// Points each view ray is integrated at.
uniform int view_samples : hint_range(4, 128) = 32;

// The star: direction toward it and the cosine of its angular radius at the eye; 1.0 draws no disc.
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float sun_cos_radius = 1.0;

// The moon: direction toward it, the cosine of its angular radius (1.0 draws no disc), the direction from it
// to the star, which shades the disc into a crescent, and its rock's albedo.
uniform vec3 moon_dir = vec3(0.0, 1.0, 0.0);
uniform float moon_cos_radius = 1.0;
uniform vec3 moon_sun_dir = vec3(0.0, 0.0, 1.0);
uniform float moon_albedo = 0.0;

// Scale heights over the ground past which the air's density is under a float's resolution of the ground's.
const float TOP_SCALE_HEIGHTS = 16.6355;   // 24 ln 2
// The Rayleigh phase function times PI.
const float RAYLEIGH_PHASE_PI = 0.1875;    // 3 / 16

// exp(y^2) erfc(y) for y >= 0 (Press et al. 1992, Numerical Recipes 2nd ed. 6.2, fractional error < 1.2e-7).
float erfcx(float y) {
	float t = 1.0 / (1.0 + 0.5 * y);
	return t * exp(-1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806
		+ t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
}

// The air from height h (radius r) out to space along a ray at cosine mu to the vertical there, in units of
// the ground's density times H: the Chapman function of r / H. A ray below the horizon runs through its
// tangent point; one the ground stops returns -1. LA_APPROX: sky_single_scatter_chapman
float column_to_space(float h, float r, float mu) {
	float H = air_scale_height_m;
	float up_leg = exp(-h / H) * sqrt(0.5 * PI * r / H) * erfcx(sqrt(0.5 * r / H) * abs(mu));
	if (mu >= 0.0) {
		return up_leg;
	}
	float s = sqrt(max(0.0, 1.0 - mu * mu));
	float ht = h * s - ground_radius_m * mu * mu / (1.0 + s);
	if (ht < 0.0) {
		return -1.0;
	}
	return 2.0 * exp(-ht / H) * sqrt(0.5 * PI * (ground_radius_m + ht) / H) - up_leg;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 up = normalize(planet_up);
	vec3 sun_n = normalize(sun_dir);
	float H = air_scale_height_m;
	float rg = ground_radius_m;
	float he = eye_height_m;
	float re = rg + he;
	float b = re * dot(d, up);
	// Distance to the ground along the ray, the near root of s^2 + 2bs + he(2rg + he) = 0, in the form that
	// keeps its digits when the ray grazes.
	float c_g = he * (2.0 * rg + he);
	float disc_g = b * b - c_g;
	bool ground = b < 0.0 && disc_g >= 0.0 && he >= 0.0;
	float s_ground = ground ? c_g / (-b + sqrt(disc_g)) : 0.0;
	// Where the ray leaves the air, or, from above it, enters it.
	float h_top = TOP_SCALE_HEIGHTS * H;
	float disc_t = b * b - (he - h_top) * (2.0 * rg + he + h_top);
	vec3 col = vec3(0.0);
	vec3 tau = vec3(0.0);
	if (disc_t > 0.0 && dot(rayleigh_beta_ground, vec3(1.0)) > 0.0) {
		float root = sqrt(disc_t);
		float s0 = he > h_top ? max(-b - root, 0.0) : 0.0;
		float s1 = ground ? min(-b + root, s_ground) : -b + root;
		if (s1 > s0) {
			float ds = (s1 - s0) / float(view_samples);
			float cos_th = dot(d, sun_n);
			float phase = RAYLEIGH_PHASE_PI * (1.0 + cos_th * cos_th);
			for (int i = 0; i < view_samples; i++) {
				float s = s0 + (float(i) + 0.5) * ds;
				float dr2 = c_g + 2.0 * b * s + s * s;
				float r = sqrt(rg * rg + dr2);
				float h = dr2 / (r + rg);
				vec3 beta = rayleigh_beta_ground * exp(-h / H);
				vec3 dtau = beta * ds;
				float lit = column_to_space(h, r, dot(sun_n, (up * re + d * s) / r));
				if (lit >= 0.0) {
					col += dtau * phase * exp(-(tau + 0.5 * dtau) - rayleigh_beta_ground * H * lit);
				}
				tau += dtau;
			}
		}
	}

	// THE DISCS ARE DRAWN FOR THE EYE, NEVER INTO THE RADIANCE CUBEMAP: what a surface receives from the star
	// already arrives through its own light. Both are seen through the air the ray crossed.
	if (!AT_CUBEMAP_PASS && !ground) {
		vec3 seen = exp(-tau);
		if (sun_cos_radius < 1.0) {
			// The disc at its own radiance: the irradiance arrives from the solid angle it subtends.
			float omega = TAU * (1.0 - sun_cos_radius);
			col += seen * (PI / omega) * smoothstep(sun_cos_radius - 2.0e-5, sun_cos_radius, dot(d, sun_n));
		}
		if (moon_cos_radius < 1.0) {
			// Sunlight off a sphere of rock: the terminator is Lambert on the disc's own surface normal.
			vec3 tomoon = normalize(moon_dir);
			float md = dot(d, tomoon);
			float disc = smoothstep(moon_cos_radius - 2.0e-5, moon_cos_radius, md);
			if (disc > 0.0) {
				vec3 mu_ax = normalize(cross(abs(tomoon.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), tomoon));
				vec3 mv = cross(tomoon, mu_ax);
				float rr = sqrt(max(1.0e-9, 1.0 - moon_cos_radius * moon_cos_radius));
				vec3 rel = d - tomoon * md;
				float un = dot(rel, mu_ax) / rr;
				float vn = dot(rel, mv) / rr;
				vec3 nrm = un * mu_ax + vn * mv - tomoon * sqrt(max(0.0, 1.0 - un * un - vn * vn));
				col += seen * moon_albedo * max(dot(nrm, normalize(moon_sun_dir)), 0.0) * disc;
			}
		}
	}
	COLOR = col;
}
