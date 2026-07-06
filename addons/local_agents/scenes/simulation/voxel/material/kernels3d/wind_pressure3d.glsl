#[compute]
#version 450

// GPU 3D WIND — PASS A: air PRESSURE from temperature. A race-free per-cell port of
// LAMaterialWind3D.step() PASS A: warm air is buoyant/low-pressure, cold air dense/high-pressure —
// p = P0 - K_T*(T - T_REF). SOLID cells carry P0 (a neutral wall value so a reflective neighbour read in
// PASS B sees no cross-wall gradient). One invocation per grid cell; reads temp + solid, writes pressure
// into a resident buffer PASS B then reads. Constants copied EXACTLY from MaterialWind3D.gd — do not diverge.
//
// Index layout (matches MaterialField3D): idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer PressureOut { float pressure[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Pressure model — MUST match MaterialWind3D.gd exactly.
const float P0 = 100.0;      // reference air pressure (arbitrary units; only gradients matter)
const float K_T = 0.6;       // pressure drop per °C above the reference (warm air => low pressure)
const float T_REF = 15.0;    // reference temperature the pressure curve is anchored at

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		pressure[g] = P0;
	} else {
		pressure[g] = P0 - K_T * (temp[g] - T_REF);
	}
}
