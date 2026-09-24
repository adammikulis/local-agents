// The free surface of the field's liquid water: a still dielectric of water's own refractive index reflecting
// what stands over it and, drawn translucent, passing what lies under it through pure water's absorption over
// the path. The rings an impact sends across it lift the surface and bend its normal. The model frame's +Y
// is the local vertical.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, depth_draw_always;

#include "res://addons/local_agents/game/render/shaders/generated.gdshaderinc"

// Water's refractive index, and its absorption coefficient at each channel's wavelength, 1/m.
uniform float refractive_index = 1.0;
uniform vec3 absorption_per_m = vec3(0.0);
// Whether what lies under the water is drawn through it: the translucent ocean quality.
uniform bool transmit_bed = false;
// Edge of the mesh's finest quad, m: the shortest wave its vertices can carry is twice this.
uniform float mesh_edge_m = 1.0;

// Impact rings: (model x, model z of the centre, g t^2 in m for t the simulated seconds since impact, cavity
// radius m).
uniform vec4 ripples[RIPPLE_MAX];
uniform int ripple_count = 0;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

varying vec3 v_model;

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

// Height and its model-XZ gradient from every ring, holding only the waves a sampling `spacing` m apart
// can resolve: half a wavelength per sample.
vec3 surface(vec2 p, float spacing) {
	vec3 acc = vec3(0.0);
	for (int i = 0; i < RIPPLE_MAX; i++) {
		if (i >= ripple_count) {
			break;
		}
		vec2 off = p - ripples[i].xy;
		float r = length(off);
		vec3 w = ring(r, ripples[i].z, ripples[i].w);
		float held = smoothstep(PI, 0.5 * PI, w.z * spacing);
		acc += held * vec3(w.x, w.y * off / max(r, 1.0e-6));
	}
	return acc;
}

void vertex() {
	VERTEX.y += surface(VERTEX.xz, mesh_edge_m).x;
	v_model = VERTEX;
}

void fragment() {
	vec3 s = surface(v_model.xz, length(fwidth(v_model.xz)));
	vec3 n_model = normalize(vec3(-s.y, 1.0, -s.z));
	NORMAL = normalize((VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * n_model, 0.0)).xyz);
	// A dielectric's reflectance at normal incidence, ((n - 1) / (n + 1))^2; Godot's F0 is 0.16 SPECULAR^2.
	float f0 = pow((refractive_index - 1.0) / (refractive_index + 1.0), 2.0);
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 0.0;
	SPECULAR = sqrt(f0 / 0.16);
	vec3 through = vec3(0.0);
	if (transmit_bed) {
		// The bed behind this pixel, attenuated over the path the ray runs through the water to reach it, and
		// by what the surface reflects instead (Schlick). LA_APPROX: water_straight_path_transmission
		vec4 bed = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).r, 1.0);
		float path = distance(bed.xyz / bed.w, VERTEX);
		float fresnel = f0 + (1.0 - f0) * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
		through = texture(screen_tex, SCREEN_UV).rgb * exp(-absorption_per_m * path) * (1.0 - fresnel);
	}
	EMISSION = through;
	ALPHA = 1.0;
}
