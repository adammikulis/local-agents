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
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };              // settled temp (Thermal back) — WARMED/COOLED in place by the latent heat
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };      // settled moisture (Atmosphere back) — debited
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Water { float water[]; };   // heat-capacity term only
layout(set = 0, binding = 5, std430) restrict readonly buffer RockFill { float rock_fill[]; };  // heat-capacity term only
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
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_TEMP_REF = 22.0;
const float SNOW_MIN = 0.001;        // clamp dust-thin snow to 0
const float SUBLIMATE_FRAC = 0.004;  // per-step fraction of the snowpack that sublimates back to moisture, so
                                     // deposition balances at a STEADY snow line instead of an unbounded snow-out

// ===== LATENT HEAT OF DEPOSITION / SUBLIMATION =====================================================
// The unit derivation, the enthalpy convention and the areal heat capacities are stated ONCE, in
// atmos_evap_sphere3d.glsl. Both legs here move water between the VAPOUR store (`moisture`) and the SOLID
// store (`snow`) with no liquid in between, so both pay the full sublimation enthalpy — vaporisation plus
// fusion, 2.83e6 J/kg — not one or the other. Until 2026-08-03 both were free: frost formed on cold ground
// without warming it and a snowpack sublimated away without cooling anything, which is backwards from what
// a snowfield actually does to the air above it.
//
// BOTH SIGNS MATTER, and they are not symmetric in effect. DEPOSITION warms, and it is the reason a real
// frost or snowfall is a warming event for the surface it lands on. SUBLIMATION cools, and it is why a
// sunlit high snowfield stays cold instead of melting: the pack loses mass to the air and takes the
// enthalpy with it. This kernel already had the mass half of both and neither energy half.
const float CAP_AIR = 345600.0;      // MUST equal heat3d_solar_sphere3d.glsl:135-138
const float CAP_ROCK = 604800.0;
const float CAP_WATER = 3888000.0;
const float CAP_SNOW = 1080000.0;
const float WATER_SPECIFIC_HEAT = 4184.0;   // LAPhysical.WATER_SPECIFIC_HEAT_J_KGK
const float LATENT_SUB = 2.83e6;            // LAPhysical.LATENT_HEAT_SUBLIMATION_J_KG — solid<->vapour at 0 C
const float H2O_KG_PER_M2_PER_UNIT = CAP_WATER / WATER_SPECIFIC_HEAT;

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
	float snow0 = max(snow[idx], 0.0);          // START-of-step snow, for the latent-heat capacity below.
	                                            // NOT clamped to 1 — see note (4) in atmos_evap_sphere3d:
	                                            // a 20-unit pack sublimates 20x the mass, so clamping its
	                                            // inertia at 1 unit made the cooling 20x too big and drove
	                                            // temp_min to -3434 C, below absolute zero.
	float moist0 = max(moisture[idx], 0.0);     // suspended water — its own heat capacity, same note
	float deposited = 0.0;                      // net VAPOUR -> SOLID this step (negative = net sublimation)
	// The saturation the whole cell is measured against — ONE value for both legs below, because deposition
	// and sublimation are the two directions of the SAME equilibrium and cannot both be right at once.
	float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (st - EVAP_TEMP_REF));
	if (st < FREEZE_TEMP) {
		// DEPOSITION: freeze the CONDENSED part of the air's water (moisture over saturation) — the fog/low
		// cloud resting on this cold ground — into snow. Conserving: whatever leaves moisture arrives as snow.
		float condensed = max(0.0, moisture[idx] - sat);
		if (condensed > 0.0) {
			float x = condensed * DEPOSIT_FRAC;
			moisture[idx] -= x;
			snow[idx] += x;
			deposited += x;
		}
	}

	// SUBLIMATION — the snowpack's steady-state SINK. Snow deposition alone is one-way on ground that never warms
	// past MELT_TEMP (the poles / high peaks), so snow ACCUMULATED without bound — a creeping snow-out that buried
	// the grazable land and starved the herds over a long run. Real snow also leaves the pack by SUBLIMATING
	// straight back to vapour (even well below freezing, driven by dry air + sun). A small per-step fraction
	// returns to moisture, so deposition and sublimation balance at a STEADY snow line (persistent polar snow +
	// sea ice remain — they just stop growing forever). Conserving: snow → moisture (the H₂O ledger is preserved).
	//
	// GATED ON THE VAPOUR DEFICIT as of 2026-08-03, and this is a physics fix, not a tuning one. The rate was a
	// bare constant fraction with NO dependence on the air it sublimates INTO, so a cell could deposit (because
	// its air was supersaturated) and sublimate (because the constant said so) in the same step — the two
	// directions of one equilibrium, both running at once. A phase change runs TOWARD equilibrium and stops
	// there: ice loses mass to air that is dry with respect to ice and gains it from air that is not. So the
	// rate now scales with the DEFICIT (sat - moisture)/sat and is zero when the air is already saturated.
	//
	// This is what makes the latent-heat term above physically closed rather than a one-way heat pump. Free
	// sublimation cost nothing, so an unconditional 0.4% per step was harmless bookkeeping. Charged at the real
	// 2.83e6 J/kg it takes 9.7 K out of a snow-dominated cell EVERY step, and with no equilibrium to stop it
	// the pack cooled without bound — measured on the first build of this change, temp_min reached -926 C,
	// well below absolute zero. The deficit gate is the physical reason it stops, and the latent heat is what
	// makes it stop: deposition WARMS the cell, warmth raises sat exponentially, and a warmer cell condenses
	// less. That negative feedback is exactly what SUBLIMATE_FRAC was standing in for as an unconditional sink.
	float deficit = clamp((sat - moisture[idx]) / max(sat, 1.0e-9), 0.0, 1.0);
	float subl = snow[idx] * SUBLIMATE_FRAC * deficit;
	if (subl > 0.0) {
		snow[idx] -= subl;
		moisture[idx] += subl;
		deposited -= subl;
	}

	if (snow[idx] < SNOW_MIN) {
		moisture[idx] += snow[idx];   // return the dust-thin remnant to the air (CONSERVING) instead of deleting
		deposited -= snow[idx];       // it — else the conserved water+moisture+snow+soil ledger slowly leaks here.
		snow[idx] = 0.0;              // This is solid -> vapour too, so it pays the same enthalpy as any other
	}                                 // sublimation; charging the mass but not the heat would leak energy instead.

	// LATENT HEAT OF DEPOSITION / SUBLIMATION — one signed exchange for the net vapour<->solid transfer this
	// cell just made, over the same areal heat capacity the energy balance assembles from its contents.
	// Positive `deposited` = vapour became ice = heat RELEASED into the cell; negative = ice became vapour =
	// heat TAKEN OUT of it. Capacity uses the START-of-step snow so it describes the cell the transfer
	// happened in.
	if (deposited != 0.0) {
		float cap = CAP_AIR
			+ CAP_ROCK  * clamp(rock_fill[idx], 0.0, 1.0)
			+ CAP_WATER * clamp(water[idx], 0.0, 1.0)
			+ CAP_WATER * moist0
			+ CAP_SNOW  * snow0;
		temp[idx] = temp[idx] + (deposited * H2O_KG_PER_M2_PER_UNIT * LATENT_SUB) / cap;
	}
}
