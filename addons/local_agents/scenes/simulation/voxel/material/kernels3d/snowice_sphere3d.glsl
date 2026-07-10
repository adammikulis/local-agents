#[compute]
#version 450

// CUBED-SPHERE SNOW DEPOSITION — the sat(T)-aware SNOWFALL leg of the unified H₂O cycle (Phase 2c). H₂O is ONE
// conserved substance in three phases (MOISTURE in the air, WATER on the ground, SNOW frozen); the phase is
// emergent from temperature. This kernel owns the ONE transition the generic DEFS reaction engine can't express
// (it has no saturation curve): freezing the CONDENSED atmospheric water directly out of the air onto cold
// ground as snow — deposition / snowfall / hoar frost. Everything else about snow is now records in
// MaterialReactions3D.gd: FREEZE (liquid water → snow, R21) and MELT (snow → water, R22). The old melt branch
// and the non-conserving global-`precip`×rate accretion branch are DELETED — this kernel is deposition-only and
// MASS-CONSERVING (snow += x; moisture -= x, so H₂O total = water + moisture + snow is preserved).
//
// GROUND-SURFACE gate (kept from the box heritage — the genuinely-special part): snow accretes ON THE TERRAIN,
// not at the top of the atmosphere, so a cell qualifies only if it is OPEN (solid == 0) and its INWARD-radial
// neighbour (slot 0) is solid ground. That is where FOG (cool near-ground condensate) sits, so cold humid
// ground freezes its suspended water into a snowpack. Each qualifying cell touches only its own snow[idx] and
// moisture[idx] → race-free. FREEZE_TEMP + the sat() curve MUST match MaterialReactions3D.gd / the atmos kernels.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Snow { float snow[]; };              // per-cell frozen depth (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };     // settled temp (Thermal back)
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };      // settled moisture (Atmosphere back) — debited
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };      // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Phase-change + saturation constants — MUST match MaterialReactions3D.gd (FREEZE_TEMP) + the atmos kernels (sat curve).
const float FREEZE_TEMP = 12.5;      // below this a cold ground cell freezes its condensed moisture to snow
const float DEPOSIT_FRAC = 0.10;     // fraction of the condensed excess frozen out per step (gradual snowpack build)
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_TEMP_REF = 22.0;
const float SNOW_MIN = 0.001;        // clamp dust-thin snow to 0

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not a snow surface
	}
	// GROUND-SURFACE air cell: open, and its inward-radial neighbour (slot 0) is solid ground.
	int down = nbr[idx * 6u + 0u];
	if (down < 0 || solid[down] == 0.0) {
		return;                                            // no ground directly below -> not a snow surface
	}

	float st = temp[idx];
	if (st < FREEZE_TEMP) {
		// DEPOSITION: freeze the CONDENSED part of the air's water (moisture over saturation) — the fog/low
		// cloud resting on this cold ground — into snow. Conserving: whatever leaves moisture arrives as snow.
		float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (st - EVAP_TEMP_REF));
		float condensed = max(0.0, moisture[idx] - sat);
		if (condensed > 0.0) {
			float x = condensed * DEPOSIT_FRAC;
			moisture[idx] -= x;
			snow[idx] += x;
		}
	}

	if (snow[idx] < SNOW_MIN) {
		snow[idx] = 0.0;
	}
}
