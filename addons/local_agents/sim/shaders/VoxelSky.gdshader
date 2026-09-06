// VoxelSky — single-scatter Rayleigh + Mie atmosphere, a starfield, and the sun and moon discs.
//
// Radiance is in the renderer's own unit, where 1.0 is a white Lambertian surface fully lit by the sun
// (radiance E/PI). Every phase function below therefore carries a factor PI over its 4-PI-normalised
// form, and there is no exposure or brightness dial anywhere in this file.
shader_type sky;

// Vertical optical depth of the standard atmosphere at 680 / 550 / 440 nm. Rayleigh is the molecular
// column (Bodhaine 1999); Mie is the aerosol column of clear continental air, taken neutral in
// wavelength.
uniform vec3 rayleigh_tau = vec3(0.0411, 0.0973, 0.2429);
uniform vec3 mie_tau = vec3(0.021, 0.021, 0.021);
uniform float mie_g = 0.76;            // Mie asymmetry (forward-scatter glow tightness)

// The local vertical at the eye, and where the eye stands: the zenith, the air mass and the ray's own
// lowest altitude are all measured from these. On a sphere world +Y is the pole, not the horizon.
uniform vec3 planet_up = vec3(0.0, 1.0, 0.0);
uniform float eye_radius_m = 0.0;      // |eye - body centre|
uniform float crust_radius_m = 0.0;    // the mean crust radius the atmosphere stands on
// Scale height of the Rayleigh atmosphere, m (U.S. Standard Atmosphere).
const float AIR_SCALE_HEIGHT_M = 8000.0;

// Sun: direction toward the sun, its tint, and cos of its angular radius seen from the eye.
uniform vec3 sun_dir = vec3(0.4, 0.7, 0.4);
uniform vec3 sun_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float sun_cos_radius = 0.9999893;
// Radiance of the solar disc in the same unit: the sun's irradiance arrives from the solid angle its
// disc subtends, so L = E / omega and omega = 2*PI*(1 - cos_radius).
uniform float sun_irradiance = 1.0;

// Moon: direction toward it, cos of its angular radius, and the direction from IT to the sun, which is
// what shades the disc into a crescent.
uniform vec3 moon_dir = vec3(-0.4, 0.7, -0.4);
uniform vec3 moon_sun_dir = vec3(0.0, 0.0, 1.0);
uniform float moon_cos_radius = 0.99999;
// Geometric albedo of the lunar surface: the disc is sunlight reflected off dark basaltic regolith.
const float MOON_ALBEDO = 0.12;

// The starfield's discs are about a degree across where a real star is a point, so its brightness is a
// declared presentation scale. Stars are ADDED to the sky, so daylight washes them out on its own.
uniform float star_intensity = 0.0001;

// Relative air mass along a ray at zenith angle z (Kasten & Young 1989), clamped at the horizon.
float air_mass(float cos_up) {
	float z = degrees(acos(clamp(cos_up, -1.0, 1.0)));
	z = min(z, 90.0);
	return 1.0 / (cos(radians(z)) + 0.50572 * pow(96.07995 - z, -1.6364));
}

// Air density at the LOWEST point the view ray reaches, relative to sea level. Looking up that is the
// eye's own altitude; looking down it is the ray's closest approach to the body, which is what makes a
// planet seen from space wear a bright limb and a black sky above it.
float ray_air_density(float cos_up) {
	float h = eye_radius_m - crust_radius_m;
	if (cos_up < 0.0) {
		float perp = eye_radius_m * sqrt(max(0.0, 1.0 - cos_up * cos_up));
		h = perp - crust_radius_m;
	}
	return exp(-max(h, 0.0) / AIR_SCALE_HEIGHT_M);
}

// Single-scatter radiance looking along `dir` with the sun toward `sun_n`. The slab is homogeneous at
// the ray's own density, the sun's beam is attenuated over its own air mass, and the view integral
// closes as (1 - exp(-tau)) so the horizon saturates instead of running away.
vec3 atmosphere(vec3 dir, vec3 sun_n, vec3 up) {
	float cos_theta = dot(dir, sun_n);
	float ray_phase = 0.1875 * (1.0 + cos_theta * cos_theta);
	float g2 = mie_g * mie_g;
	float mie_phase = 0.25 * (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * mie_g * cos_theta, 1.0e-4), 1.5);

	vec3 tau = rayleigh_tau + mie_tau;
	float dens = ray_air_density(dot(dir, up));
	vec3 tau_view = tau * air_mass(dot(dir, up)) * dens;
	vec3 tau_sun = tau * air_mass(dot(sun_n, up)) * dens;
	vec3 phase = (rayleigh_tau * ray_phase + mie_tau * mie_phase) / tau;
	return phase * exp(-tau_sun) * (1.0 - exp(-tau_view)) * sun_irradiance;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
	float n = sin(dot(p, vec2(41.0, 289.0)));
	return fract(vec2(262144.0, 32768.0) * n);
}

// One star per grid cell of the (azimuth, elevation) sky, at a hashed sub-position with hashed
// size/brightness and a gentle twinkle. Point-like, so the azimuth seam is invisible.
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
	vec3 up_n = normalize(planet_up);
	vec3 sun_n = normalize(sun_dir);
	// No painted ground hemisphere and no night gradient: the scatter is one continuous field in every
	// direction, and it goes dark on its own once the sun's path through the air is long enough.
	vec3 col = atmosphere(dir, sun_n, up_n);

	// THE DISCS AND STARS ARE DRAWN FOR THE EYE, NEVER INTO THE RADIANCE CUBEMAP. What a surface receives
	// from the sun already arrives through its own light, so adding the disc to the ambient would deliver
	// the same irradiance a second time.
	if (!AT_CUBEMAP_PASS) {
		col += starfield(dir) * star_intensity * vec3(0.90, 0.95, 1.0);

		// The solar disc at its own radiance: the irradiance arrives from the solid angle it subtends.
		float sd = dot(dir, sun_n);
		float omega = 6.2831853 * (1.0 - sun_cos_radius);
		col += sun_color * (sun_irradiance * 3.14159265 / max(omega, 1.0e-9))
			* smoothstep(sun_cos_radius - 2.0e-5, sun_cos_radius, sd);

		// The lunar disc: sunlight off a sphere of regolith, so the terminator and the crescent are
		// Lambert on the disc's own surface normal rather than a phase parameter.
		vec3 tomoon = normalize(moon_dir);
		float md = dot(dir, tomoon);
		float disc = smoothstep(moon_cos_radius - 2.0e-5, moon_cos_radius, md);
		if (disc > 0.0) {
			vec3 mu = normalize(cross(abs(tomoon.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), tomoon));
			vec3 mv = cross(tomoon, mu);
			float rr = sqrt(max(1.0e-9, 1.0 - moon_cos_radius * moon_cos_radius));
			vec3 rel = dir - tomoon * md;
			float un = dot(rel, mu) / rr;
			float vn = dot(rel, mv) / rr;
			vec3 nrm = un * mu + vn * mv - tomoon * sqrt(max(0.0, 1.0 - un * un - vn * vn));
			col += sun_color * sun_irradiance * MOON_ALBEDO
				* max(dot(nrm, normalize(moon_sun_dir)), 0.0) * disc;
		}
	}

	COLOR = col;
}
