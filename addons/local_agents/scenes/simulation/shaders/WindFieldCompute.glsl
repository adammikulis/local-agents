#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer TempRead { float v[]; } temp_read;
layout(set = 0, binding = 1, std430) buffer TempWrite { float v[]; } temp_write;
layout(set = 0, binding = 2, std430) readonly buffer WindReadX { float v[]; } wind_read_x;
layout(set = 0, binding = 3, std430) readonly buffer WindReadZ { float v[]; } wind_read_z;
layout(set = 0, binding = 4, std430) buffer WindWriteX { float v[]; } wind_write_x;
layout(set = 0, binding = 5, std430) buffer WindWriteZ { float v[]; } wind_write_z;
layout(set = 0, binding = 6, std430) readonly buffer Params {
	float dt;
	float ambient_temp;
	float diurnal_phase;
	float rain_intensity;
	float sun_altitude;
	float avg_insolation;
	float avg_uv_index;
	float avg_heat_load;
	float air_heating_scalar;
	float voxel_size;
	float vertical_half_extent;
	float half_extent;
	float base_dir_x;
	float base_dir_z;
	float base_intensity;
	float base_speed;
	float radius_cells;
	float vertical_cells;
	float wind_pass_phase;
	float terrain_seed;
	float phase;
	float tile_count;
} params;

int width_cells() {
	return max(1, int(round(params.radius_cells)) * 2 + 1);
}

int depth_cells() {
	return width_cells();
}

int height_cells() {
	return max(1, int(round(params.vertical_cells)) * 2 + 1);
}

int index_for_cell(ivec3 cell) {
	int width = width_cells();
	int depth = depth_cells();
	int radius = int(round(params.radius_cells));
	int vertical = int(round(params.vertical_cells));
	int xi = cell.x + radius;
	int zi = cell.z + radius;
	int yi = cell.y + vertical;
	if (xi < 0 || yi < 0 || zi < 0 || xi >= width || yi >= height_cells() || zi >= depth) {
		return -1;
	}
	return yi * width * depth + zi * width + xi;
}

ivec3 cell_for_index(int idx) {
	int width = width_cells();
	int depth = depth_cells();
	int slice = width * depth;
	int yi = idx / slice;
	int rem = idx - yi * slice;
	int zi = rem / width;
	int xi = rem - zi * width;
	int radius = int(round(params.radius_cells));
	int vertical = int(round(params.vertical_cells));
	return ivec3(xi - radius, yi - vertical, zi - radius);
}

bool is_inside(ivec3 cell) {
	vec2 planar = vec2(float(cell.x), float(cell.z)) * params.voxel_size;
	return length(planar) <= params.half_extent + 0.0001 && abs(float(cell.y) * params.voxel_size) <= params.vertical_half_extent + 0.0001;
}

float terrain_height(ivec3 cell) {
	float x = float(cell.x);
	float z = float(cell.z);
	return sin((x + params.terrain_seed) * 0.15) * 0.55 + cos((z - params.terrain_seed) * 0.17) * 0.45;
}

vec2 valley_axis(ivec3 cell) {
	float x = float(cell.x);
	float z = float(cell.z);
	float angle = sin((x + params.terrain_seed) * 0.12) * 1.15 + cos((z - params.terrain_seed) * 0.1) * 0.85;
	vec2 axis = vec2(cos(angle), sin(angle));
	float axis_len = length(axis);
	if (axis_len <= 0.00001) {
		return vec2(1.0, 0.0);
	}
	return axis / axis_len;
}

float read_temp(ivec3 cell, float fallback) {
	int idx = index_for_cell(cell);
	if (idx < 0 || !is_inside(cell)) {
		return fallback;
	}
	return temp_read.v[idx];
}

void run_temperature_pass(uint idx_u, ivec3 cell) {
	int idx = int(idx_u);
	float temp = temp_read.v[idx];
	if (!is_inside(cell)) {
		temp_write.v[idx] = temp;
		return;
	}
	float y_world = float(cell.y) * params.voxel_size;
	float vertical_extent = max(params.voxel_size, params.vertical_half_extent);
	float y_norm = clamp((y_world + vertical_extent) / (vertical_extent * 2.0), 0.0, 1.0);
	float near_ground = clamp(1.0 - y_norm * 0.72, 0.0, 1.0);
	float lapse = (y_norm - 0.5) * 0.24;
	float diurnal = 0.1 * sin(params.diurnal_phase + float(cell.x) * 0.07);
	float terrain = terrain_height(cell);
	float uv_norm = clamp(params.avg_uv_index / 1.6, 0.0, 1.0);
	float solar_ground_heat = params.sun_altitude * params.avg_insolation * (0.12 + params.avg_heat_load * 0.08) * near_ground * params.air_heating_scalar;
	float uv_air_heat = params.sun_altitude * uv_norm * 0.05 * clamp(y_norm * 1.2, 0.1, 1.0) * params.air_heating_scalar;
	float evaporative_cooling = params.rain_intensity * 0.1 * near_ground;
	float target_temp = clamp(
		params.ambient_temp + diurnal - terrain * 0.2 - lapse + solar_ground_heat + uv_air_heat - evaporative_cooling,
		0.0,
		1.2
	);
	float relaxation = clamp(0.1 * params.dt * (1.0 - params.rain_intensity * 0.35), 0.01, 0.35);
	float updated_temp = mix(temp, target_temp, relaxation);
	float below = read_temp(cell + ivec3(0, -1, 0), updated_temp);
	float above = read_temp(cell + ivec3(0, 1, 0), updated_temp);
	float vertical_mix = (below + above - updated_temp * 2.0) * 0.08 * params.dt;
	updated_temp = clamp(updated_temp + vertical_mix, 0.0, 1.2);
	temp_write.v[idx] = updated_temp;
}

void run_wind_pass(uint idx_u, ivec3 cell) {
	int idx = int(idx_u);
	if (!is_inside(cell)) {
		wind_write_x.v[idx] = wind_read_x.v[idx];
		wind_write_z.v[idx] = wind_read_z.v[idx];
		return;
	}
	float center = temp_read.v[idx];
	float east = read_temp(cell + ivec3(1, 0, 0), center);
	float west = read_temp(cell + ivec3(-1, 0, 0), center);
	float north = read_temp(cell + ivec3(0, 0, 1), center);
	float south = read_temp(cell + ivec3(0, 0, -1), center);
	vec2 gradient = vec2((east - west) * 0.5, (north - south) * 0.5);
	vec2 base_dir = vec2(params.base_dir_x, params.base_dir_z);
	float base_len = length(base_dir);
	if (base_len <= 0.00001) {
		base_dir = vec2(1.0, 0.0);
	} else {
		base_dir /= base_len;
	}
	vec2 terrain_channel = valley_axis(cell);
	vec2 base = base_dir * (params.base_intensity * params.base_speed);
	vec2 thermals = gradient * (0.65 + (1.0 - params.rain_intensity) * 0.25);
	vec2 channeling = terrain_channel * dot(terrain_channel, base_dir) * 0.22;
	float drag = clamp(0.18 + abs(terrain_height(cell)) * 0.3 + params.rain_intensity * 0.22, 0.1, 0.85);
	vec2 computed = (base + thermals + channeling) * (1.0 - drag * 0.4);
	vec2 prev = vec2(wind_read_x.v[idx], wind_read_z.v[idx]);
	vec2 next = mix(prev, computed, clamp(0.12 + params.dt * 0.2, 0.08, 0.5));
	wind_write_x.v[idx] = next.x;
	wind_write_z.v[idx] = next.y;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(params.tile_count)) {
		return;
	}
	ivec3 cell = cell_for_index(int(idx));
	if (params.wind_pass_phase < 0.5) {
		run_temperature_pass(idx, cell);
		return;
	}
	run_wind_pass(idx, cell);
}
