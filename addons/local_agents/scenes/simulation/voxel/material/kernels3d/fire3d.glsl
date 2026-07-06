#[compute]
#version 450

// GPU 3D FIRE / COMBUSTION — a race-free per-cell port of LAMaterialCombustion3D.step(). The CPU oracle is
// written in GATHER form (each cell sums the ember heat thrown by its BURNING neighbours) precisely so this
// single-dispatch kernel reproduces it bit-for-bit: every cell reads the fire[] snapshot (fire_in) + wind,
// writes its own temp/fuel in place, and writes the next fire state to fire_out (ping-pong). Order-independent.
//
// Per non-solid cell:
//   1) EMBER GATHER — add preheat from each burning neighbour, biased DOWNWIND by that neighbour's wind
//      blowing toward this cell (+ a fixed upward throw from a burning cell below → plume climbs slopes).
//   2) PHASE — WET (water > WET_MAX) extinguishes (firebreak); else a burning cell CONSUMES fuel + pins its
//      own temp to BURN_TEMP (self-sustaining; the heat kernels conduct it out) and burns to ash when spent;
//      an unlit fuel cell IGNITES once its temp reaches IGNITE_TEMP (from lava/lightning/meteor/spreading front).
//
// NOTE vs the CPU oracle: ASH marking, the plant/tree fuel-feed + consume, and ash→plant regrowth are
// scene/ecology concerns and stay on the CPU (like lava's SDF stamps + melt). This kernel is the parity
// oracle; wiring it into MaterialGPU3D.step()'s resident seam (a fire ping-pong pair, like lava) is the
// remaining GPU-first work. Constants copied EXACTLY from MaterialCombustion3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer FireIn  { float fire_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer FireOut { float fire_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Fuel    { float fuel[]; };
layout(set = 0, binding = 3, std430) restrict buffer Temp    { float temp[]; };
layout(set = 0, binding = 4, std430) restrict buffer Water   { float water[]; };
layout(set = 0, binding = 5, std430) restrict buffer Solid   { float solid[]; };
layout(set = 0, binding = 6, std430) restrict buffer VelX    { float vel_x[]; };
layout(set = 0, binding = 7, std430) restrict buffer VelZ    { float vel_z[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Constants — MUST match MaterialCombustion3D.gd exactly.
const float IGNITE_TEMP = 300.0;
const float BURN_TEMP = 640.0;
const float FUEL_MIN = 0.02;
const float FIRE_MIN = 0.02;
const float FIRE_START = 0.4;
const float FIRE_GROW = 0.3;
const float BURN_RATE = 0.045;
const float WET_MAX = 0.05;
const float EMBER_HEAT = 22.0;
const float EMBER_WIND_GAIN = 5.0;
const float EMBER_MAX = 70.0;
const float EMBER_UP = 16.0;

// Ember one burning neighbour contributes (base creep + downwind boost, × emitter intensity, capped).
float ember(float neighbour_fire, float toward) {
	float w = EMBER_HEAT + EMBER_WIND_GAIN * max(0.0, toward);
	return min(EMBER_MAX, w) * clamp(neighbour_fire, 0.0, 1.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		fire_out[g] = 0.0;
		return;
	}
	uint dx = params.dim_x;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	uint iy = g / layer;
	uint rem = g % layer;
	uint iz = rem / dx;
	uint ix = rem % dx;

	// 1) EMBER GATHER from burning neighbours (downwind/upward biased).
	float e = 0.0;
	if (ix > 0u) {
		uint n = g - 1u;                              // neighbour to -X emits toward +X
		if (solid[n] == 0.0 && fire_in[n] > FIRE_MIN) { e += ember(fire_in[n], vel_x[n]); }
	}
	if (ix < dx - 1u) {
		uint n = g + 1u;                              // neighbour to +X emits toward -X
		if (solid[n] == 0.0 && fire_in[n] > FIRE_MIN) { e += ember(fire_in[n], -vel_x[n]); }
	}
	if (iz > 0u) {
		uint n = g - dx;                              // neighbour to -Z emits toward +Z
		if (solid[n] == 0.0 && fire_in[n] > FIRE_MIN) { e += ember(fire_in[n], vel_z[n]); }
	}
	if (iz < dz - 1u) {
		uint n = g + dx;                              // neighbour to +Z emits toward -Z
		if (solid[n] == 0.0 && fire_in[n] > FIRE_MIN) { e += ember(fire_in[n], -vel_z[n]); }
	}
	if (iy > 0u) {
		uint nd = g - layer;                          // burning cell below throws a plume upward
		if (solid[nd] == 0.0 && fire_in[nd] > FIRE_MIN) { e += EMBER_UP * clamp(fire_in[nd], 0.0, 1.0); }
	}
	if (e > 0.0) {
		temp[g] += e;
	}

	// 2) PHASE — extinguish / burn / ignite.
	float f = fire_in[g];
	float fuel_i = fuel[g];
	float fnew = 0.0;
	if (water[g] > WET_MAX) {
		fnew = 0.0;                                   // wet → firebreak
	} else if (f > FIRE_MIN) {
		if (fuel_i > 0.0) {
			fuel[g] = max(0.0, fuel_i - BURN_RATE * clamp(f, 0.0, 1.0));
			if (temp[g] < BURN_TEMP) { temp[g] = BURN_TEMP; }
			fnew = (fuel[g] <= 0.0) ? 0.0 : min(1.0, f + FIRE_GROW);
		} else {
			fnew = 0.0;
		}
	} else if (fuel_i > FUEL_MIN && temp[g] >= IGNITE_TEMP) {
		fnew = FIRE_START;                            // IGNITION from any heat source
	}
	fire_out[g] = fnew;
}
