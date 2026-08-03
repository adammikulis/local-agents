#[compute]
#version 450

// CUBED-SPHERE atmosphere EVAPORATION + BOILING — the CONSERVING water→moisture transfer of the unified
// water cycle. There is now ONE atmospheric water channel `moisture` (total water suspended in a cell's
// air); vapor/cloud/fog are DERIVED at read time from moisture vs sat(T), so this kernel only moves the
// true mass. A warm exposed water surface (a wet cell with open air above) releases moisture into its OWN
// cell — more when warm — and DEBITS the same mass from DYNAMIC water (mass-conserving; fixes the old
// non-conserving evap that created vapor from nothing). The calm STATIC field sea is an INFINITE
// evaporation reservoir: it ADDS moisture without debiting (its cells hold no simulated water to drain).
// BOILING is folded in here (was a separate condense-kernel step): a cell hotter than BOIL_TEMP flashes
// extra water→moisture, debiting dynamic water (static cells steam a tiny fixed amount, no debit).
// The only cross-cell read is the "open air ABOVE" test — the OUTWARD radial neighbour (slot 5).
//
// EVAPORATION COOLS THE SURFACE, which until 2026-08-03 it did not. This kernel moved mass and nothing
// else: water became airborne with no energy leaving the cell it left. That is the largest single heat
// sink on an ocean planet's surface (~80 W/m² globally on Earth, against ~340 W/m² absorbed) simply
// missing, and it is a perpetual-motion machine — run the cycle round (evaporate here, rain there) and the
// planet has moved water for free. The LATENT HEAT block below is the repair. `Temp` was `readonly`; it is
// written now, in place, in the same cell whose water left.
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float aw_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };              // COOLED in place by the latent heat carried away
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };            // debited in place (DYNAMIC only)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer AirOut { float aw_out[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Snow { float snow[]; };     // heat-capacity term only
layout(set = 0, binding = 7, std430) restrict readonly buffer RockFill { float rock_fill[]; };  // heat-capacity term only
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float static_brake;   // 0..1 GLOBAL bound: scales the INFINITE static-sea moisture add. 1 = pump freely,
	                      // 0 = sea holds (atmosphere is at its target cloud cover). Dynamic-water evap is NOT
	                      // gated by this, so the water cycle keeps running; only the un-conserving source tapers.
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match the query-side sat()/evap math in MaterialField3D.gd + the box heritage.
const float EVAP_RATE = 0.007;   // slowed: the infinite static-sea reservoir pumped moisture faster than rain drained
                                 // it, so atmospheric moisture ran away (~11x over 2000 frames) and snowed out onto the
                                 // highlands, a creeping cold drift that froze the habitable band mid-run (population sustain)
const float EVAP_WARM_K = 0.11;  // Clausius–Clapeyron slope: e ~ exp((T-REF)*k). Cold land water barely evaporates
                                 // (rivers persist); the warm sea evaporates hard (drives the cycle).
const float WATER_MIN = 0.05;
const float EVAP_TEMP_REF = 22.0;
const float MAX_MASS = 1.0;
// SATURATION / HUMIDITY BRAKE — the stabilizing negative feedback that BOUNDS the moisture pump. Physically a
// surface cannot keep evaporating into air that is already saturated: the closer the local air is to holding all
// the water it can, the slower net evaporation runs (real Clausius–Clapeyron limit). Without this the infinite
// static-sea reservoir added moisture every step regardless of how humid the column already was, so atmospheric
// moisture RAN AWAY (~11x over 2000 frames), cloud cover climbed toward 1.0, that dimmed insolation (SystemOrbits
// transmission), the surface drifted monotonically cold, and colder air condensed still more cloud — an UNBOUNDED
// cloud→cooling feedback that froze the habitable band. The brake caps the CONDENSED load (moisture over sat(T),
// the part that becomes cloud) each cell can build from local evaporation: evaporation tapers linearly to zero as
// condensed → EVAP_COND_CEIL. Advection/uplift/night-cooling can still pile a cell past this to rain (the cycle
// keeps running); what stops is the runaway SOURCE. sat() curve constants MUST match atmos_precip/snowice/MaterialField.
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_COND_CEIL = 0.30;  // condensed (cloud) headroom above saturation at which local evaporation stops
                                    // (> atmos_precip RAIN_MASS_THRESHOLD=0.14 so convergence zones still rain first)
const float BOIL_TEMP = 100.0;      // LAPhysical.WATER_BOIL_C — the phase boundary, not a tunable
const float BOIL_RATE = 0.02;
const float BOIL_MAX_FRAC = 0.5;
const float STATIC_STEAM_MASS = 0.1;

// ===== LATENT HEAT — THE DERIVATION, STATED ONCE FOR ALL FOUR H₂O CHANNELS ==========================
// This block is the authority the other phase-change kernels (atmos_precip, snowice) point back at. Read
// it once here rather than re-deriving it three times.
//
// (1) WHAT ONE UNIT OF THE CHANNEL WEIGHS. The channels are dimensionless fills, so the mass has to come
//     from somewhere else in the model, and there is exactly one place that already states it: the AREAL
//     HEAT CAPACITIES the solar kernel uses. An areal heat capacity is an areal MASS times a specific
//     heat — cap [J/m²/K] = m [kg/m²] * c [J/kg/K] — so CAP_WATER, which heat3d_solar_sphere3d.glsl:224
//     adds for a cell whose `water` channel reads 1.0, fixes that cell's water mass at
//          H2O_KG_PER_M2_PER_UNIT = CAP_WATER / WATER_SPECIFIC_HEAT = 3888000 / 4184 = 929.3 kg/m²
//     which is the 0.932 m depth of water the solar kernel's own capacity block already quotes. Nothing is
//     chosen here: given CAP_WATER, this number is forced.
//
//     It is written as the QUOTIENT, not as 929.3, on purpose. Those areal capacities are under review
//     (the solar kernel records that CAP_WATER implies ~0.93 m of ocean where a real mixed layer is
//     20-100 m). When CAP_WATER moves, this moves with it and stays correct.
//
//     THE CONVERSION IS AMBIGUOUS IN THE TREE AND THIS IS THE BRANCH TAKEN. A second, INCOMPATIBLE
//     convention exists: the field's own geometry, where LAPhysical.GROUNDWATER_CIRCULATION_M = 2000 m
//     spans REGOLITH_CELLS = 4 cells, making a cell ~500 model metres tall and a full water cell
//     ~5e5 kg/m² — 536x heavier than the line above. The two disagree because the heat capacities were
//     legacy model numbers reinterpreted as SI, not measured against the grid. The capacity branch is
//     taken because it is the one the ENERGY BUDGET uses, and this is an energy exchange: it makes latent
//     and sensible heat commensurate inside one budget, which is the property that matters. Note that the
//     result barely depends on the choice — see (3).
//
// (2) THE ENTHALPY CONVENTION, so the loop closes exactly. Each channel carries the enthalpy of its own
//     phase: `water` is liquid, `moisture` is VAPOUR, `snow` is solid. Every transition therefore pays or
//     collects the difference, in the cell where it happens:
//          water   -> moisture   evaporation/boiling   ABSORBS L_v      (here)
//          moisture-> water      rain shedding         RELEASES L_v     (atmos_precip)
//          moisture-> snow       deposition            RELEASES L_s     (snowice)
//          snow    -> moisture   sublimation           ABSORBS L_s      (snowice)
//          water  <-> snow       freeze/melt           +/- L_f          (reaction records R21/R22)
//     Round any closed path and the enthalpy sums to zero, which is what makes the water cycle stop being
//     a free energy source. Falling RAIN carries no latent term — it is already liquid, and charging it
//     again on landing would create the heat twice; see atmos_rain_sphere3d.
//
// (3) WHAT THE COOLING ACTUALLY WORKS OUT TO, because it is worth seeing that it is not adjustable. For a
//     cell the sea dominates, cap ≈ CAP_AIR + CAP_WATER, so
//          dT = -e * (CAP_WATER / c) * L_v / cap  ≈  -e * L_v / c  =  -e * 585 K
//     The unit conversion cancels: L_v/c is just "evaporating a mass of water absorbs what cooling that
//     same mass by 585 K would". So the cooling per step is set by the evaporated FRACTION and by two
//     measured properties of water, and by nothing this file can tune. If that comes out large, the
//     finding is about the evaporation RATE, not about the latent heat.
//
// (4) TWO TERMS THE SOLAR KERNEL'S CAPACITY OMITS, AND WHY THEY ARE INCLUDED HERE. That kernel writes
//     `CAP_WATER * clamp(water,0,1) + CAP_SNOW * clamp(snow,0,1)` and does not count the airborne water at
//     all. Both omissions are harmless for a radiative flux and are NOT harmless for a phase change,
//     because a phase change's energy is proportional to the MASS that changed phase while the temperature
//     change is that energy over the capacity — so if the mass is uncounted in the capacity, the same
//     transfer produces an unbounded dT:
//       * SNOW IS NOT BOUNDED to 1 the way `water` is (MAX_MASS caps water; nothing caps a snowpack). A
//         cell holding 20 units of snow sublimates 20x the mass of a cell holding 1, so clamping its
//         capacity at 1 unit makes the cooling 20x too large. Measured on the first build of this change:
//         deep polar snow drove temp_min to -3434 C, which is below absolute zero.
//       * SUSPENDED WATER carries its own heat capacity. Condensation releases its enthalpy into the whole
//         parcel — the air AND the water in it — and in a cloud cell the water is the larger half.
//     Both are counted below. (Liquid water's specific heat is used for the suspended part rather than
//     vapour's, because in this model `moisture` above sat(T) IS the cloud/fog liquid; it is an
//     approximation for the sub-saturation part and it is stated rather than hidden.)
const float CAP_AIR = 345600.0;      // MUST equal heat3d_solar_sphere3d.glsl:135-138 — the same areal heat
const float CAP_ROCK = 604800.0;     // capacities the energy balance uses, so latent and radiative heat
const float CAP_WATER = 3888000.0;   // land in ONE budget. Change them there and here in the same edit.
const float CAP_SNOW = 1080000.0;
const float WATER_SPECIFIC_HEAT = 4184.0;   // LAPhysical.WATER_SPECIFIC_HEAT_J_KGK
const float LATENT_VAP = 2.45e6;            // LAPhysical.LATENT_HEAT_VAPORISATION_J_KG — liquid<->vapour at 20 C
const float LATENT_VAP_BOIL = 2.26e6;       // LAPhysical.LATENT_HEAT_VAPORISATION_BOIL_J_KG — at 100 C
const float H2O_KG_PER_M2_PER_UNIT = CAP_WATER / WATER_SPECIFIC_HEAT;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);

	float aw = aw_in[g];
	if (solid[g] != 0.0) {
		aw_out[g] = aw;
		return;
	}

	bool is_static = static_cells[g] != 0.0;
	float wet0 = clamp(water[g], 0.0, 1.0);   // START-of-step water, for the latent-heat capacity below
	// A cell must be a wet SURFACE (dynamic water above WATER_MIN, or a calm static-sea cell) to feed air.
	if (water[g] <= WATER_MIN && !is_static) {
		aw_out[g] = aw;
		return;
	}

	// Open air ABOVE = the OUTWARD radial neighbour (slot 5) is non-solid and not itself half-full of water
	// (so only the air/water interface feeds humidity). At the outward boundary (slot5 == -1 = open space)
	// the air above is open — matching the box "top of world = open" branch.
	int au = nbr[idx * 6 + 5];
	bool open_above = true;
	if (au >= 0) {
		open_above = (solid[au] == 0.0 && water[au] < MAX_MASS * 0.5);
	}

	float added = 0.0;        // moisture gained this step
	float debit = 0.0;        // DYNAMIC water drained this step (0 for the infinite static sea)
	float vap_ambient = 0.0;  // of `added`, the part that left at ambient temperature (pays LATENT_VAP)
	float vap_boil = 0.0;     // of `added`, the part that flashed at 100 C     (pays LATENT_VAP_BOIL)

	// EVAPORATION — from an exposed surface, rising STEEPLY with temperature (Clausius–Clapeyron: saturation
	// vapour pressure is exponential in T, not linear). This is what lets surface water PERSIST on cool land:
	// a warm equatorial SEA cell (~35°C) evaporates hard and drives the moisture cycle, while a cold highland
	// river/lake/meltwater cell (~8-14°C) barely evaporates, so spring- and rain-fed streams survive long enough
	// to pool in basins and run to the sea = visible rivers/lakes emerge (the old linear T/22 stripped cold
	// water almost as fast as warm, so nothing on land ever accumulated). EVAP_WARM_K sets the exponential
	// slope; the clamp keeps a hot sea from runaway steaming.
	if (open_above) {
		float warmth = clamp(exp((temp[g] - EVAP_TEMP_REF) * EVAP_WARM_K), 0.0, 2.5);
		float e = EVAP_RATE * warmth;
		// HUMIDITY BRAKE (the bound): taper evaporation to zero as this cell's air approaches its condensed
		// ceiling, so a saturated column stops pumping — the negative feedback that settles cloud cover instead
		// of letting it run away. sat rises with T (warm air holds more), so the warm sea keeps evaporating while
		// an already-cloudy cold column shuts its own source off.
		float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (temp[g] - EVAP_TEMP_REF));
		float condensed = max(0.0, aw - sat);
		float humid_brake = clamp(1.0 - condensed / EVAP_COND_CEIL, 0.0, 1.0);
		e *= humid_brake;
		if (is_static) {
			float s = e * params.static_brake; // infinite reservoir: gain without draining, GLOBALLY bounded so the
			                                  // total atmospheric H2O can't run away — the sea stops pumping once
			                                  // cloud cover reaches its target (a steady deck, not a creeping snow-out)
			added += s;
			// The static sea's MASS is not debited (a standing matter-conservation violation, not this
			// kernel's to fix), but its HEAT is. The cell is real seawater — _seed_sphere_sea sets
			// water = 1.0 there, so it carries CAP_WATER of thermal inertia — and water leaving a real sea
			// surface takes its vaporisation enthalpy out of that sea. Skipping the sink here because the
			// mass is fictional would leave evaporation free over exactly the cells that do most of it.
			vap_ambient += s;
		} else {
			e = min(e, water[g]);             // never drive water below 0
			added += e;
			debit += e;
			vap_ambient += e;
		}
	}

	// BOILING — a wet cell hot enough flashes standing water to rising steam (open air not required).
	if (temp[g] > BOIL_TEMP) {
		float bfrac = clamp((temp[g] - BOIL_TEMP) * BOIL_RATE, 0.0, BOIL_MAX_FRAC);
		if (is_static) {
			float sb = bfrac * STATIC_STEAM_MASS * params.static_brake;
			added += sb;
			vap_boil += sb;
		} else if (water[g] > WATER_MIN) {
			float b = min(water[g] * bfrac, water[g] - debit);
			if (b > 0.0) {
				added += b;
				debit += b;
				vap_boil += b;
			}
		}
	}

	aw_out[g] = aw + added;
	if (debit > 0.0) {
		water[g] = water[g] - debit;
	}

	// LATENT HEAT OF VAPORISATION — the cell pays for the phase change it just performed. See the
	// derivation block above: channel units -> kg/m² through CAP_WATER / c, times L_v, over the SAME areal
	// heat capacity the energy balance assembles from this cell's own contents. Boiling water leaves at
	// 100 C and pays the smaller 100 C enthalpy; everything else leaves at ambient and pays the 20 C one.
	//
	// The capacity is taken from the START-of-step contents (wet0), matching the snapshot the solar kernel
	// sees, so the debit and the capacity describe the same cell rather than the cell before and after.
	if (vap_ambient > 0.0 || vap_boil > 0.0) {
		float cap = CAP_AIR
			+ CAP_ROCK  * clamp(rock_fill[g], 0.0, 1.0)
			+ CAP_WATER * wet0
			+ CAP_WATER * max(aw, 0.0)               // the water already suspended here — see (4)
			+ CAP_SNOW  * max(snow[g], 0.0);         // NOT clamped to 1: a deep pack has deep inertia
		float joules = (vap_ambient * LATENT_VAP + vap_boil * LATENT_VAP_BOIL) * H2O_KG_PER_M2_PER_UNIT;
		temp[g] = temp[g] - joules / cap;
	}
}
