#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SrcX { int v[]; } src_x;
layout(set = 0, binding = 1, std430) readonly buffer SrcY { int v[]; } src_y;
layout(set = 0, binding = 2, std430) readonly buffer SrcZ { int v[]; } src_z;
layout(set = 0, binding = 3, std430) readonly buffer SrcValue { float v[]; } src_value;
layout(set = 0, binding = 4, std430) readonly buffer WindX { float v[]; } wind_x;
layout(set = 0, binding = 5, std430) readonly buffer WindY { float v[]; } wind_y;
layout(set = 0, binding = 6, std430) readonly buffer TouchedMask { int v[]; } touched_mask;
layout(set = 0, binding = 7, std430) restrict buffer OutX { int v[]; } out_x;
layout(set = 0, binding = 8, std430) restrict buffer OutY { int v[]; } out_y;
layout(set = 0, binding = 9, std430) restrict buffer OutZ { int v[]; } out_z;
layout(set = 0, binding = 10, std430) restrict buffer OutValue { float v[]; } out_value;
layout(set = 0, binding = 11, std430) readonly buffer Params {
	float dt;
	float decay_factor;
	float half_extent;
	float voxel_size;
	float vertical_half_extent;
	float local_mode;
	float grid_radius_cells;
	float vertical_cells;
	float source_count;
} params;

const int OUTPUT_SLOTS = 7;
const int NEIGHBOR_DX[6] = int[](1, -1, 0, 0, 0, 0);
const int NEIGHBOR_DY[6] = int[](0, 0, 1, -1, 0, 0);
const int NEIGHBOR_DZ[6] = int[](0, 0, 0, 0, 1, -1);

bool voxel_inside(int x, int y, int z) {
	float wx = float(x) * params.voxel_size;
	float wz = float(z) * params.voxel_size;
	if (length(vec2(wx, wz)) > params.half_extent) {
		return false;
	}
	return abs(float(y) * params.voxel_size) <= params.vertical_half_extent;
}

int dense_index(int x, int y, int z) {
	int radius = int(round(params.grid_radius_cells));
	int y_cells = int(round(params.vertical_cells));
	int dim = radius * 2 + 1;
	int y_dim = y_cells * 2 + 1;
	int sx = x + radius;
	int sy = y + y_cells;
	int sz = z + radius;
	if (sx < 0 || sy < 0 || sz < 0 || sx >= dim || sy >= y_dim || sz >= dim) {
		return -1;
	}
	return sx + sz * dim + sy * dim * dim;
}

bool touched_has(int x, int y, int z) {
	if (params.local_mode < 0.5) {
		return true;
	}
	int idx = dense_index(x, y, z);
	if (idx < 0 || idx >= touched_mask.v.length()) {
		return false;
	}
	return touched_mask.v[idx] != 0;
}

void write_slot(int slot_index, int x, int y, int z, float value) {
	out_x.v[slot_index] = x;
	out_y.v[slot_index] = y;
	out_z.v[slot_index] = z;
	out_value.v[slot_index] = value;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(int(round(params.source_count)))) {
		return;
	}
	int base_slot = int(idx) * OUTPUT_SLOTS;
	for (int s = 0; s < OUTPUT_SLOTS; s++) {
		write_slot(base_slot + s, 0, 0, 0, 0.0);
	}

	int sx = src_x.v[idx];
	int sy = src_y.v[idx];
	int sz = src_z.v[idx];
	float value = src_value.v[idx];
	if (value <= 0.00001) {
		return;
	}
	float remaining = value * clamp(params.decay_factor, 0.0, 1.0);
	if (remaining <= 0.00001) {
		return;
	}
	float drift_scale = (params.dt / max(params.voxel_size, 0.0001)) * 0.75;
	int dx = int(clamp(round(wind_x.v[idx] * drift_scale), -1.0, 1.0));
	int dz = int(clamp(round(wind_y.v[idx] * drift_scale), -1.0, 1.0));
	int ax = sx + dx;
	int ay = sy;
	int az = sz + dz;
	if (!voxel_inside(ax, ay, az)) {
		ax = sx;
		ay = sy;
		az = sz;
	}
	if (!touched_has(ax, ay, az)) {
		ax = sx;
		ay = sy;
		az = sz;
	}

	float retained = remaining * 0.76;
	write_slot(base_slot, ax, ay, az, retained);

	float spread = remaining - retained;
	if (spread <= 0.00001) {
		return;
	}
	int valid_neighbors = 0;
	for (int n = 0; n < 6; n++) {
		int nx = ax + NEIGHBOR_DX[n];
		int ny = ay + NEIGHBOR_DY[n];
		int nz = az + NEIGHBOR_DZ[n];
		if (!voxel_inside(nx, ny, nz)) {
			continue;
		}
		if (!touched_has(nx, ny, nz)) {
			continue;
		}
		valid_neighbors += 1;
	}
	float per = spread / float(max(1, valid_neighbors));
	for (int n = 0; n < 6; n++) {
		int nx = ax + NEIGHBOR_DX[n];
		int ny = ay + NEIGHBOR_DY[n];
		int nz = az + NEIGHBOR_DZ[n];
		if (!voxel_inside(nx, ny, nz)) {
			continue;
		}
		if (!touched_has(nx, ny, nz)) {
			continue;
		}
		write_slot(base_slot + 1 + n, nx, ny, nz, per);
	}
}
