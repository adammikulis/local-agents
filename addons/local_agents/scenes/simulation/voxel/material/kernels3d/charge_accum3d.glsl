#[compute]
#version 450

// GPU 3D CHARGE / ELECTRIFICATION — ACCUMULATE pass. A race-free per-cell port of
// LAMaterialCharge3D._accumulate() (the charge-separation half of the emergent-lightning rule). The CPU
// oracle reads/writes ONLY its own cell (no neighbour reads), so this single-dispatch kernel reproduces it
// bit-for-bit: charge separates where a convective UPDRAFT (positive vertical wind vel_y) lofts SUPERCOOLED
// CLOUD (cloud density × how deep into the mixed-phase band the cell's temperature sits), and a slow LEAK
// bleeds every non-solid cell's charge back toward neutral. In-place on the single charge buffer.
//
// NOTE vs the CPU oracle: the per-column dielectric BREAKDOWN reduction (find the over-threshold column, fire
// a bolt from its most-charged cell, inject strike heat + scare, reset the column) is a scene/ecology concern
// and stays on the CPU tail (LAMaterialCharge3D.step_scene_only), like combustion's ash/scene tail. This
// kernel is the parity oracle for the ACCUMULATE core. Constants copied EXACTLY from MaterialCharge3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };          // in place (read + write)
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CloudIn { float cloud[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float dt;       // STEP_DT
	float pad0;
	float pad1;
	float pad2;
} params;

// Charge separation tunables — MUST match MaterialCharge3D.gd exactly.
const float FREEZE_T = 12.0;       // top of the charging band
const float COLD_SPAN = 30.0;      // °C below FREEZE_T over which `cold` fades 1 -> 0
const float CHARGE_GAIN = 8.0;     // charge separated per (updraft × cloud × cold) per second
const float CHARGE_LEAK = 0.004;   // fraction of a cell's charge that bleeds away each step
const float UPDRAFT_MIN = 0.0;     // only POSITIVE vertical wind (rising air) separates charge

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		charge[g] = 0.0;
		return;
	}
	float up = vel_y[g];
	float q = charge[g];
	if (up > UPDRAFT_MIN && cloud[g] > 0.0) {
		float cold = clamp((FREEZE_T - temp[g]) / COLD_SPAN, 0.0, 1.0);
		q += CHARGE_GAIN * max(0.0, up) * cloud[g] * cold * params.dt;
	}
	q *= (1.0 - CHARGE_LEAK);        // slow leak toward neutral
	charge[g] = q;
}
