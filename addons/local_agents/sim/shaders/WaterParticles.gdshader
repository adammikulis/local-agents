shader_type particles;
render_mode disable_velocity;

// PROCESS shader for LAWaterParticles — ONE particle system that renders whichever PHASE the field's
// water is in. Per particle it samples the field-cover texture (6-layer RGBA, one texel per SphereGrid
// surface cell) by normalize(pos - planet_center), classifies its phase from the sampled channels + its
// own radius band, gates itself invisible where the field is clear, and drifts SLOWLY (lazy clouds).
// The device split (field on a local RenderingDevice) means the field summary is baked to this texture on
// the CPU at ~10Hz; ALL per-particle placement/advection/classification stays on the GPU here.

uniform sampler2DArray field_tex : filter_nearest;
uniform vec3 planet_center;
uniform vec3 cam_pos;
uniform vec3 cam_dir;      // normalize(cam_pos - planet_center)
uniform vec3 prevailing;   // slow cloud-drift axis (planet spin axis)
uniform vec3 sun_dir;      // world dir toward the star (basis.z of the sun light)
uniform float cap_cos;     // cos(cap half-angle) — emit only in the camera-facing dome
uniform float sea_radius;
uniform float cloud_base_r;
uniform float fog_top_r;
uniform float fog_lo_r;
uniform float outer_r;

const float CLOUD_MIN = 0.12;   // cloud phase threshold (distinct FORMATIONS need sim-side condensation clumping)
const float FOG_MIN = 0.08;
const float PRECIP_MIN = 0.02;
const float AMBIENT = 0.16;
const float CLOUD_SCALE = 17.0;
const float FOG_SCALE = 22.0;
const float RAIN_W = 2.0;
const float RAIN_H = 12.0;
const float SNOW_SCALE = 3.2;
const float CLOUD_SPEED = 2.2;
const float RAIN_SPEED = 34.0;
const float SNOW_SPEED = 6.0;

// SphereGrid cube-face frames (must match sphere/SphereGrid.gd _FACE_N/_FACE_R/_FACE_U so the texel
// selection here is IDENTICAL to grid.world_to_cell — no cubemap-winding guesswork).
const vec3 FACE_N[6] = vec3[6](vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0));
const vec3 FACE_R[6] = vec3[6](vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0));
const vec3 FACE_U[6] = vec3[6](vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0));

uint hash_u(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float rnd(uint n) {
	return float(hash_u(n) & 0x00ffffffu) / 16777215.0;
}

int face_of(vec3 d) {
	vec3 a = abs(d);
	if (a.x >= a.y && a.x >= a.z) {
		return d.x >= 0.0 ? 0 : 1;
	}
	if (a.y >= a.z) {
		return d.y >= 0.0 ? 2 : 3;
	}
	return d.z >= 0.0 ? 4 : 5;
}

vec4 sample_field(vec3 dir) {
	int f = face_of(dir);
	float denom = dot(dir, FACE_N[f]);
	if (denom < 0.0001) {
		return vec4(0.0);
	}
	vec3 p = dir / denom;
	float a = dot(p, FACE_R[f]);
	float b = dot(p, FACE_U[f]);
	float u = clamp((a + 1.0) * 0.5, 0.0, 0.99999);
	float v = clamp((b + 1.0) * 0.5, 0.0, 0.99999);
	return textureLod(field_tex, vec3(u, v, float(f)), 0.0);
}

void start() {
	uint base = INDEX * 3u + uint(TIME * 60.0) * 2654435761u;
	float u1 = rnd(base);
	float u2 = rnd(base + 1u);
	float u3 = rnd(base + 2u);
	float u4 = rnd(base + 7u);
	// Band: mostly cloud aloft, a slice of precip below cloud, a minority of ground fog.
	float band;
	float r;
	if (u4 < 0.62) {
		band = 0.0;
		r = mix(sea_radius + 4.0, sea_radius + 38.0, u3);   // thin cloud shell hugging the planet
	} else if (u4 < 0.84) {
		band = 1.0;
		r = mix(sea_radius + 2.0, cloud_base_r, u3);
	} else {
		band = 2.0;
		r = mix(fog_lo_r, fog_top_r, u3);
	}
	// A random direction inside the camera-facing angular cap (the visible sky dome).
	float cos_t = mix(1.0, cap_cos, u1);
	float sin_t = sqrt(max(0.0, 1.0 - cos_t * cos_t));
	float phi = u2 * 6.2831853;
	vec3 up = abs(cam_dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t = normalize(cross(up, cam_dir));
	vec3 bb = cross(cam_dir, t);
	vec3 d = normalize(cam_dir * cos_t + (t * cos(phi) + bb * sin(phi)) * sin_t);
	TRANSFORM[3] = vec4(planet_center + d * r, 1.0);
	// w packs band*10 + sizeRand so both survive across frames (x is overwritten with phase each frame).
	CUSTOM = vec4(-1.0, 0.0, 0.5, band * 10.0 + (0.4 + u1 * 0.9));
	VELOCITY = vec3(0.0);
}

void process() {
	vec3 pos = TRANSFORM[3].xyz;
	vec3 rel = pos - planet_center;
	float r = length(rel);
	vec3 dir = rel / max(r, 0.0001);
	vec4 f = sample_field(dir);
	float packed = CUSTOM.w;
	float band = floor(packed * 0.1);
	float szr = packed - band * 10.0;
	float phase = -1.0;
	float density = 0.0;
	if (band < 0.5) {                 // CLOUD band
		density = f.r;
		if (density >= CLOUD_MIN) {
			phase = 0.0;
		}
	} else if (band < 1.5) {          // PRECIP band
		density = f.b;
		if (density >= PRECIP_MIN) {
			phase = f.a > 0.4 ? 3.0 : 2.0;   // cold column -> snow, else rain
		}
	} else {                          // FOG band
		density = f.g;
		if (density >= FOG_MIN) {
			phase = 1.0;
		}
	}
	float sx = 0.0;
	float sy = 0.0;
	vec3 drift = vec3(0.0);
	vec3 tang = normalize(cross(prevailing, dir));
	if (phase < 0.0) {
		sx = 0.0;
		sy = 0.0;
	} else if (phase < 0.5) {         // cloud — big soft puff, slow tangential drift
		sx = CLOUD_SCALE * szr * (0.7 + clamp(density * 3.0, 0.0, 1.0) * 0.5);
		sy = sx;
		drift = tang * CLOUD_SPEED;
	} else if (phase < 1.5) {         // fog — flatter, hugs the ground, slower drift
		sx = FOG_SCALE * szr;
		sy = sx * 0.7;
		drift = tang * CLOUD_SPEED * 0.5;
	} else if (phase < 2.5) {         // rain — thin tall streak, falls radially inward
		sx = RAIN_W;
		sy = RAIN_H;
		drift = -dir * RAIN_SPEED + tang * 1.5;
	} else {                          // snow — small flake, slow inward flutter
		sx = SNOW_SCALE;
		sy = SNOW_SCALE;
		drift = -dir * SNOW_SPEED + tang * 2.0;
	}
	pos += drift * DELTA;             // disable_velocity render mode -> integrate manually
	TRANSFORM[3] = vec4(pos, 1.0);
	TRANSFORM[0] = vec4(sx, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, sy, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, sx, 0.0);
	float bright = mix(AMBIENT, 1.0, clamp(dot(dir, sun_dir) * 1.5 + 0.25, 0.0, 1.0));
	VELOCITY = drift;
	CUSTOM = vec4(phase, density, bright, packed);
}
