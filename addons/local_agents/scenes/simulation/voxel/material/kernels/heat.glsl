#[compute]
#version 450

// GPU heat step for the MaterialField — a race-free GATHER port of MaterialHeat.step().
// One invocation per grid cell (flat index = j * dim + i). Reads temp_in, writes temp_out into a
// separate buffer so no invocation reads a neighbour another is writing (that read-after-write race
// is why the CPU conduction fully fills a scratch delta before applying). Constants and math are
// copied EXACTLY from material/MaterialHeat.gd — do not diverge.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer TerrainH { float terrain_h[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Sampled { float sampled[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Cloud { float cloud[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Fog { float fog[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Water { float water[]; };

layout(push_constant, std430) uniform Params {
	float solar;       // _solar_input() computed CPU-side (sun energy * elevation)
	uint dim;          // grid side length
	uint cell_count;   // dim * dim
	float pad;         // 16-byte alignment
} params;

// Constants — MUST match MaterialHeat.gd exactly.
const float CONDUCT_FRACTION = 0.16;
const float AMBIENT_RELAX = 0.06;
const float AMBIENT_NIGHT = 6.0;
const float SOLAR_WARMTH = 16.0;
const float LAPSE_RATE = 0.42;
const float LAPSE_REF = 15.0;
const float WATER_COOL = 300.0;
const float CLOUD_SHADE_GAIN = 3.0;
const float CLOUD_SHADE_MAX = 0.75;
const float WATER_THRESHOLD = 0.02;   // LAMaterialField.WATER_THRESHOLD
const float STEP_DT = 0.1;            // LAMaterialField.STEP_DT

// Godot's move_toward(a, b, d): step a toward b by at most d.
float move_toward_f(float a, float b, float d) {
	float diff = b - a;
	if (abs(diff) <= d) {
		return b;
	}
	return a + sign(diff) * d;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	// Unsampled cells are untouched by the CPU step — pass their temperature through unchanged so a
	// full download of temp_out matches _f._temp exactly.
	if (sampled[idx] == 0.0) {
		temp_out[idx] = temp_in[idx];
		return;
	}

	uint dim = params.dim;
	uint i = idx % dim;
	uint j = idx / dim;
	float t0 = temp_in[idx];

	// 1) CONDUCTION as a gather: net flux this cell receives from each sampled 4-neighbour. This is
	// numerically identical to the CPU symmetric scatter (each pair's flux applied to both cells).
	float delta = 0.0;
	if (i > 0u) {
		uint n = idx - 1u;
		if (sampled[n] != 0.0) {
			delta += (temp_in[n] - t0) * CONDUCT_FRACTION * 0.25;
		}
	}
	if (i < dim - 1u) {
		uint n = idx + 1u;
		if (sampled[n] != 0.0) {
			delta += (temp_in[n] - t0) * CONDUCT_FRACTION * 0.25;
		}
	}
	if (j > 0u) {
		uint n = idx - dim;
		if (sampled[n] != 0.0) {
			delta += (temp_in[n] - t0) * CONDUCT_FRACTION * 0.25;
		}
	}
	if (j < dim - 1u) {
		uint n = idx + dim;
		if (sampled[n] != 0.0) {
			delta += (temp_in[n] - t0) * CONDUCT_FRACTION * 0.25;
		}
	}

	// 2) Apply conduction, relax toward ambient (solar + cloud-shade - altitude lapse), cool wet cells.
	float solar_warmth = SOLAR_WARMTH * params.solar;
	float altitude = terrain_h[idx];
	float shade = min(CLOUD_SHADE_MAX, (cloud[idx] + fog[idx]) * CLOUD_SHADE_GAIN);
	float day_base = AMBIENT_NIGHT + solar_warmth * (1.0 - shade);
	float ambient = day_base - LAPSE_RATE * max(0.0, altitude - LAPSE_REF);
	float t = t0 + delta;
	t = t + (ambient - t) * AMBIENT_RELAX;
	if (water[idx] > WATER_THRESHOLD) {
		t = move_toward_f(t, ambient, WATER_COOL * STEP_DT);
	}
	temp_out[idx] = t;
}
