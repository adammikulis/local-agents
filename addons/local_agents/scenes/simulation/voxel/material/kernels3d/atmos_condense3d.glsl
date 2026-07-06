#[compute]
#version 450

// GPU 3D atmosphere CONDENSATION — port of MaterialAtmosphere3D.step() STAGES 3+4 (dewpoint condensation
// + precipitation), per VOID cell, purely local (the only cross-cell reads are the read-only masks below
// for the near-ground test). For each cell: vapor past its OWN dewpoint (SAT_BASE*exp(SAT_TEMP_GAIN*(T-
// EVAP_TEMP_REF))) condenses a CONDENSE_RATE share of the excess — into FOG when the cell is cool AND
// rests near the terrain/sea, else into CLOUD aloft; sub-saturated air re-evaporates a CLOUD_REEVAP_RATE
// share of its condensate; both dissipate by CLOUD_DECAY; thick cloud (> RAIN_CLOUD_THRESHOLD) sheds a
// RAIN_RATE share of its excess as rain. The rain MASS is written to a per-cell scratch buffer and routed
// to the ground cell by the separate atmos_rain3d gather (the only cross-cell WRITE), so this pass stays
// race-free. Constants copied EXACTLY from MaterialAtmosphere3D.gd — do not diverge.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VaporIn { float vapor_in[]; };   // post-transport
layout(set = 0, binding = 1, std430) restrict buffer Cloud { float cloud[]; };                 // post-transport, in place
layout(set = 0, binding = 2, std430) restrict buffer Fog { float fog[]; };                     // post-transport, in place
layout(set = 0, binding = 3, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 7, std430) restrict writeonly buffer VaporOut { float vapor_out[]; };
layout(set = 0, binding = 8, std430) restrict writeonly buffer Rain { float rain_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialAtmosphere3D.gd exactly.
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_TEMP_REF = 22.0;
const float CONDENSE_RATE = 0.30;
const float CLOUD_REEVAP_RATE = 0.12;
const float CLOUD_DECAY = 0.006;
const float RAIN_CLOUD_THRESHOLD = 0.45;
const float RAIN_RATE = 0.16;
const float FOG_MAX_TEMP = 12.0;
const float WATER_MIN = 0.05;
const int FOG_GROUND_CELLS = 2;

// A cell is "near the ground" if solid rock, standing water, or the static sea lies within
// FOG_GROUND_CELLS cells directly below it (the bottom of the world reads as ground).
bool near_ground(int idx, int iy, int layer) {
	for (int dd = 1; dd <= FOG_GROUND_CELLS; dd++) {
		int jy = iy - dd;
		if (jy < 0) {
			return true;
		}
		int jb = idx - dd * layer;
		if (solid[jb] != 0.0 || static_cells[jb] != 0.0 || water[jb] > WATER_MIN) {
			return true;
		}
	}
	return false;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int dim_x = int(params.dim_x);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;

	if (solid[g] != 0.0) {
		vapor_out[g] = vapor_in[g];
		rain_out[g] = 0.0;
		return;
	}

	float t = temp[g];
	float vap = vapor_in[g];
	float c = cloud[g];
	float f = fog[g];

	float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF));
	if (vap > sat) {
		float cond = (vap - sat) * CONDENSE_RATE;
		vap = vap - cond;
		if (t < FOG_MAX_TEMP && near_ground(idx, iy, layer)) {
			f += cond;
		} else {
			c += cond;
		}
	} else {
		float fr = f * CLOUD_REEVAP_RATE;
		float cr = c * CLOUD_REEVAP_RATE;
		f -= fr;
		c -= cr;
		vap = vap + fr + cr;
	}
	c *= (1.0 - CLOUD_DECAY);
	f *= (1.0 - CLOUD_DECAY);

	float rain = 0.0;
	if (c > RAIN_CLOUD_THRESHOLD) {
		rain = (c - RAIN_CLOUD_THRESHOLD) * RAIN_RATE;
		c -= rain;
	}

	vapor_out[g] = vap;
	cloud[g] = c;
	fog[g] = f;
	rain_out[g] = rain;
}
