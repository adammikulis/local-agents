#[compute]
#version 450

// CUBED-SPHERE atmosphere EVAPORATION — sphere port of atmos_evap3d.glsl (box). A warm, exposed water
// surface (a wet cell with open air above it) releases vapor into its OWN cell, more when warm. Purely
// per-cell; the only cross-cell read is the "open air ABOVE" test, which on the sphere is the OUTWARD
// radial neighbour (slot 5) instead of the box's +layer cell. The water→vapor reaction math is copied
// VERBATIM from the box kernel. Reads vapor_in + writes vapor_out; cloud/fog untouched here.
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VaporIn { float vapor_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer VaporOut { float vapor_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialAtmosphere3D.gd exactly.
const float EVAP_RATE = 0.02;
const float WATER_MIN = 0.05;
const float EVAP_TEMP_REF = 22.0;
const float MAX_MASS = 1.0;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);

	float vin = vapor_in[g];
	if (solid[g] != 0.0) {
		vapor_out[g] = vin;
		return;
	}
	// A cell must be a wet SURFACE (dynamic water above WATER_MIN, or a calm static-sea cell) to evaporate.
	if (water[g] <= WATER_MIN && static_cells[g] == 0.0) {
		vapor_out[g] = vin;
		return;
	}
	// Open air ABOVE = the OUTWARD radial neighbour (slot 5) is non-solid and not itself half-full of water
	// (so only the air/water interface feeds humidity). At the outward boundary (slot5 == -1 = open space)
	// the air above is open, matching the box "top of world = open" branch.
	int au = nbr[idx * 6 + 5];
	bool open_above = true;
	if (au >= 0) {
		open_above = (solid[au] == 0.0 && water[au] < MAX_MASS * 0.5);
	}
	if (!open_above) {
		vapor_out[g] = vin;
		return;
	}
	float warmth = clamp(temp[g] / EVAP_TEMP_REF, 0.0, 2.0);
	vapor_out[g] = vin + EVAP_RATE * warmth;
}
