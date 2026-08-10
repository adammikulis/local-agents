#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };          // in place (read + write)
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CloudIn { float cloud[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelY { float vel_y[]; };    // outward-radial (up) wind
layout(set = 0, binding = 4, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;           // STEP_DT
	uint pad0;
	float pad1;
} params;

// LAPhysical.WATER_FREEZE_C = 0.0.)
const float FREEZE_T = -10.0;      // LAPhysical.CHARGE_ZONE_WARM_C — warm edge of the mixed-phase riming zone
const float COLD_SPAN = 15.0;      // down to LAPhysical.CHARGE_ZONE_COLD_C (-25 C): the charging band
const float CHARGE_GAIN = 8.0;     // charge separated per (updraft × cloud × cold) per second
const float CHARGE_LEAK = 0.05;       // bleed WHILE electrifying — sets the forcing threshold for breakdown (cores only)
const float CHARGE_LEAK_QUIET = 0.4;  // fast bleed once the storm driver is gone (~8 -> ~0.1 in ~9 steps)
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
	float cold = 0.0;
	bool driven = (up > UPDRAFT_MIN && cloud[g] > 0.0);
	if (driven) {
		cold = clamp((FREEZE_T - temp[g]) / COLD_SPAN, 0.0, 1.0);
		q += CHARGE_GAIN * max(0.0, up) * cloud[g] * cold * params.dt;
	}
	// Actively electrifying (rising + supercooled + cloudy) -> slow leak; otherwise the driver is gone -> fast leak.
	float leak = (driven && cold > 0.0) ? CHARGE_LEAK : CHARGE_LEAK_QUIET;
	q *= (1.0 - leak);
	charge[g] = q;
}
