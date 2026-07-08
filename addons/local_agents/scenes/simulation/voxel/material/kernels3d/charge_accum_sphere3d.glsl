#[compute]
#version 450

// CUBED-SPHERE CHARGE / ELECTRIFICATION — ACCUMULATE pass. Sphere port of charge_accum3d.glsl (box). This
// pass is PURELY PER-CELL (the CPU oracle reads/writes ONLY its own cell — no neighbour reads), so the sphere
// port is a structural copy: charge separates where a convective UPDRAFT lofts SUPERCOOLED CLOUD (cloud ×
// how deep into the mixed-phase band the cell's temperature sits), and a slow LEAK bleeds every non-solid
// cell's charge back toward neutral. In-place on the single charge buffer. Only change vs the box: the unused
// dim_x/dim_y/dim_z push fields are dropped (this pass never reached for a neighbour, so there is nothing to
// remap onto the neighbour table). Constants copied EXACTLY from MaterialCharge3D.gd.
//
// RADIAL-UP NOTE: the box reads vel_y as the "updraft" magnitude (the world +Y vertical wind). On the sphere
// the physically-correct updraft is the OUTWARD-RADIAL velocity; the wind PASS B port (wind_step_sphere3d)
// redefines vel_y to carry exactly that outward-radial (up) component, so this kernel KEEPS reading vel_y
// unchanged — it is already the correct radial updraft once the wind port lands. No reconstruction here.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };          // in place (read + write)
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CloudIn { float cloud[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelY { float vel_y[]; };    // outward-radial (up) wind
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;       // STEP_DT
	float pad0;
	float pad1;
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
