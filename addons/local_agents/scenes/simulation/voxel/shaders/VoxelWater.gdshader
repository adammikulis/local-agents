// Freshwater surface shader for lakes / rivers / spring pools / cave pools (the CA water mesh — the
// open sea uses VoxelOcean.gdshader). A translucent teal-blue with gentle crossed wavelets, a fresnel
// sky sheen and a sun sparkle. Deliberately does NOT use scene-depth thickness: the CA freshwater is a
// thin sheet, so a depth-based foam/shallow term turns the whole lake opaque-white — a flat translucent
// tint reads as water reliably. Shared by the 2.5D MaterialRender + the 3D MaterialField3D surfaces.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, diffuse_burley;

uniform vec3 water_color : source_color = vec3(0.05, 0.24, 0.30);
uniform vec3 sky_tint : source_color = vec3(0.30, 0.46, 0.60);
uniform float base_alpha = 0.80;
uniform float wave_amp = 0.10;
uniform float wave_scale = 0.24;
uniform float wave_speed = 0.9;

varying vec3 v_world;

float ripple(vec2 p, float t) {
	// Two crossed wavelets (different angles/frequencies) so there's no separable grid banding.
	float a = sin(dot(p, vec2(1.0, 0.55)) * wave_scale + t * wave_speed);
	float b = sin(dot(p, vec2(-0.5, 1.0)) * wave_scale * 1.9 + t * wave_speed * 1.3);
	return (a * 0.6 + b * 0.4) * wave_amp;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += ripple(v_world.xz, TIME);
}

void fragment() {
	// Analytic normal from the ripple gradient (central differences) → catches light as moving sparkle.
	float e = 0.75;
	float hx = ripple(v_world.xz + vec2(e, 0.0), TIME) - ripple(v_world.xz - vec2(e, 0.0), TIME);
	float hz = ripple(v_world.xz + vec2(0.0, e), TIME) - ripple(v_world.xz - vec2(0.0, e), TIME);
	vec3 wn = normalize(vec3(-hx, 2.0 * e, -hz));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 5.0);
	// Rougher + low specular so a flat lake seen from above doesn't turn into a bright sky mirror; the
	// sky sheen only comes in at grazing angles (high fresnel).
	ALBEDO = mix(water_color, sky_tint, fres * 0.35);
	ROUGHNESS = 0.38;
	METALLIC = 0.0;
	SPECULAR = 0.3;
	ALPHA = clamp(base_alpha + fres * 0.18, 0.0, 1.0);
}
