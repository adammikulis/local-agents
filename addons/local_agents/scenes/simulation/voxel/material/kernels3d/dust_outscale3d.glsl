#[compute]
#version 450

// GPU 3D DUST — OUTSCALE precompute. A per-cell port of LAMaterialDust3D._compute_outscale(): for every
// non-solid cell, the uniform scale that keeps its TOTAL outgoing dust fraction at or below OUT_MAX (CFL
// stability). The raw fractions are the wind Courant numbers toward each OPEN neighbour plus a gravity-
// settling fraction downward; a direction blocked by rock/boundary contributes nothing. The transport gather
// reads this so a neighbour's scaled donation is one lookup. Reads ONLY velocity + solid, so it is per-cell.
// Constants + math copied EXACTLY from MaterialDust3D.gd — the raw_out_total()/fall_frac() helpers here must
// stay identical to those recomputed in dust_transport3d.glsl.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutScale { float outscale[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float k;        // STEP_DT / cell_size (Courant factor)
	float pad0;
	float pad1;
	float pad2;
} params;

// Transport tunables — MUST match MaterialDust3D.gd exactly.
const float OUT_MAX = 0.55;
const float SETTLE_BASE = 0.25;
const float SETTLE_MIN_FRAC = 0.02;
const float SETTLE_WIND_REF = 6.0;

// Downward flux fraction of a cell: downward WIND Courant part + a gravity SETTLING fraction largest in calm
// air and falling to SETTLE_MIN_FRAC as speed approaches SETTLE_WIND_REF. Identical to MaterialDust3D._fall_frac.
float fall_frac(uint i, float k) {
	float vxi = vel_x[i];
	float vyi = vel_y[i];
	float vzi = vel_z[i];
	float speed = sqrt(vxi * vxi + vyi * vyi + vzi * vzi);
	float calm = clamp(1.0 - speed / SETTLE_WIND_REF, 0.0, 1.0);
	float settle = SETTLE_MIN_FRAC + (SETTLE_BASE - SETTLE_MIN_FRAC) * calm;
	return max(0.0, -vyi) * k + settle;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		outscale[g] = 0.0;
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	uint iy = g / layer;
	uint rem = g - iy * layer;
	uint iz = rem / dx;
	uint ix = rem - iz * dx;
	float k = params.k;

	// raw_out_total: horizontal + upward wind Courant fractions toward each OPEN neighbour, + the always-
	// present downward settling flux (never blocked — deposited when the cell below is solid).
	float t = 0.0;
	if (ix < dx - 1u && solid[g + 1u] == 0.0)    { t += max(0.0, vel_x[g]) * k; }
	if (ix > 0u && solid[g - 1u] == 0.0)         { t += max(0.0, -vel_x[g]) * k; }
	if (iz < dz - 1u && solid[g + dx] == 0.0)    { t += max(0.0, vel_z[g]) * k; }
	if (iz > 0u && solid[g - dx] == 0.0)         { t += max(0.0, -vel_z[g]) * k; }
	if (iy < dy - 1u && solid[g + layer] == 0.0) { t += max(0.0, vel_y[g]) * k; }
	t += fall_frac(g, k);

	if (t > OUT_MAX && t > 0.0) {
		outscale[g] = OUT_MAX / t;
	} else {
		outscale[g] = 1.0;
	}
}
