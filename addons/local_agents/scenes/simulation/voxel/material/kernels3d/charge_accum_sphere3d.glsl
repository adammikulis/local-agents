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
layout(set = 0, binding = 5, std430) restrict readonly buffer Relevance { float relevance[]; };  // Keystone C

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;           // STEP_DT
	uint step_index;    // monotonic field-step counter, for the relevance-gated update stride
	float pad1;
} params;

// Charge separation tunables. STORMS MUST FORM *AND* DISSIPATE. Two prior calibrations each failed one
// half: FREEZE_T=13 + a near-zero LEAK (0.004) let charge STAND forever wherever it built, so a warm cloudy
// planet pinned at BREAKDOWN and firehosed ~1900 bolts/1500f (forms, never dissipates); FREEZE_T=0 then over-
// corrected the SOURCE — almost no cell on this warm world reaches sub-freezing, so charge never reached
// breakdown and ZERO bolts fired (dissipates, never forms). The real bug was never the source — it was the
// missing SINK. So the SOURCE is restored to this planet's warm calibration (FREEZE_T ~13 just above the snow
// line, COLD_SPAN 6, GAIN 8) so genuine convective cells DO reach breakdown, and the fix lives entirely in
// DISSIPATION: (1) the driver-gated decay below, and (2) post-bolt neighbourhood depletion in MaterialCharge3D.
// Snow/freeze is unaffected (that lives in snowice_sphere3d / MaterialReactions3D, FREEZE_TEMP=12.5).
const float FREEZE_T = 13.0;       // top of the charging band (just above the snow line) — warm-planet calibrated
const float COLD_SPAN = 6.0;       // °C below FREEZE_T over which `cold` fades 1 -> 0 (a few degrees of supercooling)
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

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		charge[g] = 0.0;
		return;
	}
	// RELEVANCE-GATED (Keystone C): the build predicate (updraft x cloud, temp<FREEZE_T) is exactly this
	// kernel's own `driven && cold>0` condition, so a gated cell was never about to gain charge this step —
	// but it may still hold RESIDUAL charge from an earlier storm, which must keep decaying even while
	// gated (CHARGE_LEAK_QUIET), or a formerly-charged cell would plateau at a non-zero floor instead of
	// dissipating. This is provably equivalent to what the ungated kernel already does for any non-driven
	// cell (its own `leak` is CHARGE_LEAK_QUIET whenever `driven` is false, independent of gating).
	int stride = stride_for(relevance[g], MAX_STRIDE, 1);
	if (!should_run(params.step_index, g, stride)) {
		charge[g] = charge[g] * (1.0 - CHARGE_LEAK_QUIET);
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
