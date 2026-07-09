#[compute]
#version 450

// CUBED-SPHERE GAS — SKY EXCHANGE + SKY VENT pass. Sphere port of gas_sky3d.glsl. The box kernel dispatched one
// invocation per XZ COLUMN and applied the sky exchange to that column's TOPMOST OPEN cell (found by scanning
// iy from the top down to the first non-solid cell). On the sphere there are no columns, so we dispatch PER CELL
// (like heat_sphere3d, `if (idx >= cell_count) return;`) and let each SKY-EXPOSED surface cell breathe in place.
//
// SURFACE / SKY cell on the sphere: a cell is sky-exposed iff it is OPEN (solid == 0) and its OUTWARD-radial
// neighbour (nbr slot 5) is -1 (space boundary) or solid — i.e. it is the OUTERMOST open cell reached walking
// slot 5 outward until you hit -1 or rock. That local test is exactly the landing set of the "walk slot 5
// outward" the box did by scanning a column top-down. Each surface cell touches only ITSELF, so it is race-free.
// A cell buried under rock (outward neighbour is open but the run is capped further out by stone) is never a
// surface cell → no refill / no vent = the emergent suffocation seal (trapped O₂ draws down, CO₂ pools).
//
// Sky exchange math is VERBATIM from gas_sky3d.glsl:
//   O₂  — relaxes toward O2_AMBIENT by SKY_EXCHANGE (the open atmosphere breathes it back in).
//   CO₂ — sheds toward 0 by CO2_SKY_VENT (the free atmosphere carries it off).
// Runs AFTER the o2/co2 transport gather, in place on their output buffers. Constants copied EXACTLY from
// MaterialGas3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer O2  { float o2[]; };
layout(set = 0, binding = 1, std430) restrict buffer CO2 { float co2[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialGas3D.gd exactly.
const float O2_AMBIENT = 1.0;
const float SKY_EXCHANGE = 0.5;
const float CO2_SKY_VENT = 0.25;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock: never a surface cell
	}
	// SKY-EXPOSED surface = outermost open cell (its outward-radial neighbour is space or rock).
	int up = nbr[idx * 6u + 5u];
	bool is_surface = (up < 0) || (solid[up] != 0.0);
	if (!is_surface) {
		return;                                            // sealed / buried cell: no exchange
	}
	o2[idx] += SKY_EXCHANGE * (O2_AMBIENT - o2[idx]);
	co2[idx] = max(0.0, co2[idx] - CO2_SKY_VENT * co2[idx]);
}
