#[compute]
#version 450

// CUBED-SPHERE WIND — PASS A: air PRESSURE from temperature. Sphere port of wind_pressure3d.glsl (box).
// This pass is PURELY PER-CELL (p = P0 - K_T*(T - T_REF); SOLID cells carry the neutral wall value P0) with
// NO neighbour reads — so the sphere port is trivial: the box grid dims were used ONLY for the cell_count
// guard, so there is nothing geometric to remap. No neighbour INDEX TABLE is needed here (PASS B is where the
// gradient — and thus the neighbour table — comes in). Only change vs the box: the unused dim_x/dim_y/dim_z
// push fields are dropped, leaving just the cell_count guard. Constants copied EXACTLY from MaterialWind3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer PressureOut { float pressure[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
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
