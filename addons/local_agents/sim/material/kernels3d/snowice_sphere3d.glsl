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
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };              // settled temp (Thermal back) — WARMED by the deposition enthalpy below (was readonly)
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };      // settled moisture (Atmosphere back) — debited
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Water { float water[]; };   // heat-capacity mix only
layout(set = 0, binding = 5, std430) restrict readonly buffer RockFill { float rock_fill[]; };  // heat-capacity mix only
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };      // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Phase-change + saturation constants — MUST match MaterialReactions3D.gd (FREEZE_TEMP) + the atmos kernels (sat curve).
const float FREEZE_TEMP = 0.0;      // LAPhysical.WATER_FREEZE_C — the phase boundary, not a tunable      // water freezes at zero, as it should — see MaterialReactions3D
const float DEPOSIT_FRAC = 0.10;     // fraction of the condensed excess frozen out per step (gradual snowpack build)
const float SNOW_MIN = 1.0e-9;       // clamp numerically-dust-thin snow to 0 (was 1e-3, which is a real 16 mm
                                     // of water equivalent — a threshold in the same units the sky now works
                                     // in would delete an entire season's snowfall as a rounding error)
// The saturation curve, one function — see atmos_precip_sphere3d.glsl's block for what it replaced.
const float MAGNUS_A_PA = 610.94;    // LAPhysical.MAGNUS_A_PA
const float MAGNUS_B = 17.625;       // LAPhysical.MAGNUS_B
const float MAGNUS_C_C = 243.04;     // LAPhysical.MAGNUS_C_C
const float VAPOUR_R = 461.52;       // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float KELVIN_0 = 273.15;       // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;       // LAPhysical.WATER_DENSITY_KG_M3

float sat_mass_frac(float t_c) {
	float t = max(t_c, -80.0);
	float e_sat = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C));
	return (e_sat / (VAPOUR_R * max(t + KELVIN_0, 1.0))) / RHO_WATER;
}

// ===== THE LATENT HEAT OF DEPOSITION =======================================================================
// Vapour going straight to ice releases the FULL enthalpy of sublimation — the heat of vaporisation plus the
// heat of fusion, because the substance skips the liquid entirely. LAPhaseRecords R25 charges the reverse
// (snow -> moisture) exactly this much, so the pair is equal and opposite and a cell that deposits and
// sublimates repeatedly ends where it started. Before 2026-08-07 neither leg was charged and snow could form
// out of the air for free, which is heat appearing from nothing at every snowfall.
const float LATENT_SUBLIMATION = 2.8347e6;   // LAPhysical.LATENT_HEAT_SUBLIMATION_J_KG
const float RC_ROCK  = 2.436e6;             // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_AIR   = 1186.0;              // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_WATER = 4.171e6;             // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
const float RC_SNOW  = 6.27e5;              // LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K

// Identical text to heat_sphere3d.glsl's rc_of — the same cell must hold the same heat here as it does in
// conduction. (Lava is absent from this mix as it is there; a cell depositing snow is below freezing.)
float rc_of(uint i) {
	if (solid[i] != 0.0) {
		return RC_ROCK;
	}
	float f_rock = clamp(rock_fill[i], 0.0, 1.0);
	float f_water = clamp(water[i], 0.0, 1.0);
	float f_snow = clamp(snow[i], 0.0, 1.0);
	float f_air = max(0.0, 1.0 - f_rock - f_water - f_snow);
	return RC_AIR * f_air + RC_ROCK * f_rock + RC_WATER * f_water + RC_SNOW * f_snow;
}

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
	float rc_cell = max(rc_of(idx), 1.0);
	float dt_per_unit = RHO_WATER * LATENT_SUBLIMATION / rc_cell;   // K of warming per unit deposited
	if (st < FREEZE_TEMP) {
		// DEPOSITION: freeze the CONDENSED part of the air's water (moisture over saturation) — the fog/low
		// cloud resting on this cold ground — into snow. Conserving: whatever leaves moisture arrives as snow.
		float condensed = max(0.0, moisture[idx] - sat_mass_frac(st));
		if (condensed > 0.0) {
			float x = condensed * DEPOSIT_FRAC;
			// SELF-ARREST AT THE PHASE BOUNDARY, the same rule the reaction engine applies: the heat this
			// releases warms the cell, and at FREEZE_TEMP there is no longer ice forming out of the air — what
			// condenses there is liquid. So it may carry the cell TO the boundary and no further. Physics, not
			// a clamp: it is the latent-heat plateau, and without it a humid cell could jump degrees past 0 °C
			// in one step and then melt the snow it had just made.
			x = min(x, (FREEZE_TEMP - st) / dt_per_unit);
			if (x > 0.0) {
				moisture[idx] -= x;
				snow[idx] += x;
				temp[idx] = st + x * dt_per_unit;
			}
		}
	}

	// SUBLIMATION LIVES IN THE REACTION TABLE NOW (LAPhaseRecords R25), driven by the same saturation deficit
	// as evaporation from water and soil. What was here was `snow * 0.004` per step: a sink that ran at one
	// speed in bone-dry desert air and in saturated polar air alike, because it never looked at the humidity
	// that actually drives sublimation. It existed to stop an unbounded snow-out, which was itself a symptom
	// of a sky holding 3080x too much water. One rule, three reservoirs, no per-phase rate.

	if (snow[idx] < SNOW_MIN) {
		float remnant = snow[idx];
		moisture[idx] += remnant;     // return the dust-thin remnant to the air (CONSERVING) instead of deleting
		snow[idx] = 0.0;              // it — else the conserved water+moisture+snow+soil ledger slowly leaks here
		// It is still a phase change, so it still costs the sublimation enthalpy (the cell COOLS). At under
		// 1e-9 of a cell that is ~0.002 K and it fires once per cell as the pack empties, but an unpaid
		// transition is an unpaid transition — this is exactly the size of leak that adds up over 69120 cells.
		temp[idx] -= remnant * RHO_WATER * LATENT_SUBLIMATION / rc_cell;
	}
}
