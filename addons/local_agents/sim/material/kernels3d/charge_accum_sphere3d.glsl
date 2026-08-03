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
	float dt;           // STEP_DT
	uint pad0;
	float pad1;
} params;

// Charge separation tunables. STORMS MUST FORM *AND* DISSIPATE. The band is a MEASURED PROPERTY of real
// thunderstorms, not a knob: non-inductive graupel/ice charging happens in the mixed-phase riming zone, about
// -10 C down to -25 C, so FREEZE_T/COLD_SPAN are pinned to LAPhysical and must not be moved to make a warm
// planet produce bolts. (They were: an earlier calibration set FREEZE_T=13 "just above the snow line" because
// this world could not get cold, which is the same instinct that once moved water's freezing point to 12.5 C.
// Both are fixed; a comment here claiming FREEZE_TEMP=12.5 was stale and is gone — water freezes at
// LAPhysical.WATER_FREEZE_C = 0.0.)
// The bug those calibrations were chasing was never the SOURCE, it was the missing SINK: with a near-zero leak
// (0.004) charge STOOD forever wherever it built, so a cloudy planet pinned at BREAKDOWN and firehosed ~1900
// bolts/1500f. The fix lives entirely in DISSIPATION: (1) the driver-gated decay below, and (2) post-bolt
// neighbourhood depletion in MaterialCharge3D.
const float FREEZE_T = -10.0;      // LAPhysical.CHARGE_ZONE_WARM_C — warm edge of the mixed-phase riming zone
const float COLD_SPAN = 15.0;      // down to LAPhysical.CHARGE_ZONE_COLD_C (-25 C): the charging band
const float CHARGE_GAIN = 8.0;     // charge separated per (updraft × cloud × cold) per second
// TWO LEAKS set BOTH the firing threshold and the dissipation. While a cell is ACTIVELY electrifying (rising +
// cloudy + in-band) it leaks at CHARGE_LEAK, so its charge equilibrates at ~= GAIN·up·cold·cloud·dt / CHARGE_LEAK.
// That equilibrium is a FORCING-STRENGTH THRESHOLD: with the old near-zero 0.004 leak the equilibrium was ~200×
// the forcing, so even a weakly-rising cloudy cell pinned far past breakdown and fired — the firehose. A larger
// CHARGE_LEAK pulls the equilibrium down so ONLY a vigorous convective CORE (strong updraft) crosses breakdown;
// broad gentle cloud settles below it and never fires. Then the moment the driver passes (no updraft / no cloud /
// warm), the cell switches to the MUCH stronger CHARGE_LEAK_QUIET and sheds its charge to ~0 within a handful of
// steps — so a settled/dry region goes quiet and the global charge_peak falls between storms (the sawtooth),
// instead of an ex-storm cell holding at breakdown and re-firing forever. This is the missing SINK.
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
