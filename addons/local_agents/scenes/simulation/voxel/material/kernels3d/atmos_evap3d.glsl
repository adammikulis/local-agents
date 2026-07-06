#[compute]
#version 450

// GPU 3D atmosphere EVAPORATION — port of MaterialAtmosphere3D.step() STAGE 1 (the humidity source). A
// warm, exposed water surface (a wet cell with open air above it) releases vapor into its OWN cell,
// more when warm. Purely per-cell (no neighbour writes, only a read of the cell directly above for the
// "open air above" test), so one invocation per grid cell. Reads vapor_in (last step's vapor) + writes
// vapor_out; cloud/fog are untouched here (they transport unchanged from their live buffers). Constants
// copied EXACTLY from MaterialAtmosphere3D.gd — do not diverge.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VaporIn { float vapor_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer VaporOut { float vapor_out[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
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
	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;

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
	// Open air above: the cell directly above must be non-solid and not itself half-full of water (so only
	// the air/water interface — sea top, lake top, wet cavern floor under air — feeds humidity).
	bool open_above = true;
	if (iy < dim_y - 1) {
		int au = idx + layer;
		open_above = (solid[au] == 0.0 && water[au] < MAX_MASS * 0.5);
	}
	if (!open_above) {
		vapor_out[g] = vin;
		return;
	}
	float warmth = clamp(temp[g] / EVAP_TEMP_REF, 0.0, 2.0);
	vapor_out[g] = vin + EVAP_RATE * warmth;
}
