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
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float aw_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };            // debited in place (DYNAMIC only)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer AirOut { float aw_out[]; };
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
const float BOIL_TEMP = 100.0;
const float BOIL_RATE = 0.02;
const float BOIL_MAX_FRAC = 0.5;
const float STATIC_STEAM_MASS = 0.1;

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

	float added = 0.0;   // moisture gained this step
	float debit = 0.0;   // DYNAMIC water drained this step (0 for the infinite static sea)

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
			added += e * params.static_brake; // infinite reservoir: gain without draining, GLOBALLY bounded so the
			                                  // total atmospheric H2O can't run away — the sea stops pumping once
			                                  // cloud cover reaches its target (a steady deck, not a creeping snow-out)
		} else {
			e = min(e, water[g]);             // never drive water below 0
			added += e;
			debit += e;
		}
	}

	// BOILING — a wet cell hot enough flashes standing water to rising steam (open air not required).
	if (temp[g] > BOIL_TEMP) {
		float bfrac = clamp((temp[g] - BOIL_TEMP) * BOIL_RATE, 0.0, BOIL_MAX_FRAC);
		if (is_static) {
			added += bfrac * STATIC_STEAM_MASS * params.static_brake;
		} else if (water[g] > WATER_MIN) {
			float b = min(water[g] * bfrac, water[g] - debit);
			if (b > 0.0) {
				added += b;
				debit += b;
			}
		}
	}

	aw_out[g] = aw + added;
	if (debit > 0.0) {
		water[g] = water[g] - debit;
	}
}
