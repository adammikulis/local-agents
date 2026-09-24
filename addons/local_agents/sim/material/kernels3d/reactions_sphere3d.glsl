#[compute]
#version 450

#include "bindings.glsli"

layout(set = 0, binding = LA_BIND_GRAVITY, std430) restrict readonly buffer Grav { float g_field[]; };
// Cells a record changed, and slot 3 their count: transport wakes them wherever they sit, so a
// reaction can never fire into a cell the activity mask has stopped stepping.
layout(set = 0, binding = LA_BIND_ACT_WAKE, std430) buffer WakeQueue { uint wake_q[]; };
layout(set = 0, binding = LA_BIND_ACT_WAKE_ARGS, std430) buffer WakeArgs { uint wake_args[]; };
#include "cellvol.glsli"

// GENERIC REACTION ENGINE. One data-driven kernel: every same-cell reaction is a record in the Defs buffer.
// Kinetics come from the rate model, direction from dG (see direction_scale).

layout(local_size_x = 64) in;

// --- Reactable channels; read_ch/add_ch resolve a record slot to one of these ------------------------
layout(set = 0, binding = LA_BIND_TEMP, std430) restrict readonly buffer Temp { float temp[]; };  // derived, C
layout(set = 0, binding = LA_BIND_E_J_M3, std430) restrict buffer Enthalpy { float h[]; };          // the state, J/m^3
// ONE H2O CHANNEL. Solid / liquid / vapour are DERIVED shares of it, so no record here
// may move mass between phases: a phase change is what the enthalpy ladder already says happened.
layout(set = 0, binding = LA_BIND_H2O, std430) restrict buffer H2OBuf   { float h2o[]; };
layout(set = 0, binding = LA_BIND_O2, std430) restrict buffer O2       { float o2[]; };
layout(set = 0, binding = LA_BIND_CO2, std430) restrict buffer CO2      { float co2[]; };
// FUEL — cured cellulosic litter, the SAME substance as biomass and detritus. Combustion is a record
// (CombustionRecords.gd), and it is fuel's only sink.
layout(set = 0, binding = LA_BIND_FUEL, std430) restrict buffer Fuel     { float fuel[]; };
// FIRE — an INSTRUMENT, not a channel and not a reactable slot. Assigned at the bottom of main().
layout(set = 0, binding = LA_BIND_FIRE, std430) restrict buffer Fire     { float fire[]; };
layout(set = 0, binding = LA_BIND_DETRITUS, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = LA_BIND_FUNGUS, std430) restrict buffer Fungus { float fungus[]; };       // decomposer biomass: the decompose record credits it at CUE, the die-back record debits it
layout(set = 0, binding = LA_BIND_FERT, std430) restrict buffer Fert { float fert[]; };           // soil nutrient (decompose mineralises into it, uptake debits it)
layout(set = 0, binding = LA_BIND_BIOMASS, std430) restrict buffer Biomass { float biomass[]; };    // living plant matter (photosynthesis grows it, respiration/decay oxidizes it)
layout(set = 0, binding = LA_BIND_VEL_X, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = LA_BIND_VEL_Z, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = LA_BIND_VEL_Y, std430) restrict readonly buffer VelY { float vel_y[]; };
// ONE MINERAL AMOUNT. Melt, suspension and cementation are derived or stored beside it, never here.
layout(set = 0, binding = LA_BIND_SILICATE, std430) restrict buffer Silicate { float silicate[]; };  // CaSiO3, volume fraction
// --- THE DERIVED PHASE OF H2O, three shares of h2o[] summing to 1 (state_derive.glsl).
layout(set = 0, binding = LA_BIND_H2O_SOLID, std430) restrict readonly buffer H2OSolid  { float h2o_solid[]; };
layout(set = 0, binding = LA_BIND_H2O_LIQUID, std430) restrict readonly buffer H2OLiquid { float h2o_liquid[]; };
layout(set = 0, binding = LA_BIND_H2O_VAPOUR, std430) restrict readonly buffer H2OVapour { float h2o_vapour[]; };
// Cell pressure, Pa — the saturation curve and the enthalpy ladder both need it.
layout(set = 0, binding = LA_BIND_PRESSURE, std430) restrict readonly buffer PressureBuf { float pressure[]; };
// --- Gate inputs + the record table -----------------------------------------------------------------------
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict readonly buffer Solid { float solid[]; };

// GravityPass owns the vertical relation; this kernel reads it. vert_down is vert_up's scattered
// inverse, so at most one cell names any given cell as its below - which is what makes the
// cross-cell writes below race-free. An unset entry is -1.
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict readonly buffer VertUp { int vert_up[]; };
layout(set = 0, binding = LA_BIND_VERT_DOWN, std430) restrict readonly buffer VertDown { int vert_down[]; };

int la_below(uint c) {
	return vert_down[c];
}

int la_above(uint c) {
	return vert_up[c];
}
// AQUIFER PERMEABILITY MASK (1 = groundwater-bearing regolith). The mask root_soil() walks — soil lives
// here, not "wherever the rock is solid": an eroded or carved regolith cell is open AND still an aquifer.
layout(set = 0, binding = LA_BIND_REGOLITH, std430) restrict readonly buffer Regolith { float regolith[]; };
// --- THE TWO NON-SILICATE MINERAL SPECIES. Every mineral channel above is calcium silicate CaSiO3; the
// Urey reaction CaSiO3 + CO2 <-> CaCO3 + SiO2 has two products that are not, so each gets a channel.
layout(set = 0, binding = LA_BIND_CARBONATE, std430) restrict buffer Carbonate { float carbonate[]; };  // CaCO3 — the carbon sink
layout(set = 0, binding = LA_BIND_SILICA, std430) restrict buffer Silica { float silica[]; };        // SiO2 — the residue
// BINDINGS 30-33 IN THIS KERNEL ARE NOT THE 30-33 OF EVERY OTHER KERNEL.
layout(set = 0, binding = LA_BIND_N2, std430) restrict buffer N2Buf { float n2[]; };              // dinitrogen, mol/m^3
// Lightning energy released this step, J/m^3. DERIVED here from the field the strike is relaxing.
layout(set = 0, binding = LA_BIND_DISCHARGE, std430) restrict buffer Discharge { float discharge[]; };
// The column electrostatic field (V/m) and breakdown flag transport's EFIELD row publishes.
layout(set = 0, binding = LA_BIND_COL_E, std430) restrict readonly buffer ColE { float col_e[]; };
layout(set = 0, binding = LA_BIND_STRIKE, std430) restrict readonly buffer StrikeBuf { float strike[]; };
layout(set = 0, binding = LA_BIND_GRAIN, std430) restrict readonly buffer GrainBuf { float grain[]; };   // m, the cell's grain diameter
// The hydrogen and oxygen bound in the DEAD organic pool whose carbon is detritus + fuel. Same moles per
// channel unit as the carbon, so org_h/org_c is the molar H:C and org_o/org_c the molar O:C.
layout(set = 0, binding = LA_BIND_ORG_H, std430) restrict buffer OrgH { float org_h[]; };
layout(set = 0, binding = LA_BIND_ORG_O, std430) restrict buffer OrgO { float org_o[]; };

// Below the buffer blocks: the slot names collide with the O2/CO2 block names above.
#include "generated.glsli"
#include "physical.glsli"
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"

// --- THE PHASE RULE ----------------------------------------------------------------------------------------
const float KELVIN_0 = 273.15;           // LAPhysical.KELVIN_OFFSET
const float RHO_SILICATE = 2900.0;       // LASubstances.silicate.density
const float M_SILICATE = 0.1161612;      // LASubstances.silicate.molar_mass
const float M_H2O = 0.018015;            // LAPhysical.MOLAR_MASS_WATER_KG_MOL
const float R_GAS = 8.314462618;         // LAPhysical.GAS_CONSTANT_J_MOL_K
const float P_STD = 101325.0;            // LAPhysical.STANDARD_PRESSURE_PA
const float EPS0 = 8.8541878128e-12;     // LAPhysical.VACUUM_PERMITTIVITY_F_M

// The cell's h2o split by the shares the ladder derived, in the channel's own unit (mol/m^3).
float h2o_liq(uint i) { return max(h2o[i], 0.0) * clamp(h2o_liquid[i], 0.0, 1.0); }
float h2o_ice(uint i) { return max(h2o[i], 0.0) * clamp(h2o_solid[i], 0.0, 1.0); }
float h2o_vap(uint i) { return max(h2o[i], 0.0) * clamp(h2o_vapour[i], 0.0, 1.0); }

// SATURATION AMOUNT, mol/m^3, off the SAME curve the ladder inverts: sublimation pressure while the
// condensate is ice, saturation pressure once it is liquid. c = p / (R T).
float sat_vapour_mol_m3(float t_c, float p_pa) {
	SubstanceTh w = la_h2o();
	float e_sat = la_mix_vapour_p_at(w, t_c, p_pa, 0.0);
	if (e_sat <= 0.0) {
		return 0.0;
	}
	return e_sat / (R_GAS * max(t_c + KELVIN_0, 1.0));
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
// Flammability limit: a MOLE FRACTION of the cell's gas, converted per cell against p / (R T).
const float LOC_MOLE_FRAC = 0.15;          // LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC

// mol/m^3 a mole fraction of this cell's gas stands for.
float mole_frac_to_mol_m3(uint i, float frac) {
	return frac * max(pressure[i], 0.0) / (R_GAS * max(temp[i] + KELVIN_0, 1.0));
}

// mol/m^3 a cell full of its own liquid water holds, at that cell's own temperature.
float full_h2o_at(uint i) {
	float v = la_water_liquid_v_m3_kg(temp[i]);
	return v > 0.0 ? 1.0 / (v * M_H2O) : 0.0;
}

// Half a cell of standing liquid water in the neighbour above = no free surface here. mol/m^3.
float drowned_water(uint i) {
	return 0.5 * full_h2o_at(i);
}

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
	// --- see LAReactionDefs.serialize ---
	float enthalpy_j_mol; // heat RELEASED (>0) or absorbed (<0) per mole of extent
	int   quench_slot;    // a REACTANT this reaction goes out before exhausting; -1 = none
	float quench_min;     // ...the MOLE FRACTION of the cell's gas it may not draw below
	int   pad2;
	// --- DIRECTION FROM dG (LAReactionThermo). q_slot < 0 = one-way record, no equilibrium.
	float dg_h_j_mol;      // standard dH per mole of q_slot's substance
	float dg_s_j_molk;     // standard dS, same basis
	int   q_slot;          // the one participant whose activity varies; the rest are pure phases
	float dn_gas;          // net moles of GAS per mole of extent, same composition split as the coefficients
	// --- COMPOSITION-SCALED COEFFICIENTS. coeff = base + h*(org_h/org_c) + o*(org_o/org_c), per cell.
	float react_h[4];
	float react_o[4];
	float prod_h[4];
	float prod_o[4];
	float enthalpy_h_j_mol;
	float enthalpy_o_j_mol;
	float dn_gas_h;
	float dn_gas_o;
};

layout(set = 0, binding = LA_BIND_REACTION_DEFS, std430) restrict readonly buffer Defs { Reaction recs[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint n_records;
	uint pad0;      // no kernel-side dt: every rate_k already carries its own timebase
	uint pad1;      // no global rain gate: rain is a per-cell condition, read per cell
	float sun_x;    // world-space vector TOWARD the sun; its magnitude is the irradiance in W/m^2, the
	float sun_y;    // same value flux.glsl's RADIATE row takes, so light and heat are ONE quantity
	float sun_z;
	uint pad2;
} params;

// The zenith cosine — GEOMETRY, which is what the LIGHT slot is declared to be. Same terminator the
// solar kernel draws; the flux itself is the radiative row's business.
float light_at(uint i) {
	// OUTWARD is up, and up is -g. There is no second declaration of which way that is.
	vec3 gv = vec3(g_field[i * 3u], g_field[i * 3u + 1u], g_field[i * 3u + 2u]);
	vec3 sun = vec3(params.sun_x, params.sun_y, params.sun_z);
	if (length(gv) <= 0.0 || length(sun) <= 0.0) {
		return 0.0;
	}
	return max(0.0, dot(normalize(-gv), normalize(sun)));
}

// The FIRST regolith cell beneath an open cell, or -1.
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
	float j = v_c * M_H2O * h2o_specific_j_kg(c);
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

// Geometric surface of the bedrock cell beneath, 6 phi / d for grains of diameter d, scaled into this
// cell's volume and wetted by this cell's liquid fill share: m^2 of reacting rock per m^3 of this cell.
float bedrock_surface_wet(uint i) {
	int d = la_below(i);
	if (d < 0 || solid[d] == 0.0 || grain[d] <= 0.0) {
		return 0.0;
	}
	float phi = silicate[uint(d)] * M_SILICATE / RHO_SILICATE;
	float wet = clamp(full_h2o_at(i) > 0.0 ? h2o_liq(i) / full_h2o_at(i) : 0.0, 0.0, 1.0);
	return 6.0 * phi / grain[d] * vol_ratio(uint(d), i) * wet;
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
	if (slot == VAPOUR_DEFICIT) return sat_vapour_mol_m3(temp[i], max(pressure[i], 0.0)) - h2o_vap(i);
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
	if (slot == ROCK_SURFACE_WET) return bedrock_surface_wet(i);
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
		// The melting point this cell's water actually has: the ladder's own curve at this pressure.
		if (temp[i] >= la_melt_c_at(la_h2o(), max(pressure[i], 0.0), 0.0)) {
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
		if (au >= 0 && (solid[au] != 0.0 || h2o_liq(uint(au)) >= drowned_water(uint(au)))) {
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
	// A channel amount is moles, so p = c R T. Only the VAPOUR share of a condensable exerts pressure:
	// with liquid present the vapour sits at saturation, so the amount is capped there.
	float ch = read_ch(rc.q_slot, i);
	if (rc.q_slot == H2O) {
		float c_sat = sat_vapour_mol_m3(temp[i], max(pressure[i], 0.0));
		if (c_sat > 0.0) {
			ch = min(ch, c_sat);
		}
	}
	float dg = rc.dg_h_j_mol - t_k * rc.dg_s_j_molk + sigma * rt * log(max(rt * ch / P_STD, 1e-30));
	float a_eq = exp(clamp(sigma * (t_k * rc.dg_s_j_molk - rc.dg_h_j_mol) / rt, -EXP_LIMIT, EXP_LIMIT));
	x_eq = (a_eq * P_STD / rt - ch) / (sigma * max(q_coeff, 1e-6));
	return 1.0 - exp(clamp(dg / rt, -EXP_LIMIT, EXP_LIMIT));
}

// The effective coefficient of one participant in THIS cell: base plus the composition-scaled parts.
float react_coeff_at(Reaction rc, int k, float ch, float co) {
	return rc.react_coeff[k] + rc.react_h[k] * ch + rc.react_o[k] * co;
}

float prod_coeff_at(Reaction rc, int k, float ch, float co) {
	return rc.prod_coeff[k] + rc.prod_h[k] * ch + rc.prod_o[k] * co;
}

// Slots a record may debit or credit, one demand/scale bin each.
#define LA_REACT_SLOTS (H2O_LIQUID + 1)

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	fire[i] = 0.0;                          // the burning INSTRUMENT — assigned from this step's fuel loss below
	// The stroke's store: the field energy the strike is relaxing this step. Transport drains the charge
	// at channel conductivity; this reads what that debit released. J/m^3, driver only.
	discharge[i] = (strike[i] > 0.0) ? 0.5 * EPS0 * col_e[i] * col_e[i] : 0.0;
	bool buried = (solid[i] != 0.0);        // only GATE_BURIED records run in rock; everything else is open-cell only
	// THE CELL'S OWN ORGANIC COMPOSITION: molar H:C and O:C of the dead pool. Every stoichiometric coefficient
	// and every enthalpy below is a polynomial in these two, so one channel carries peat through to anthracite.
	float org_c = detritus[i] + fuel[i];
	float comp_h = (org_c > 1e-9) ? org_h[i] / org_c : 0.0;
	float comp_o = (org_c > 1e-9) ? org_o[i] / org_c : 0.0;
	float fuel_before = fuel[i];            // combustion is fuel's only sink
	float o2_before = o2[i];                // the cell's USABLE-oxygen denominator for the fire instrument
	float o2_burn = 0.0;                    // ...and its NUMERATOR: oxygen drawn by COMBUSTION alone, summed below
	bool fired = false;                     // a record changed this cell, so transport must wake it

	// --- PHASE 1: every record's extent against the SAME starting state, plus each slot's total debit.
	uint n = min(params.n_records, uint(MAX_RECORDS));
	float xs[MAX_RECORDS];
	float dem[LA_REACT_SLOTS];
	for (int s = 0; s < LA_REACT_SLOTS; s++) {
		dem[s] = 0.0;
	}
	for (uint r = 0u; r < n; r++) {
		Reaction rc = recs[r];
		xs[r] = 0.0;
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
			// Catalytic with a temperature optimum: first order in `driver` and in the `driver2` catalyst,
			// modulated by a band peaking at `threshold` (C), zero `param2` either side.
			float t = (temp[i] - rc.threshold) / max(rc.param2, 1e-6);
			x = rc.rate_k * drv * read_ch(rc.driver2_slot, i) * max(0.0, 1.0 - t * t);
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
		// CAPS ARE UNCONDITIONAL IN BOTH DIRECTIONS: whichever side is being debited bounds the extent, so
		// no path runs a credit without its matching debit — a composition-scaled coefficient can put a
		// participant on either side. `quench_min` is a FLOOR on one reactant, a mole fraction of the gas.
		for (int k = 0; k < rc.n_react; k++) {
			float coeff = react_coeff_at(rc, k, comp_h, comp_o);
			if (coeff * x <= 0.0) {
				continue;                                    // this side is credited, not debited
			}
			float avail = read_ch(rc.react_slot[k], i);
			if (rc.react_slot[k] == rc.quench_slot) {
				avail = max(0.0, avail - mole_frac_to_mol_m3(i, rc.quench_min));
			}
			float bound = avail / max(abs(coeff), 1e-12);
			x = (x > 0.0) ? min(x, bound) : max(x, -bound);
		}
		for (int k = 0; k < rc.n_prod; k++) {
			float coeff = prod_coeff_at(rc, k, comp_h, comp_o);
			if (coeff * x >= 0.0) {
				continue;
			}
			float bound = read_ch(rc.prod_slot[k], i) / max(abs(coeff), 1e-12);
			x = (x > 0.0) ? min(x, bound) : max(x, -bound);
		}
		if (x > 0.0 && rc.cap_slot >= 0) {
			x = min(x, read_ch(rc.cap_slot, i) / max(rc.cap_coeff, 1e-12));
		}
		xs[r] = x;
		if (x == 0.0) {
			continue;
		}
		for (int k = 0; k < rc.n_react; k++) {
			float d = react_coeff_at(rc, k, comp_h, comp_o) * x;
			if (d > 0.0 && rc.react_slot[k] >= 0 && rc.react_slot[k] < LA_REACT_SLOTS) {
				dem[rc.react_slot[k]] += d;
			}
		}
		for (int k = 0; k < rc.n_prod; k++) {
			float d = -prod_coeff_at(rc, k, comp_h, comp_o) * x;
			if (d > 0.0 && rc.prod_slot[k] >= 0 && rc.prod_slot[k] < LA_REACT_SLOTS) {
				dem[rc.prod_slot[k]] += d;
			}
		}
	}

	// --- PHASE 2: one proportional scaling per over-drawn slot, so records compete by share of the same
	// starting amount, never by table order.
	float scl[LA_REACT_SLOTS];
	for (int s = 0; s < LA_REACT_SLOTS; s++) {
		scl[s] = 1.0;
		if (dem[s] > 0.0) {
			float avail = max(read_ch(s, i), 0.0);
			if (dem[s] > avail) {
				scl[s] = avail / dem[s];
			}
		}
	}

	// --- PHASE 3: apply the scaled extents.
	for (uint r = 0u; r < n; r++) {
		if (xs[r] == 0.0) {
			continue;
		}
		Reaction rc = recs[r];
		float x = xs[r];
		float s_r = 1.0;
		for (int k = 0; k < rc.n_react; k++) {
			if (react_coeff_at(rc, k, comp_h, comp_o) * x > 0.0 && rc.react_slot[k] >= 0
					&& rc.react_slot[k] < LA_REACT_SLOTS) {
				s_r = min(s_r, scl[rc.react_slot[k]]);
			}
		}
		for (int k = 0; k < rc.n_prod; k++) {
			if (prod_coeff_at(rc, k, comp_h, comp_o) * x < 0.0 && rc.prod_slot[k] >= 0
					&& rc.prod_slot[k] < LA_REACT_SLOTS) {
				s_r = min(s_r, scl[rc.prod_slot[k]]);
			}
		}
		x *= s_r;
		if (x == 0.0) {
			continue;
		}
		bool is_combustion = (rc.driver_slot == FUEL);
		for (int k = 0; k < rc.n_react; k++) {
			float coeff = react_coeff_at(rc, k, comp_h, comp_o);
			add_ch(rc.react_slot[k], i, -coeff * x);
			if (is_combustion && rc.react_slot[k] == O2 && coeff * x > 0.0) {
				o2_burn += coeff * x;
			}
		}
		for (int k = 0; k < rc.n_prod; k++) {
			add_ch(rc.prod_slot[k], i, prod_coeff_at(rc, k, comp_h, comp_o) * x);
		}
		// The state is INTERNAL energy and a record declares a standard reaction ENTHALPY, so the pV work
		// of the gas it makes or eats comes back out: dU = dH - dn_gas R T at the cell's own temperature.
		float dh = rc.enthalpy_j_mol + rc.enthalpy_h_j_mol * comp_h + rc.enthalpy_o_j_mol * comp_o;
		if (dh != 0.0) {
			float dn = rc.dn_gas + rc.dn_gas_h * comp_h + rc.dn_gas_o * comp_o;
			h[i] += (dh + dn * R_GAS * (temp[i] + KELVIN_0)) * x;
		}
		fired = true;
	}
	if (fired) {
		uint slot = atomicAdd(wake_args[3], 1u);
		if (slot < params.cell_count) {
			wake_q[slot] = i;
			atomicMax(wake_args[0], (slot + 64u) / 64u);
		}
	}

	// THE BURNING INSTRUMENT. `fire` is derived, not a state: the fraction of this cell's USABLE oxygen that
	// combustion consumed this step, where usable means above the flammability limit. Read by the gauges
	if (fuel_before > 0.0) {
		float o2_usable = max(0.0, o2_before - mole_frac_to_mol_m3(i, LOC_MOLE_FRAC));
		fire[i] = (o2_usable > 0.0) ? clamp(o2_burn / o2_usable, 0.0, 1.0) : 0.0;
	}
}
