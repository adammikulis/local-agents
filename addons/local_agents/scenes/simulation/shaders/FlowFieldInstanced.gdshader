shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_back;

uniform sampler2D flow_texture;
uniform sampler2D height_texture;
uniform int grid_width = 1;
uniform int grid_height = 1;
uniform int sample_stride = 1;
uniform float cell_size = 1.0;
uniform float sea_level = 0.0;
uniform float strength_threshold : hint_range(0.0, 1.0) = 0.2;
uniform float time_sec = 0.0;

varying float v_strength;

void vertex() {
	int gw = max(grid_width, 1);
	int gh = max(grid_height, 1);
	int idx = INSTANCE_ID;
	int gx_i = idx % gw;
	int gz_i = idx / gw;
	float gx = float(gx_i);
	float gz = float(gz_i);
	vec2 uv = vec2((gx + 0.5) / float(gw), (gz + 0.5) / float(gh));
	vec4 flow = texture(flow_texture, uv);
	vec2 dir = flow.xy * 2.0 - 1.0;
	float strength = clamp(flow.z, 0.0, 1.0);
	v_strength = strength;
	float strength_mask = step(strength_threshold, strength);
	if (dot(dir, dir) < 0.00001) {
		dir = vec2(0.0, 1.0);
	}
	dir = normalize(dir);
	float ang = atan(dir.x, dir.y);
	float c = cos(ang);
	float s = sin(ang);
	float len = mix(0.2, 1.5, strength) * strength_mask;
	vec3 v = VERTEX;
	v.z *= len;
	vec2 rz = vec2(c * v.x - s * v.z, s * v.x + c * v.z);
	float h = texture(height_texture, uv).r;
	float y = max(h, sea_level) + 1.1 + sin(time_sec * 5.0 + gx * 0.2 + gz * 0.2) * 0.04;
	VERTEX = vec3(gx * float(sample_stride) * cell_size + 0.5, y, gz * float(sample_stride) * cell_size + 0.5) + vec3(rz.x, v.y, rz.y);
}

void fragment() {
	vec3 cold = vec3(0.18, 0.64, 1.0);
	vec3 warm = vec3(0.7, 0.9, 1.0);
	vec3 color = mix(cold, warm, clamp(v_strength, 0.0, 1.0));
	ALBEDO = color;
	ALPHA = mix(0.0, 0.92, step(strength_threshold, v_strength));
}
