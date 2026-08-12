#[compute]
#version 450

#include "neighbours.glsli"
#include "cellvol.glsli"

// CUBED-SPHERE GENERIC REACTION ENGINE (Phase B3 §3). ONE data-driven kernel that dissolves a pile of

layout(local_size_x = 64) in;

// --- Reactable channels (binding == slot for the resolved ones; see read_ch/add_ch) -----------------------
layout(set = 0, binding = 0, std430) restrict buffer Temp     { float temp[]; };
layout(set = 0, binding = 1, std430) restrict buffer Water    { float water[]; };
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };
layout(set = 0, binding = 3, std430) restrict buffer O2       { float o2[]; };
layout(set = 0, binding = 4, std430) restrict buffer CO2      { float co2[]; };
// FUEL — cured cellulosic litter, the SAME substance as biomass and detritus. Bound and reactable as of
layout(set = 0, binding = 5, std430) restrict buffer Fuel     { float fuel[]; };
// FIRE — an INSTRUMENT, not a channel and not a reactable slot. Assigned at the bottom of main() as the
layout(set = 0, binding = 6, std430) restrict buffer Fire     { float fire[]; };
layout(set = 0, binding = 7, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 9, std430) restrict buffer Fert { float fert[]; };           // soil nutrient (R15 fungus-decompose + creature excretion feed it; R19 uptake now debits it — LIVE half, its diffuse/leach producer runs later this step, same convention as Fungus above)
layout(set = 0, binding = 11, std430) restrict buffer Biomass { float biomass[]; };    // living plant matter (photosynthesis grows it, respiration/decay oxidizes it)
layout(set = 0, binding = 12, std430) restrict buffer Snow { float snow[]; };          // frozen H₂O (freeze credits it, melt debits it) — SAME substance as water/moisture
// --- MINERAL phases (rock unification): loose sediment, airborne dust, waterborne suspension. Loft (M4) moves
layout(set = 0, binding = 13, std430) restrict buffer Sediment { float sediment[]; };  // loose granular regolith
layout(set = 0, binding = 14, std430) restrict buffer Dust { float dust[]; };           // airborne wind-lofted dust
layout(set = 0, binding = 16, std430) restrict buffer Susp { float susp[]; };           // waterborne suspended sediment
layout(set = 0, binding = 17, std430) restrict readonly buffer VelX { float vel_x[]; }; // horizontal wind (WINDSPEED driver)
layout(set = 0, binding = 18, std430) restrict readonly buffer VelZ { float vel_z[]; };
// --- BEDROCK phase (rock unification Stage B): molten LAVA <-> fractional bedrock ROCK_FILL are the SAME mineral.
layout(set = 0, binding = 22, std430) restrict buffer Lava { float lava[]; };            // molten rock (mass/cell)
layout(set = 0, binding = 23, std430) restrict buffer RockFill { float rock_fill[]; };   // fractional bedrock mass (solid iff >= 0.5)
// --- SUBSURFACE WATER: the aquifer the roots drink from. `soil` is non-zero ONLY in REGOLITH cells —
layout(set = 0, binding = 24, std430) restrict buffer Soil { float soil[]; };
// --- Gate inputs + scratch product target + the record table ----------------------------------------------
layout(set = 0, binding = 10, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };        // idx*6 + slot
layout(set = 0, binding = 20, std430) restrict buffer Scratch { float scratch[]; };         // SCRATCH product target (fungus_fert)
layout(set = 0, binding = 25, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, flat c*3+{0,1,2}
// AQUIFER PERMEABILITY MASK (1 = groundwater-bearing regolith). The mask root_soil() walks — soil lives here,
layout(set = 0, binding = 27, std430) restrict readonly buffer Regolith { float regolith[]; };
// --- THE TWO NON-SILICATE MINERAL SPECIES (2026-08-08). Every mineral channel above is calcium silicate
layout(set = 0, binding = 28, std430) restrict buffer Carbonate { float carbonate[]; };  // CaCO3 — the carbon sink
layout(set = 0, binding = 29, std430) restrict buffer Silica { float silica[]; };        // SiO2 — the residue
// Athy pore fraction (0 outside regolith). Declared HERE, with the other buffers, and not beside the
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
layout(set = 0, binding = 30, std430) restrict buffer N2Buf { float n2[]; };              // dinitrogen, 78% of the air
// Charge (channel units) a lightning return stroke drained from this cell this step. DRIVER ONLY.
layout(set = 0, binding = 31, std430) restrict readonly buffer Discharge { float discharge[]; };

// Slot enum — MUST match MaterialReactions3D.gd.
#define TEMP     0
#define WATER    1
#define MOISTURE 2
#define O2       3
#define CO2      4
#define FUEL     5
#define FIRE     6
#define DETRITUS 7
#define FUNGUS   8
#define FERT     9
#define LAVA     10
#define BIOMASS  11
#define SNOW     12
#define SEDIMENT  13
#define DUST      14
#define SUSP      15
#define WINDSPEED 16   // derived driver: sqrt(vel_x^2 + vel_z^2) — not a stored channel, read-only
#define ROCK_FILL 17   // fractional bedrock mineral mass (solid iff >= 0.5); M5/M6 transfer it with LAVA
#define LIGHT     18   // DERIVED driver: max(0, dot(cell_radial, sun_dir)) — REAL per-cell insolation, the same
                       // quantity heat3d_solar_sphere3d computes, with sun_dir's magnitude carrying intensity
#define SOIL_ROOT 19   // DERIVED, WRITABLE: the plant-available water of the ROOTING COLUMN — the soil summed
                       // over the permeable REGOLITH cells directly beneath this open cell (the regolith mask,
#define VAPOUR_DEFICIT 20  // DERIVED driver: sat(T) - moisture, SIGNED. The phase rule — see sat_mass_frac().
#define SOIL_TOP  21   // DERIVED, WRITABLE: the soil of the FIRST regolith cell beneath this open cell — the
                       // shallow DRYING FRONT. Roots reach the whole rooting column (SOIL_ROOT); evaporation

// --- THE PHASE RULE ----------------------------------------------------------------------------------------
const float MAGNUS_A_PA = 610.94;        // LAPhysical.MAGNUS_A_PA
const float MAGNUS_B = 17.625;           // LAPhysical.MAGNUS_B
const float MAGNUS_C_C = 243.04;         // LAPhysical.MAGNUS_C_C
const float VAPOUR_R = 461.52;           // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float KELVIN_0 = 273.15;           // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;           // LAPhysical.WATER_DENSITY_KG_M3
const float R_GAS = 8.314462618;         // LAPhysical.GAS_CONSTANT_J_MOL_K
const float P_STD = 101325.0;            // LAPhysical.STANDARD_PRESSURE_PA
const float DG_EXP_LIMIT = 60.0;         // exp() argument bound; beyond it the equilibrium bound sets the extent

float sat_mass_frac(float t_c) {
	float t = max(t_c, -80.0);           // the Magnus fit's pole is at -243.04 C
	float e_sat = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C));
	return (e_sat / (VAPOUR_R * max(t + KELVIN_0, 1.0))) / RHO_WATER;
}
#define OVERBURDEN 22  // DERIVED driver: LITHOSTATIC pressure (Pa) of the SOLID column above. See overburden().
#define BEDROCK_BELOW 23 // DERIVED, WRITABLE: the bedrock of the SOLID cell directly beneath this open one —
                       // the rock a surface process actually attacks. Unique per thread; see bedrock_below().
#define CARBONATE 24   // CaCO3, bound at 28 — where weathered carbon goes and where it comes back from
                       // when D1b runs backwards. Own-cell stock; nothing advects it.
#define SILICA    25   // SiO2, bound at 29 — the weathering residue. Nothing weathers it further.
#define N2        26   // dinitrogen, bound at 30 — the nitrogen reservoir lightning fixation draws on
#define DISCHARGE 27   // DERIVED driver only, bound at 31 — charge units this cell's return stroke drained

#define WET_MAX_LOFT 0.05   // water mass above which a surface is WET and can't loft dust (dust_loft parity)
#define REGOLITH_CELLS 4    // rooting depth = the permeable regolith band (MUST match MaterialField3D.REGOLITH_CELLS)
// OVERBURDEN_MAX_CELLS bounds the outward walk. The lithification threshold is reached at four cells of full
#define OVERBURDEN_MAX_CELLS 12
const float ROCK_DENSITY = 2900.0;      // LAPhysical.ROCK_DENSITY_KG_M3 — basalt / crustal rock
const float SEDIMENT_DENSITY = 2000.0;  // LAPhysical.SEDIMENT_DENSITY_KG_M3 — unconsolidated wet sediment
                                        // (absolute temperature for Arrhenius comes from KELVIN_0 above —

// --- A CELL'S VOLUMETRIC HEAT CAPACITY [J/m3/K] ------------------------------------------------------------
const float LOC_MOLE_FRAC = 0.15;          // LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC
const float AIR_O2_MOLE_FRAC_K = 0.20946;  // LAPhysical.AIR_MOLE_FRAC_O2
const float O2_FLAMMABILITY_LIMIT = LOC_MOLE_FRAC / AIR_O2_MOLE_FRAC_K;

#define CONST_FRAC             0
#define BILINEAR               1
#define EXCESS_OVER_THRESHOLD  2
// 3 IS RETIRED AND STAYS UNUSED — it was RELAX_TARGET, whose own definition ("signed; no reactant; product =
#define DEFICIT_BELOW_THRESHOLD 4   // mirror of EXCESS: fires when driver is BELOW threshold (freeze at T<FREEZE_TEMP)
#define OPTIMUM_BAND           5    // x = k * driver * max(0, 1 - ((driver2 - threshold)/param2)^2) — a rate that
                                    // PEAKS at an optimum and falls off BOTH ways. See MaterialReactions3D.gd.
#define ARRHENIUS              6    // x = k * driver * driver2 * exp(-(Ea/R)(1/T - 1/T_ref)) — the temperature
                                    // law of chemistry. threshold = Ea/R (K), param2 = T_ref (K). See ReactionDefs.gd.

#define GATE_NEAR_GROUND 4
#define GATE_DRY         16   // cell is DRY (water <= WET_MAX_LOFT) — sand only lofts when not wet
                              // water=1 and is deliberately not simulated) — real per-cell chemistry only
#define GATE_AIR_ABOVE   128  // THE FREE SURFACE: the outward neighbour is air (not rock, not drowned). A
                              // submerged cell has no air touching it and cannot evaporate. See ReactionDefs.

#define DROWNED_WATER 0.5     // half a cell of standing water in the neighbour above = no free surface here

#define TGT_SELF    0
#define TGT_SCRATCH 3

struct Reaction {
	int   rate_model;
	float rate_k;
	float threshold;
	int   gate_mask;
	int   driver_slot;
	int   driver2_slot;
	int   cap_slot;
	float cap_coeff;
	int   n_react;
	int   n_prod;
	float param2;      // second rate-model scalar (OPTIMUM_BAND: the half-width of the band around `threshold`)
	float t_ceiling_k; // ARRHENIUS: absolute T above which the law stops applying (its phase is gone). 0 = none.
	int   react_slot[4];
	float react_coeff[4];
	int   prod_slot[4];
	float prod_coeff[4];
	int   prod_target[4];
	// --- the 16-byte block the record grew by, 2026-08-09 (see LAReactionDefs.serialize) ---
	float enthalpy_j_m3;  // heat RELEASED (>0) or absorbed (<0) per unit of extent, J per m3 of cell
	int   quench_slot;    // a REACTANT this reaction goes out before exhausting; -1 = none
	float quench_min;     // ...the amount of it the reaction may not draw below (flammability limit)
	int   pad2;
	// --- DIRECTION FROM dG (LAReactionThermo). q_slot < 0 = one-way record, no equilibrium.
	float dg_h_j_mol;      // standard dH per mole of q_slot's substance
	float dg_s_j_molk;     // standard dS, same basis
	int   q_slot;          // the one participant whose activity varies; the rest are pure phases
	float q_pa_per_unit_k; // partial pressure (Pa) one channel unit of q_slot exerts per kelvin
};

layout(set = 0, binding = 21, std430) restrict readonly buffer Defs { Reaction recs[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint n_records;
	uint pad_was_dt;      // rate_k carries its own timebase; a kernel-side dt would double-count it
	// *(Slot 3 held `uint raining` until 2026-08-10 — a GLOBAL boolean that suppressed dust loft over the
	uint pad_was_raining;
	float sun_x;    // world-space vector TOWARD the sun; MAGNITUDE carries insolation (same value ThermalPass
	float sun_y;    // hands heat3d_solar_sphere3d, so light and heat are driven by ONE quantity)
	float sun_z;
	// Pascals of lithostatic pressure per unit of (mass x density) in the column above — i.e. g times the model
	float overburden_pa;
} params;

// REAL per-cell insolation — the LIGHT slot. Identical to the solar kernel's term, so the terminator that
float light_at(uint i) {
	uint rb = i * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	return max(0.0, dot(cell_radial, vec3(params.sun_x, params.sun_y, params.sun_z)));
}

// ROOTING-COLUMN water. `soil` lives in REGOLITH cells, so an open cell's plant-available water is the soil
int top_regolith(uint i) {
	int c = nbr[i * N_SLOTS + N_IN];
	if (c < 0 || regolith[c] == 0.0) {
		return -1;
	}
	return c;
}


float root_soil(uint i) {
	float sum = 0.0;
	int c = nbr[i * N_SLOTS + N_IN];
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		sum += soil[uint(c)] * vol_ratio(uint(c), i);
		if (solid[c] == 0.0) {
			break;                          // an OPEN aquifer cell terminates the walk (see RACE-FREEDOM above)
		}
		c = nbr[uint(c) * N_SLOTS + N_IN];
	}
	return sum;
}

// Draw `amount` of water out of the rooting column, taken from each cell in proportion to what it holds (roots
void root_soil_draw(uint i, float amount) {
	if (amount <= 0.0) {
		return;
	}
	float total = root_soil(i);
	if (total <= 0.0) {
		return;
	}
	float f = min(amount / total, 1.0);
	int c = nbr[i * N_SLOTS + N_IN];
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		soil[uint(c)] = max(0.0, soil[uint(c)] * (1.0 - f));
		if (solid[c] == 0.0) {
			break;
		}
		c = nbr[uint(c) * N_SLOTS + N_IN];
	}
}

// LITHOSTATIC PRESSURE of the column above, in pascals — the OVERBURDEN slot. Walk radially OUTWARD summing
float overburden(uint i) {
	float m = 0.0;
	int c = nbr[i * N_SLOTS + N_OUT];
	for (int k = 0; k < OVERBURDEN_MAX_CELLS; k++) {
		if (c < 0) {
			break;
		}
		// `rock_fill` is a matrix SATURATION, so the mineral actually present is rock_fill * (1 - phi).
		m += rock_fill[uint(c)] * (1.0 - clamp(porosity[uint(c)], 0.0, 1.0)) * ROCK_DENSITY
			+ sediment[uint(c)] * SEDIMENT_DENSITY;
		c = nbr[uint(c) * N_SLOTS + N_OUT];
	}
	return m * params.overburden_pa;
}

// The bedrock of the cell directly BENEATH this open one — the BEDROCK_BELOW slot. Returns 0 when there is no
float bedrock_below(uint i) {
	int d = nbr[i * N_SLOTS + N_IN];
	if (d < 0 || solid[d] == 0.0) {
		return 0.0;
	}
	return rock_fill[uint(d)] * vol_ratio(uint(d), i);
}

void bedrock_below_add(uint i, float v) {
	int d = nbr[i * N_SLOTS + N_IN];
	if (d < 0 || solid[d] == 0.0) {
		return;
	}
	rock_fill[uint(d)] = max(0.0, rock_fill[uint(d)] + v * vol_ratio(i, uint(d)));
}

// See the RC_* block above. Air, rock (bedrock plus whatever is molten) and liquid water by volume fraction.
#include "rc_shared.glsli"

// Resolve a channel slot to its per-cell value. Unbound slots read 0 (a record must not reference them).
float read_ch(int slot, uint i) {
	if (slot == TEMP)     return temp[i];
	if (slot == WATER)    return water[i];
	if (slot == MOISTURE) return moisture[i];
	if (slot == O2)       return o2[i];
	if (slot == CO2)      return co2[i];
	if (slot == FUEL)     return fuel[i];
	if (slot == DETRITUS) return detritus[i];
	if (slot == FUNGUS)   return fungus[i];
	if (slot == FERT)     return fert[i];
	if (slot == BIOMASS)  return biomass[i];
	if (slot == SNOW)     return snow[i];
	if (slot == SEDIMENT) return sediment[i];
	if (slot == DUST)     return dust[i];
	if (slot == SUSP)     return susp[i];
	if (slot == WINDSPEED) return sqrt(vel_x[i] * vel_x[i] + vel_z[i] * vel_z[i]);
	if (slot == LAVA)     return lava[i];
	if (slot == ROCK_FILL) return rock_fill[i];
	if (slot == LIGHT)     return light_at(i);
	if (slot == SOIL_ROOT) return root_soil(i);
	if (slot == VAPOUR_DEFICIT) return sat_mass_frac(temp[i]) - moisture[i];
	if (slot == SOIL_TOP) { int c = top_regolith(i); return (c < 0) ? 0.0 : soil[uint(c)] * vol_ratio(uint(c), i); }
	if (slot == OVERBURDEN) return overburden(i);
	if (slot == BEDROCK_BELOW) return bedrock_below(i);
	if (slot == CARBONATE) return carbonate[i];
	if (slot == SILICA)    return silica[i];
	if (slot == N2)        return n2[i];
	if (slot == DISCHARGE) return discharge[i];
	return 0.0;
}

// Add v to a channel slot (own cell). Mass channels clamp at 0. FUNGUS/LIGHT/unbound slots are not writable as
void add_ch(int slot, uint i, float v) {
	if      (slot == TEMP)     { temp[i]     += v; }
	else if (slot == WATER)    { water[i]     = max(0.0, water[i] + v); }
	else if (slot == MOISTURE) { moisture[i] += v; }
	else if (slot == O2)       { o2[i]        = max(0.0, o2[i] + v); }
	else if (slot == CO2)      { co2[i]       = max(0.0, co2[i] + v); }
	else if (slot == FUEL)     { fuel[i]      = max(0.0, fuel[i]     + v); }   // combustion is fuel's only sink
	else if (slot == DETRITUS) { detritus[i]  = max(0.0, detritus[i] + v); }
	else if (slot == FERT)     { fert[i]      = max(0.0, fert[i] + v); }
	else if (slot == BIOMASS)  { biomass[i]   = max(0.0, biomass[i]  + v); }
	else if (slot == SNOW)     { snow[i]      = max(0.0, snow[i]     + v); }
	else if (slot == SEDIMENT) { sediment[i]  = max(0.0, sediment[i] + v); }
	else if (slot == DUST)     { dust[i]      = max(0.0, dust[i]     + v); }
	else if (slot == SUSP)     { susp[i]      = max(0.0, susp[i]     + v); }
	else if (slot == LAVA)     { lava[i]      = max(0.0, lava[i]     + v); }
	else if (slot == ROCK_FILL) { rock_fill[i] = max(0.0, rock_fill[i] + v); }  // may exceed 1.0 (accreted rock); clamp only at 0
	else if (slot == SOIL_ROOT) { root_soil_draw(i, -v); }                     // roots draw water OUT of the column (v < 0)
	else if (slot == SOIL_TOP)  { int c = top_regolith(i); if (c >= 0) { soil[uint(c)] = max(0.0, soil[uint(c)] + v * vol_ratio(i, uint(c))); } }
	else if (slot == BEDROCK_BELOW) { bedrock_below_add(i, v); }               // weathering eats the outcrop it stands on
	else if (slot == CARBONATE) { carbonate[i] = max(0.0, carbonate[i] + v); } // D1b credits, D1c debits
	else if (slot == SILICA)    { silica[i]    = max(0.0, silica[i]    + v); }
	else if (slot == N2)        { n2[i]        = max(0.0, n2[i]        + v); }
}

// Gate helpers reuse the exact neighbour tests proven in the dissolved kernels.
bool gate_ok(int mask, uint i) {
	if (mask == 0) {
		return true;
	}
	if ((mask & GATE_DRY) != 0) {
		if (water[i] > WET_MAX_LOFT) {
			return false;                   // wet sand / puddle never lofts (dust_loft:53 parity)
		}
	}
	if ((mask & GATE_NEAR_GROUND) != 0) {
		// GROUND-HUGGING: an open cell resting directly ON terrain (its INWARD neighbour, is rock).
		int dn = nbr[i * N_SLOTS + N_IN];
		if (dn < 0 || solid[dn] == 0.0) {
			return false;
		}
	}
	if ((mask & GATE_AIR_ABOVE) != 0) {
		// FREE SURFACE: the outward-radial neighbour must be AIR — open rock-free and not itself drowned.
		int au = nbr[i * N_SLOTS + N_OUT];
		if (au >= 0 && (solid[au] != 0.0 || water[au] >= DROWNED_WATER)) {
			return false;
		}
	}
	return true;
}

// dG = dH - T dS + R T ln Q, Q the activity of the one participant whose activity varies (the rest are pure
// phases at unit activity). Returns the signed direction scale; `x_eq` is the extent that reaches dG = 0.
float direction_scale(Reaction rc, uint i, out float x_eq) {
	x_eq = 0.0;
	float sigma = 0.0;
	float q_coeff = 0.0;
	for (int k = 0; k < rc.n_react; k++) {
		if (rc.react_slot[k] == rc.q_slot) { sigma = -1.0; q_coeff = rc.react_coeff[k]; }
	}
	for (int k = 0; k < rc.n_prod; k++) {
		if (rc.prod_slot[k] == rc.q_slot) { sigma = 1.0; q_coeff = rc.prod_coeff[k]; }
	}
	if (sigma == 0.0) {
		return 1.0;
	}
	float t_k = max(temp[i] + KELVIN_0, 1.0);
	float rt = R_GAS * t_k;
	float pa_per_unit = max(rc.q_pa_per_unit_k * t_k, 1e-30);
	float ch = read_ch(rc.q_slot, i);
	float dg = rc.dg_h_j_mol - t_k * rc.dg_s_j_molk + sigma * rt * log(max(pa_per_unit * ch / P_STD, 1e-30));
	float a_eq = exp(clamp(sigma * (t_k * rc.dg_s_j_molk - rc.dg_h_j_mol) / rt, -DG_EXP_LIMIT, DG_EXP_LIMIT));
	x_eq = (a_eq * P_STD / pa_per_unit - ch) / (sigma * max(q_coeff, 1e-6));
	return 1.0 - exp(clamp(dg / rt, -DG_EXP_LIMIT, DG_EXP_LIMIT));
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	scratch[i] = 0.0;                       // reset per-cell SCRATCH each step (replaces fungus kernel's fert reset)
	fire[i] = 0.0;                          // the burning INSTRUMENT — assigned from this step's fuel loss below
	if (solid[i] != 0.0) {
		return;                             // reactions run in OPEN cells only
	}
	float fuel_before = fuel[i];            // combustion is fuel's only sink
	float o2_before = o2[i];                // the cell's USABLE-oxygen denominator for the fire instrument
	float o2_burn = 0.0;                    // ...and its NUMERATOR: oxygen drawn by COMBUSTION alone, summed below

	for (uint r = 0u; r < params.n_records; r++) {
		Reaction rc = recs[r];
		if (!gate_ok(rc.gate_mask, i)) {
			continue;
		}
		float drv = read_ch(rc.driver_slot, i);
		float x = 0.0;
		if (rc.rate_model == CONST_FRAC) {
			x = rc.rate_k * drv;
		} else if (rc.rate_model == BILINEAR) {
			x = rc.rate_k * drv * read_ch(rc.driver2_slot, i);
		} else if (rc.rate_model == EXCESS_OVER_THRESHOLD) {
			x = max(0.0, drv - rc.threshold) * rc.rate_k;
		} else if (rc.rate_model == DEFICIT_BELOW_THRESHOLD) {
			x = max(0.0, rc.threshold - drv) * rc.rate_k;   // mirror of EXCESS: fires when driver < threshold
		} else if (rc.rate_model == OPTIMUM_BAND) {
			// A rate that PEAKS in the middle and falls off BOTH ways: proportional to `driver`, modulated by a
			float v = read_ch(rc.driver2_slot, i);
			float t = (v - rc.threshold) / max(rc.param2, 1e-6);
			x = rc.rate_k * drv * max(0.0, 1.0 - t * t);
		} else if (rc.rate_model == ARRHENIUS) {
			// The temperature law of chemistry: rate rises exponentially with T at a rate set by the measured
			float conc2 = (rc.driver2_slot >= 0) ? read_ch(rc.driver2_slot, i) : 1.0;
			float t_k = temp[i] + KELVIN_0;
			if (rc.t_ceiling_k > 0.0) {
				t_k = min(t_k, rc.t_ceiling_k);
			}
			float t_ref = max(rc.param2, 1.0);
			x = rc.rate_k * drv * conc2 * exp(-rc.threshold * (1.0 / max(t_k, 1.0) - 1.0 / t_ref));
		}
		// An UNKNOWN rate model now yields x = 0 and the record simply does nothing. It used to fall through

		if (x <= 0.0) {
			continue;
		}
		// The rate model above is the KINETICS. This is the DIRECTION, and it may be negative.
		if (rc.q_slot >= 0) {
			float x_eq = 0.0;
			x *= direction_scale(rc, i, x_eq);
			x = (x > 0.0) ? min(x, max(x_eq, 0.0)) : max(x, min(x_eq, 0.0));
		}
		if (x > 0.0) {
			// Reactant caps: the extent can't drive any reactant (or the aux cap) negative.
			for (int k = 0; k < rc.n_react; k++) {
				float coeff = max(rc.react_coeff[k], 1e-6);
				float avail = read_ch(rc.react_slot[k], i);
				if (rc.react_slot[k] == rc.quench_slot) {
					avail = max(0.0, avail - rc.quench_min);
				}
				x = min(x, avail / coeff);
			}
			if (rc.cap_slot >= 0) {
				x = min(x, read_ch(rc.cap_slot, i) / max(rc.cap_coeff, 1e-6));
			}
		} else {
			// Running BACKWARDS: the products are what gets debited, so they are what bounds the extent.
			for (int k = 0; k < rc.n_prod; k++) {
				if (rc.prod_target[k] == TGT_SCRATCH) {
					continue;
				}
				x = max(x, -read_ch(rc.prod_slot[k], i) / max(rc.prod_coeff[k], 1e-6));
			}
		}
		if (x == 0.0) {
			continue;
		}
		// ATTRIBUTION FOR THE BURNING INSTRUMENT, and it has to happen HERE, inside the loop, against THIS
		bool is_combustion = (rc.driver_slot == FUEL);
		float o2_pre_rec = is_combustion ? o2[i] : 0.0;

		for (int k = 0; k < rc.n_react; k++) {
			add_ch(rc.react_slot[k], i, -rc.react_coeff[k] * x);
		}

		for (int k = 0; k < rc.n_prod; k++) {
			if (rc.prod_target[k] == TGT_SCRATCH) {
				scratch[i] += rc.prod_coeff[k] * x;
			} else {
				add_ch(rc.prod_slot[k], i, rc.prod_coeff[k] * x);
			}
		}

		if (is_combustion) {
			o2_burn += max(0.0, o2_pre_rec - o2[i]);
		}

		// THE ENTHALPY, and it is an ENERGY rather than a mass coefficient for a reason: how hot a cell gets
		if (rc.enthalpy_j_m3 != 0.0) {
			temp[i] += rc.enthalpy_j_m3 * x / max(rc_of(i), 1.0);
		}
	}

	// THE BURNING INSTRUMENT. `fire` is not a state any more: a cell is burning if its combustion RATE is
	if (fuel_before > 0.0) {
		// FIRE IS THE FRACTION OF THIS CELL'S USABLE OXYGEN THAT COMBUSTION CONSUMED THIS STEP.
		float o2_usable = max(0.0, o2_before - O2_FLAMMABILITY_LIMIT);
		fire[i] = (o2_usable > 0.0) ? clamp(o2_burn / o2_usable, 0.0, 1.0) : 0.0;
	}
}
