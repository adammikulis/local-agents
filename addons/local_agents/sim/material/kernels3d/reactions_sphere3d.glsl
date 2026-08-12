#[compute]
#version 450

#include "neighbours.glsli"

layout(set = 0, binding = 48, std430) restrict readonly buffer Grav { float g_field[]; };
#include "cellvol.glsli"

// GENERIC REACTION ENGINE. One data-driven kernel: every same-cell reaction is a record in the Defs buffer.
// Kinetics come from the rate model, direction from dG (see direction_scale).

layout(local_size_x = 64) in;

// --- Reactable channels (binding == slot for the resolved ones; see read_ch/add_ch) -----------------------
layout(set = 0, binding = 0, std430) restrict readonly buffer Temp { float temp[]; };  // derived, C
layout(set = 0, binding = 19, std430) restrict buffer Enthalpy { float h[]; };          // the state, J/m^3
// ONE H2O CHANNEL. Solid / liquid / vapour are DERIVED shares of it (bindings 34-36), so no record here
// may move mass between phases: a phase change is what the enthalpy ladder already says happened.
layout(set = 0, binding = 1, std430) restrict buffer H2OBuf   { float h2o[]; };
layout(set = 0, binding = 3, std430) restrict buffer O2       { float o2[]; };
layout(set = 0, binding = 4, std430) restrict buffer CO2      { float co2[]; };
// FUEL — cured cellulosic litter, the SAME substance as biomass and detritus. Combustion is a record
// (CombustionRecords.gd), and it is fuel's only sink.
layout(set = 0, binding = 5, std430) restrict buffer Fuel     { float fuel[]; };
// FIRE — an INSTRUMENT, not a channel and not a reactable slot. Assigned at the bottom of main().
layout(set = 0, binding = 6, std430) restrict buffer Fire     { float fire[]; };
layout(set = 0, binding = 7, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 8, std430) restrict buffer Fungus { float fungus[]; };       // decomposer biomass: the decompose record credits it at CUE, the die-back record debits it
layout(set = 0, binding = 9, std430) restrict buffer Fert { float fert[]; };           // soil nutrient (decompose mineralises into it, uptake debits it)
layout(set = 0, binding = 11, std430) restrict buffer Biomass { float biomass[]; };    // living plant matter (photosynthesis grows it, respiration/decay oxidizes it)
layout(set = 0, binding = 17, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 18, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer VelY { float vel_y[]; };
// ONE MINERAL AMOUNT. Melt, suspension and cementation are derived or stored beside it, never here.
layout(set = 0, binding = 22, std430) restrict buffer Silicate { float silicate[]; };  // CaSiO3, volume fraction
// --- THE DERIVED PHASE OF H2O, three shares of h2o[] summing to 1 (state_derive.glsl).
layout(set = 0, binding = 34, std430) restrict readonly buffer H2OSolid  { float h2o_solid[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer H2OLiquid { float h2o_liquid[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer H2OVapour { float h2o_vapour[]; };
// Cell pressure, Pa — the saturation curve and the enthalpy ladder both need it.
layout(set = 0, binding = 37, std430) restrict readonly buffer PressureBuf { float pressure[]; };
// --- Gate inputs + scratch product target + the record table ----------------------------------------------
layout(set = 0, binding = 10, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };        // idx*6 + slot
#include "march.glsli"

// The neighbour below / above this cell: down is -normalize(g), never a slot index.
int la_below(uint c) {
	vec3 gv = vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
	return (length(gv) > 0.0) ? la_step(c, normalize(gv)) : -1;
}

int la_above(uint c) {
	vec3 gv = vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
	return (length(gv) > 0.0) ? la_step(c, -normalize(gv)) : -1;
}
layout(set = 0, binding = 20, std430) restrict buffer Scratch { float scratch[]; };         // SCRATCH product target (fungus_fert)
// AQUIFER PERMEABILITY MASK (1 = groundwater-bearing regolith). The mask root_soil() walks — soil lives
// here, not "wherever the rock is solid": an eroded or carved regolith cell is open AND still an aquifer.
layout(set = 0, binding = 27, std430) restrict readonly buffer Regolith { float regolith[]; };
// --- THE TWO NON-SILICATE MINERAL SPECIES. Every mineral channel above is calcium silicate CaSiO3; the
// Urey reaction CaSiO3 + CO2 <-> CaCO3 + SiO2 has two products that are not, so each gets a channel.
layout(set = 0, binding = 28, std430) restrict buffer Carbonate { float carbonate[]; };  // CaCO3 — the carbon sink
layout(set = 0, binding = 29, std430) restrict buffer Silica { float silica[]; };        // SiO2 — the residue
// BINDINGS 30-33 IN THIS KERNEL ARE NOT THE 30-33 OF EVERY OTHER KERNEL.
layout(set = 0, binding = 30, std430) restrict buffer N2Buf { float n2[]; };              // dinitrogen, 78% of the air
// Charge (channel units) a lightning return stroke drained from this cell this step. DRIVER ONLY.
layout(set = 0, binding = 31, std430) restrict readonly buffer Discharge { float discharge[]; };
// The hydrogen and oxygen bound in the DEAD organic pool whose carbon is detritus + fuel. Same moles per
// channel unit as the carbon, so org_h/org_c is the molar H:C and org_o/org_c the molar O:C.
layout(set = 0, binding = 32, std430) restrict buffer OrgH { float org_h[]; };
layout(set = 0, binding = 33, std430) restrict buffer OrgO { float org_o[]; };

// Below the buffer blocks: the slot names collide with the O2/CO2 block names above.
#include "generated.glsli"
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"

// --- THE PHASE RULE ----------------------------------------------------------------------------------------
const float WATER_FREEZE_C = 0.0;        // LAPhysical.WATER_FREEZE_C — GATE_FREEZING's boundary
const float KELVIN_0 = 273.15;           // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;           // LAPhysical.WATER_DENSITY_KG_M3
const float R_GAS = 8.314462618;         // LAPhysical.GAS_CONSTANT_J_MOL_K
const float P_STD = 101325.0;            // LAPhysical.STANDARD_PRESSURE_PA

// The cell's h2o split by the shares the ladder derived, in the channel's own unit (volume fraction).
float h2o_liq(uint i) { return max(h2o[i], 0.0) * clamp(h2o_liquid[i], 0.0, 1.0); }
float h2o_ice(uint i) { return max(h2o[i], 0.0) * clamp(h2o_solid[i], 0.0, 1.0); }
float h2o_vap(uint i) { return max(h2o[i], 0.0) * clamp(h2o_vapour[i], 0.0, 1.0); }

// SATURATION AMOUNT in the channel's unit, off the SAME curve the ladder inverts: sublimation pressure
// while the condensate is ice, saturation pressure once it is liquid.
float sat_vapour_vf(float t_c, float p_pa) {
	SubstanceTh w = la_h2o();
	float e_sat = la_mix_vapour_p_at(w, t_c, p_pa, 0.0);
	if (e_sat <= 0.0) {
		return 0.0;
	}
	return e_sat * w.molar_mass / (R_GAS * max(t_c + KELVIN_0, 1.0) * RHO_WATER);
}

// Specific enthalpy of the h2o sitting in cell `c`, J/kg, read straight off the ladder at its own state.
float h2o_specific_j_kg(uint c) {
	return la_state_to_enthalpy(la_h2o(), temp[c], max(pressure[c], 0.0), 0.0);
}

// WIND is the flow TANGENTIAL to the local vertical, m/s. No axis of the grid is special: down is -g.
float wind_speed(uint i) {
	vec3 v = vec3(vel_x[i], vel_y[i], vel_z[i]);
	vec3 gv = vec3(g_field[i * 3u], g_field[i * 3u + 1u], g_field[i * 3u + 2u]);
	if (length(gv) <= 0.0) {
		return length(v);
	}
	vec3 up = normalize(-gv);
	return length(v - up * dot(v, up));
}
// Flammability limit as a fraction of ambient air: the limiting oxygen concentration over air's own mole
// fraction of O2.
const float LOC_MOLE_FRAC = 0.15;          // LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC
const float AIR_O2_MOLE_FRAC_K = 0.20946;  // LAPhysical.AIR_MOLE_FRAC_O2
const float O2_FLAMMABILITY_LIMIT = LOC_MOLE_FRAC / AIR_O2_MOLE_FRAC_K;

#define DROWNED_WATER 0.5     // half a cell of standing water in the neighbour above = no free surface here

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
	float param2;      // second rate-model scalar (RM_OPTIMUM_BAND: the half-width of the band around `threshold`)
	float t_ceiling_k; // RM_ARRHENIUS: absolute T above which the law stops applying (its phase is gone). 0 = none.
	int   react_slot[4];
	float react_coeff[4];
	int   prod_slot[4];
	float prod_coeff[4];
	int   prod_target[4];
	// --- see LAReactionDefs.serialize ---
	float enthalpy_j_m3;  // heat RELEASED (>0) or absorbed (<0) per unit of extent, J per m3 of cell
	int   quench_slot;    // a REACTANT this reaction goes out before exhausting; -1 = none
	float quench_min;     // ...the amount of it the reaction may not draw below (flammability limit)
	int   pad2;
	// --- DIRECTION FROM dG (LAReactionThermo). q_slot < 0 = one-way record, no equilibrium.
	float dg_h_j_mol;      // standard dH per mole of q_slot's substance
	float dg_s_j_molk;     // standard dS, same basis
	int   q_slot;          // the one participant whose activity varies; the rest are pure phases
	float q_pa_per_unit_k; // partial pressure (Pa) one channel unit of q_slot exerts per kelvin
	// --- COMPOSITION-SCALED COEFFICIENTS. coeff = base + h*(org_h/org_c) + o*(org_o/org_c), per cell.
	float react_h[4];
	float react_o[4];
	float prod_h[4];
	float prod_o[4];
	float enthalpy_h_j_m3;
	float enthalpy_o_j_m3;
	int   pad3;
	int   pad4;
};

layout(set = 0, binding = 21, std430) restrict readonly buffer Defs { Reaction recs[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint n_records;
	uint pad0;      // no kernel-side dt: every rate_k already carries its own timebase
	uint pad1;      // no global rain gate: rain is a per-cell condition, read per cell
	float sun_x;    // world-space vector TOWARD the sun; MAGNITUDE carries insolation (the same value
	float sun_y;    // transport.glsl's RADIATE row takes, so light and heat come from ONE quantity)
	float sun_z;
	uint pad2;
} params;

// REAL per-cell insolation — the LIGHT slot. Identical to the solar kernel's term, so the terminator that
float light_at(uint i) {
	// OUTWARD is up, and up is -g. There is no second declaration of which way that is.
	vec3 gv = vec3(g_field[i * 3u], g_field[i * 3u + 1u], g_field[i * 3u + 2u]);
	if (length(gv) <= 0.0) {
		return 0.0;
	}
	return max(0.0, dot(normalize(-gv), vec3(params.sun_x, params.sun_y, params.sun_z)));
}

// The FIRST regolith cell beneath an open cell, or -1. The inward-neighbour mapping is injective, so no two
// reacting cells share one.
int top_regolith(uint i) {
	int c = la_below(i);
	if (c < 0 || regolith[c] == 0.0) {
		return -1;
	}
	return c;
}


float root_soil(uint i) {
	float sum = 0.0;
	int c = la_below(i);
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		sum += h2o_liq(uint(c)) * vol_ratio(uint(c), i);
		if (solid[c] == 0.0) {
			break;                          // an OPEN aquifer cell terminates the walk (see RACE-FREEDOM above)
		}
		c = la_below(uint(c));
	}
	return sum;
}

// MASS DOES NOT MOVE WITHOUT ITS HEAT. `v_c` is the change to cell `c` in c's own units; the joules it
// carried there go to cell `i`. The destination's ladder then decides what phase those joules buy, so the
// latent heat is the difference between the two phases' enthalpies and no record declares it.
void h2o_carry(uint c, uint i, float v_c) {
	if (v_c == 0.0) {
		return;
	}
	float j = v_c * RHO_WATER * h2o_specific_j_kg(c);
	h[c] += j;
	h[i] -= j * vol_ratio(c, i);
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
	int c = la_below(i);
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		float took = h2o_liq(uint(c)) * f;
		h2o[uint(c)] = max(0.0, h2o[uint(c)] - took);
		h2o_carry(uint(c), i, -took);
		if (solid[c] == 0.0) {
			break;
		}
		c = la_below(uint(c));
	}
}

// The bedrock of the cell directly BENEATH this open one — the BEDROCK_BELOW slot. Returns 0 when there is no
float bedrock_below(uint i) {
	int d = la_below(i);
	if (d < 0 || solid[d] == 0.0) {
		return 0.0;
	}
	return silicate[uint(d)] * vol_ratio(uint(d), i);
}

void bedrock_below_add(uint i, float v) {
	int d = la_below(i);
	if (d < 0 || solid[d] == 0.0) {
		return;
	}
	silicate[uint(d)] = max(0.0, silicate[uint(d)] + v * vol_ratio(i, uint(d)));
}


// Resolve a channel slot to its per-cell value. Unbound slots read 0 (a record must not reference them).
float read_ch(int slot, uint i) {
	if (slot == TEMP)     return temp[i];
	if (slot == H2O)      return h2o[i];
	if (slot == O2)       return o2[i];
	if (slot == CO2)      return co2[i];
	if (slot == FUEL)     return fuel[i];
	if (slot == DETRITUS) return detritus[i];
	if (slot == FUNGUS)   return fungus[i];
	if (slot == FERT)     return fert[i];
	if (slot == BIOMASS)  return biomass[i];
	if (slot == WINDSPEED) return wind_speed(i);
	if (slot == SILICATE) return silicate[i];
	if (slot == LIGHT)     return light_at(i);
	if (slot == SOIL_ROOT) return root_soil(i);
	if (slot == VAPOUR_DEFICIT) return sat_vapour_vf(temp[i], max(pressure[i], 0.0)) - h2o_vap(i);
	if (slot == SOIL_TOP) { int c = top_regolith(i); return (c < 0) ? 0.0 : h2o_liq(uint(c)) * vol_ratio(uint(c), i); }
	if (slot == BEDROCK_BELOW) return bedrock_below(i);
	if (slot == CARBONATE) return carbonate[i];
	if (slot == SILICA)    return silica[i];
	if (slot == N2)        return n2[i];
	if (slot == DISCHARGE) return discharge[i];
	if (slot == ORG_H)     return org_h[i];
	if (slot == ORG_O)     return org_o[i];
	if (slot == ORG_C)     return detritus[i] + fuel[i];
	if (slot == H2O_LIQUID) return h2o_liq(i);
	return 0.0;
}

// Add v to a channel slot (own cell). Mass channels clamp at 0. LIGHT and unbound slots are geometry, not
// matter, and no-op here. SOIL_ROOT, SOIL_TOP and BEDROCK_BELOW write into the neighbouring cell they name.
void add_ch(int slot, uint i, float v) {
	if      (slot == H2O)      { h2o[i]       = max(0.0, h2o[i] + v); }
	else if (slot == O2)       { o2[i]        = max(0.0, o2[i] + v); }
	else if (slot == CO2)      { co2[i]       = max(0.0, co2[i] + v); }
	else if (slot == FUEL)     { fuel[i]      = max(0.0, fuel[i]     + v); }   // combustion is fuel's only sink
	else if (slot == DETRITUS) { detritus[i]  = max(0.0, detritus[i] + v); }
	else if (slot == FUNGUS)   { fungus[i]    = max(0.0, fungus[i]   + v); }
	else if (slot == FERT)     { fert[i]      = max(0.0, fert[i] + v); }
	else if (slot == BIOMASS)  { biomass[i]   = max(0.0, biomass[i]  + v); }
	else if (slot == SILICATE) { silicate[i]  = max(0.0, silicate[i] + v); }
	else if (slot == SOIL_ROOT) { root_soil_draw(i, -v); }                     // roots draw water OUT of the column (v < 0)
	else if (slot == SOIL_TOP)  {
		int c = top_regolith(i);
		if (c >= 0) {
			float dv = v * vol_ratio(i, uint(c));
			dv = max(dv, -h2o_liq(uint(c)));                                  // only the PORE WATER may leave
			h2o[uint(c)] = max(0.0, h2o[uint(c)] + dv);
			h2o_carry(uint(c), i, dv);
		}
	}
	else if (slot == BEDROCK_BELOW) { bedrock_below_add(i, v); }               // weathering eats the outcrop it stands on
	else if (slot == CARBONATE) { carbonate[i] = max(0.0, carbonate[i] + v); } // D1b credits, D1c debits
	else if (slot == SILICA)    { silica[i]    = max(0.0, silica[i]    + v); }
	else if (slot == N2)        { n2[i]        = max(0.0, n2[i]        + v); }
	else if (slot == ORG_H)     { org_h[i]     = max(0.0, org_h[i]     + v); }
	else if (slot == ORG_O)     { org_o[i]     = max(0.0, org_o[i]     + v); }
}

// Gate helpers reuse the exact neighbour tests proven in the dissolved kernels.
bool gate_ok(int mask, uint i) {
	if (mask == 0) {
		return true;
	}
	if ((mask & GATE_FREEZING) != 0) {
		if (temp[i] >= WATER_FREEZE_C) {
			return false;                   // above the phase boundary the condensate is liquid, not ice
		}
	}
	if ((mask & GATE_NEAR_GROUND) != 0) {
		// GROUND-HUGGING: an open cell resting directly ON terrain (its INWARD neighbour, is rock).
		int dn = la_below(i);
		if (dn < 0 || solid[dn] == 0.0) {
			return false;
		}
	}
	if ((mask & GATE_AIR_ABOVE) != 0) {
		// FREE SURFACE: the outward-radial neighbour must be AIR — open rock-free and not itself drowned.
		int au = la_above(i);
		if (au >= 0 && (solid[au] != 0.0 || h2o_liq(uint(au)) >= DROWNED_WATER)) {
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
	float a_eq = exp(clamp(sigma * (t_k * rc.dg_s_j_molk - rc.dg_h_j_mol) / rt, -EXP_LIMIT, EXP_LIMIT));
	x_eq = (a_eq * P_STD / pa_per_unit - ch) / (sigma * max(q_coeff, 1e-6));
	return 1.0 - exp(clamp(dg / rt, -EXP_LIMIT, EXP_LIMIT));
}

// The effective coefficient of one participant in THIS cell: base plus the composition-scaled parts.
float react_coeff_at(Reaction rc, int k, float ch, float co) {
	return rc.react_coeff[k] + rc.react_h[k] * ch + rc.react_o[k] * co;
}

float prod_coeff_at(Reaction rc, int k, float ch, float co) {
	return rc.prod_coeff[k] + rc.prod_h[k] * ch + rc.prod_o[k] * co;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	scratch[i] = 0.0;                       // reset the per-cell SCRATCH product target each step
	fire[i] = 0.0;                          // the burning INSTRUMENT — assigned from this step's fuel loss below
	bool buried = (solid[i] != 0.0);        // only GATE_BURIED records run in rock; everything else is open-cell
	// THE CELL'S OWN ORGANIC COMPOSITION: molar H:C and O:C of the dead pool. Every stoichiometric coefficient
	// and every enthalpy below is a polynomial in these two, so one channel carries peat through to anthracite.
	float org_c = detritus[i] + fuel[i];
	float comp_h = (org_c > 1e-9) ? org_h[i] / org_c : 0.0;
	float comp_o = (org_c > 1e-9) ? org_o[i] / org_c : 0.0;
	float fuel_before = fuel[i];            // combustion is fuel's only sink
	float o2_before = o2[i];                // the cell's USABLE-oxygen denominator for the fire instrument
	float o2_burn = 0.0;                    // ...and its NUMERATOR: oxygen drawn by COMBUSTION alone, summed below

	for (uint r = 0u; r < params.n_records; r++) {
		Reaction rc = recs[r];
		if (buried && (rc.gate_mask & GATE_BURIED) == 0) {
			continue;
		}
		if (!buried && !gate_ok(rc.gate_mask, i)) {
			continue;
		}
		float drv = read_ch(rc.driver_slot, i);
		float x = 0.0;
		if (rc.rate_model == RM_CONST_FRAC) {
			x = rc.rate_k * drv;
		} else if (rc.rate_model == RM_BILINEAR) {
			x = rc.rate_k * drv * read_ch(rc.driver2_slot, i);
		} else if (rc.rate_model == RM_EXCESS_OVER_THRESHOLD) {
			x = max(0.0, drv - rc.threshold) * rc.rate_k;
		} else if (rc.rate_model == RM_DEFICIT_BELOW_THRESHOLD) {
			x = max(0.0, rc.threshold - drv) * rc.rate_k;   // mirror of EXCESS: fires when driver < threshold
		} else if (rc.rate_model == RM_OPTIMUM_BAND) {
			// A rate that PEAKS in the middle and falls off BOTH ways: proportional to `driver`, modulated by a
			float v = read_ch(rc.driver2_slot, i);
			float t = (v - rc.threshold) / max(rc.param2, 1e-6);
			x = rc.rate_k * drv * max(0.0, 1.0 - t * t);
		} else if (rc.rate_model == RM_ARRHENIUS) {
			// The temperature law of chemistry: activation energy in `threshold` (Ea/R, kelvin), referenced
			// to `param2` (the temperature k is quoted at). First order in `driver`, and in `driver2` when it
			float conc2 = (rc.driver2_slot >= 0) ? read_ch(rc.driver2_slot, i) : 1.0;
			float t_k = temp[i] + KELVIN_0;
			if (rc.t_ceiling_k > 0.0) {
				t_k = min(t_k, rc.t_ceiling_k);
			}
			float t_ref = max(rc.param2, 1.0);
			x = rc.rate_k * drv * conc2 * exp(-rc.threshold * (1.0 / max(t_k, 1.0) - 1.0 / t_ref));
		} else if (rc.rate_model == RM_RESISTANCE_SERIES) {
			// An interfacial flux through two resistances in series. `driver2` is the conductance of the
			// first (a wind speed), `param2` the second expressed against it, so the flux saturates.
			float u = max(read_ch(rc.driver2_slot, i), 0.0);
			x = rc.rate_k * drv * u / (1.0 + rc.param2 * u);
		}
		// An UNKNOWN rate model yields x = 0 and the record does nothing.

		if (x <= 0.0) {
			continue;
		}
		// The rate model above is the KINETICS. This is the DIRECTION, and it may be negative.
		if (rc.q_slot >= 0) {
			float x_eq = 0.0;
			x *= direction_scale(rc, i, x_eq);
			x = (x > 0.0) ? min(x, max(x_eq, 0.0)) : max(x, min(x_eq, 0.0));
		}
		// CAPS ARE UNCONDITIONAL IN BOTH DIRECTIONS: whichever side is being debited bounds the extent, so no
		// path runs a credit without its matching debit. `quench_min` is a FLOOR on one reactant — the amount
		if (x > 0.0) {
			for (int k = 0; k < rc.n_react; k++) {
				float coeff = max(react_coeff_at(rc, k, comp_h, comp_o), 1e-6);
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
				x = max(x, -read_ch(rc.prod_slot[k], i) / max(prod_coeff_at(rc, k, comp_h, comp_o), 1e-6));
			}
		}
		if (x == 0.0) {
			continue;
		}
		// ATTRIBUTION FOR THE BURNING INSTRUMENT, and it has to happen HERE, inside the loop, against THIS
		bool is_combustion = (rc.driver_slot == FUEL);
		float o2_pre_rec = is_combustion ? o2[i] : 0.0;

		for (int k = 0; k < rc.n_react; k++) {
			add_ch(rc.react_slot[k], i, -react_coeff_at(rc, k, comp_h, comp_o) * x);
		}

		for (int k = 0; k < rc.n_prod; k++) {
			if (rc.prod_target[k] == TGT_SCRATCH) {
				scratch[i] += prod_coeff_at(rc, k, comp_h, comp_o) * x;
			} else {
				add_ch(rc.prod_slot[k], i, prod_coeff_at(rc, k, comp_h, comp_o) * x);
			}
		}

		if (is_combustion) {
			o2_burn += max(0.0, o2_pre_rec - o2[i]);
		}

		// Enthalpy is the state, so a reaction's heat is added straight to it. J/m^3.
		float dh = rc.enthalpy_j_m3 + rc.enthalpy_h_j_m3 * comp_h + rc.enthalpy_o_j_m3 * comp_o;
		if (dh != 0.0) {
			h[i] += dh * x;
		}
	}

	// THE BURNING INSTRUMENT. `fire` is derived, not a state: the fraction of this cell's USABLE oxygen that
	// combustion consumed this step, where usable means above the flammability limit. Read by the gauges
	if (fuel_before > 0.0) {
		float o2_usable = max(0.0, o2_before - O2_FLAMMABILITY_LIMIT);
		fire[i] = (o2_usable > 0.0) ? clamp(o2_burn / o2_usable, 0.0, 1.0) : 0.0;
	}
}
