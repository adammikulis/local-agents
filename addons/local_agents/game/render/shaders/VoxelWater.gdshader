// The free surface of the field's liquid water, drawn from above: a still dielectric of water's own refractive
// index reflecting what stands over it, glowing with the sunlight pure water scatters back out of its column
// and, drawn translucent, passing what lies under it lit through that column. The rings an impact sends
// across it lift the surface along the local vertical, which each vertex carries as its normal.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, depth_draw_always;

#include "res://addons/local_agents/game/render/shaders/generated.gdshaderinc"

// Water's refractive index; pure water's absorption and scattering coefficients per channel, 1/m, and the
// cos^2 weight (1 - d) / (1 + d) of its volume scattering function for the depolarization ratio d.
uniform float refractive_index = 1.0;
uniform vec3 absorption_per_m = vec3(0.0);
uniform vec3 scattering_per_m = vec3(0.0);
uniform float scattering_cos2_weight = 0.0;
// Whether the column's optics are known: with none, no light is drawn through the water.
uniform bool column_known = false;
// Whether what lies under the water is drawn through it: the translucent ocean quality.
uniform bool transmit_bed = false;
// Toward the star, world frame, and the share of its beam per channel that reaches the ground, in the unit
// where 1 is a white Lambertian surface facing it.
uniform vec3 sun_dir_world = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_beam = vec3(0.0);

// Impact rings: (model-frame centre, cavity radius m), and g t^2 in m for t the simulated seconds since impact.
uniform vec4 ripples[RIPPLE_MAX];
uniform float ripple_gt2[RIPPLE_MAX];
uniform int ripple_count = 0;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_model;
varying vec3 v_up;
varying float v_edge;

// Linear deep-water gravity waves from a hemispherical cavity of radius R dug in water at rest, by stationary
// phase (Cauchy-Poisson): with G = g t^2, eta = A(k) G / (2 sqrt 2 r^3) cos(G / 4r) at k = G / 4r^2, where
// A(k) = -R^3 (sin kR - kR cos kR) / (kR)^3 is the cavity's Hankel transform. Returns (eta, d eta / d r, k).
// LA_APPROX: impact_ring_stationary_phase
vec3 ring(float r, float gt2, float cavity) {
	if (gt2 <= 0.0 || r <= 0.0) {
		return vec3(0.0);
	}
	float k = gt2 / (4.0 * r * r);
	float x = k * cavity;
	float shape = x < 0.05 ? (1.0 / 3.0 - x * x / 30.0) : (sin(x) - x * cos(x)) / (x * x * x);
	float amp = -cavity * cavity * cavity * shape * gt2 / (2.0 * sqrt(2.0) * r * r * r);
	float phase = k * r;
	return vec3(amp * cos(phase), amp * k * sin(phase), k);
}

// Gradient in the plane normal to `up` and height along it, from every ring, holding only the waves a
// sampling `spacing` m apart can resolve: half a wavelength per sample.
vec4 surface(vec3 p, vec3 up, float spacing) {
	vec4 acc = vec4(0.0);
	for (int i = 0; i < RIPPLE_MAX; i++) {
		if (i >= ripple_count) {
			break;
		}
		vec3 off = p - ripples[i].xyz;
		vec3 across = off - up * dot(off, up);
		float r = length(across);
		vec3 w = ring(r, ripple_gt2[i], ripples[i].w);
		float held = smoothstep(PI, 0.5 * PI, w.z * spacing);
		if (r > 0.0) {
			acc += held * vec4(w.y * across / r, w.x);
		}
	}
	return acc;
}

// Reflectance of a dielectric interface to unpolarized light at incidence cosine `cos_i`, for the index of
// the far side over the near side `eta`; 1 past the critical angle.
float fresnel(float cos_i, float eta) {
	float sin_t2 = (1.0 - cos_i * cos_i) / (eta * eta);
	if (sin_t2 >= 1.0) {
		return 1.0;
	}
	float cos_t = sqrt(1.0 - sin_t2);
	float rs = (cos_i - eta * cos_t) / (cos_i + eta * cos_t);
	float rp = (eta * cos_i - cos_t) / (eta * cos_i + cos_t);
	return 0.5 * (rs * rs + rp * rp);
}

void vertex() {
	v_up = normalize(NORMAL);
	v_edge = UV.x;
	v_model = VERTEX;
	VERTEX += v_up * surface(VERTEX, v_up, v_edge).w;
}

void fragment() {
	mat3 to_view = mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX);
	vec3 up = normalize(to_view * v_up);
	// LA_APPROX: water_seen_from_above
	if (dot(VIEW, up) <= 0.0) {
		discard;
	}
	vec4 s = surface(v_model, v_up, length(fwidth(v_model)));
	vec3 n = normalize(to_view * (v_up - s.xyz));
	NORMAL = n;
	float eta = refractive_index;
	// A dielectric's reflectance at normal incidence, ((n - 1) / (n + 1))^2; Godot's F0 is 0.16 SPECULAR^2.
	float f0 = pow((eta - 1.0) / (eta + 1.0), 2.0);
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 0.0;
	SPECULAR = sqrt(f0 / 0.16);
	vec3 light = vec3(0.0);
	vec3 t_v = refract(-VIEW, n, 1.0 / eta);
	float mu_v = -dot(t_v, up);
	if (column_known && mu_v > 0.0) {
		// The bed under this pixel, and the vertical depth of water over it.
		vec4 bed = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).r, 1.0);
		float depth = max(dot(VERTEX - bed.xyz / bed.w, up), 0.0);
		vec3 c = absorption_per_m + scattering_per_m;
		// LA_APPROX: water_column_single_scatter
		vec3 sun_v = normalize(mat3(VIEW_MATRIX) * sun_dir_world);
		float cos_s = dot(n, sun_v);
		vec3 t_s = refract(-sun_v, n, 1.0 / eta);
		float mu_s = -dot(t_s, up);
		vec3 down = vec3(0.0);
		vec3 glow = vec3(0.0);
		if (cos_s > 0.0 && mu_s > 0.0) {
			float into = 1.0 - fresnel(cos_s, eta);
			down = into * exp(-c * depth / mu_s);
			// The refracted beam's own irradiance, where pi is a white surface facing the star above the water.
			vec3 beam = PI * sun_beam * into * cos_s / -dot(t_s, n);
			float cos_th = dot(t_s, -t_v);
			vec3 beta = scattering_per_m * (1.0 + scattering_cos2_weight * cos_th * cos_th)
				/ (4.0 * PI * (1.0 + scattering_cos2_weight / 3.0));
			float k = 1.0 / mu_s + 1.0 / mu_v;
			glow = beta * beam * (1.0 - exp(-c * depth * k)) / (c * k * mu_v);
		}
		vec3 bed_light = transmit_bed ? texture(screen_tex, SCREEN_UV).rgb * down * exp(-c * depth / mu_v) : vec3(0.0);
		// Out through the surface: its transmittance, and radiance over n^2 into the thinner medium.
		light = (bed_light + glow) * (1.0 - fresnel(dot(n, VIEW), eta)) / (eta * eta);
	}
	EMISSION = light;
	ALPHA = 1.0;
}
