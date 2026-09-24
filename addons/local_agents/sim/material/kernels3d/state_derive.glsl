#[compute]
#version 450

#include "bindings.glsli"

layout(local_size_x = 64) in;

// enthalpy.glsli FIRST: Godot does not expand a nested #include inside a .glsli.
#include "physical.glsli"
#include "enthalpy.glsli"
#include "matter_channels.glsli"
#define LA_MIX_SLOTS LA_CHANNEL_SLOTS
#include "mixture_enthalpy.glsli"
#include "cellvol.glsli"
#include "eos.glsli"

// THE NEIGHBOUR GRAPH, read only by the detect phase below.
layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Nbr { int nbr[]; };
layout(set = 0, binding = LA_BIND_VERT_UP, std430) restrict readonly buffer VertUp { int vert_up[]; };
layout(set = 0, binding = LA_BIND_VERT_DOWN, std430) restrict readonly buffer VertDown { int vert_down[]; };
#include "neighbours.glsli"

// THE STATE: internal energy per volume, J/m^3. Enthalpy is derived from it at the pressure solved.
layout(set = 0, binding = LA_BIND_E_J_M3, std430) restrict buffer Energy { float e_j_m3[]; };
layout(set = 0, binding = LA_BIND_PRESSURE, std430) restrict buffer Pressure { float pressure[]; };
// Read as well as written: this pass is the ONE writer, and reads the temperature it replaces.
layout(set = 0, binding = LA_BIND_TEMP, std430) restrict buffer Temp { float temp[]; };
// THE LATTICE'S RESERVOIR: its internal energy and temperature, beside the fluid's above.
layout(set = 0, binding = LA_BIND_E_LITH_J_M3, std430) restrict buffer EnergyLith { float e_lith_j_m3[]; };
layout(set = 0, binding = LA_BIND_TEMP_LITH, std430) restrict buffer TempLith { float temp_lith[]; };
layout(set = 0, binding = LA_BIND_CONDUCTIVITY_LITH, std430) restrict writeonly buffer CondLith { float conductivity_lith[]; };
layout(set = 0, binding = LA_BIND_CAP_LITH, std430) restrict writeonly buffer CapLith { float cap_lith[]; };
layout(set = 0, binding = LA_BIND_LATTICE_FRAC, std430) restrict writeonly buffer LatticeFrac { float lattice_frac[]; };
layout(set = 0, binding = LA_BIND_H_H2O_VAP, std430) restrict writeonly buffer HH2OVap { float h_h2o_vap[]; };
// THE FLUID'S OWN PRESSURE in every cell: the published pressure of an open cell, and the state a
// locked cell's band and air stand at under whatever column its rock carries.
layout(set = 0, binding = LA_BIND_P_FLUID, std430) restrict buffer PFluid { float p_fluid[]; };
layout(set = 0, binding = LA_BIND_DERIVE_PROPS, std430) restrict readonly buffer Props { float props[]; };

// Cementation state and the solid flag. Read-modify-write: the lockup branch is hysteretic.
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = LA_BIND_CEMENT, std430) restrict buffer Cement { float cement[]; };
layout(set = 0, binding = LA_BIND_REGOLITH, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = LA_BIND_GRAIN, std430) restrict buffer Grain { float grain[]; };
// Cell centre, flat cell*3, model units. The centrifugal term needs the radius vector.
layout(set = 0, binding = LA_BIND_POS, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = LA_BIND_GRAVITY, std430) restrict readonly buffer Grav { float g_field[]; };  // m/s^2, cell*3
layout(set = 0, binding = LA_BIND_G_REST, std430) restrict writeonly buffer GravRest { float g_rest[]; };
// The body impulse this step deposits per cell (weight + rotating frame), kg/(m^2 s): the ledger's book.
layout(set = 0, binding = LA_BIND_BODYF_X, std430) restrict writeonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = LA_BIND_BODYF_Y, std430) restrict writeonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = LA_BIND_BODYF_Z, std430) restrict writeonly buffer BodyFZ { float bodyf_z[]; };
// The mixture's sound speed, m/s: Wood's one-pressure compressibility sum over the cell's own matter.
layout(set = 0, binding = LA_BIND_K_COND, std430) restrict buffer KCond { float k_cond[]; };
layout(set = 0, binding = LA_BIND_GAS_R, std430) restrict writeonly buffer GasR { float gas_r[]; };        // J/(kg K), the gas mixture
layout(set = 0, binding = LA_BIND_GAS_GAMMA, std430) restrict writeonly buffer GasGamma { float gas_gamma[]; };
layout(set = 0, binding = LA_BIND_MACH, std430) restrict writeonly buffer Mach { float mach[]; };         // |v| over the cell's own sound speed
// The energy of MOTION, J/m^3, which the enthalpy state does not hold. A function of state and nothing
// else, read only by the reduce, so a book can weigh it against the enthalpy it trades with.
layout(set = 0, binding = LA_BIND_KE_J_M3, std430) restrict writeonly buffer KinBuf { float ke_j_m3[]; };
// The energy of POSITION, J/m^3: this cell's mass in the potential `g_rest` is the gradient of.
layout(set = 0, binding = LA_BIND_GRAV_PHI, std430) restrict readonly buffer GravPhi { float grav_phi[]; };   // deviation from grav_ref
layout(set = 0, binding = LA_BIND_GRAV_REF, std430) restrict readonly buffer GravRef { float grav_ref[]; };   // J/kg, the monopole reference  // J/kg
layout(set = 0, binding = LA_BIND_PE_J_M3, std430) restrict writeonly buffer PotBuf { float pe_j_m3[]; };
// The cell's condensed matter other than water: volume fraction and kg/m^3, every lithic channel summed.
layout(set = 0, binding = LA_BIND_LITHIC_FRAC, std430) restrict writeonly buffer LithicFrac { float lithic_frac[]; };
layout(set = 0, binding = LA_BIND_LITHIC_KG, std430) restrict writeonly buffer LithicKg { float lithic_kg[]; };
// Radiogenic power of this cell's own matter, W/m^3: sum over channels of amount * M * W/kg(mix, epoch).
// flux.glsl's RADIOGENIC leg deposits it into the enthalpy.
layout(set = 0, binding = LA_BIND_RAD_W_M3, std430) restrict writeonly buffer RadW { float rad_w_m3[]; };

// MOMENTUM is the state, kg m/s per m^3. Velocity is what you read off it once you know the mass.
layout(set = 0, binding = LA_BIND_MOM_X, std430) restrict buffer MomX { float mom_x[]; };
layout(set = 0, binding = LA_BIND_MOM_Y, std430) restrict buffer MomY { float mom_y[]; };
layout(set = 0, binding = LA_BIND_MOM_Z, std430) restrict buffer MomZ { float mom_z[]; };
layout(set = 0, binding = LA_BIND_VEL_X, std430) restrict buffer VelX { float vel_x[]; };
layout(set = 0, binding = LA_BIND_VEL_Y, std430) restrict buffer VelY { float vel_y[]; };
layout(set = 0, binding = LA_BIND_VEL_Z, std430) restrict buffer VelZ { float vel_z[]; };

// What the pressure kernel needs and this pass already computes: the cell's gas in mol/m^3 and the
// density of its CONDENSED matter alone, kg/m^3.
layout(set = 0, binding = LA_BIND_RHO_BULK, std430) restrict writeonly buffer RhoBulk { float rho_bulk[]; };
layout(set = 0, binding = LA_BIND_CONDUCTIVITY, std430) restrict writeonly buffer Cond { float conductivity[]; };

// THE PHASE OF THE CELL'S H2O, as three shares of h2o[] summing to 1. Derived, never stored.
layout(set = 0, binding = LA_BIND_H2O_SOLID, std430) restrict buffer H2OSolid { float h2o_solid[]; };
layout(set = 0, binding = LA_BIND_H2O_LIQUID, std430) restrict buffer H2OLiquid { float h2o_liquid[]; };
layout(set = 0, binding = LA_BIND_H2O_VAPOUR, std430) restrict writeonly buffer H2OVapour { float h2o_vapour[]; };

// THE MELT SHARE OF THE CELL'S SILICATE: the lever rule across the solidus-liquidus interval. Derived from
// the same enthalpy ladder the temperature came off, never stored.
layout(set = 0, binding = LA_BIND_SILICATE_MELT, std430) restrict buffer SilicateMelt { float silicate_melt[]; };

// kg/m^3 the cell's own liquid water stands at. One liquid density per planet is a sea that cannot
// stratify.
layout(set = 0, binding = LA_BIND_WATER_RHO, std430) restrict writeonly buffer WaterRho { float water_rho[]; };

// LIQUID water per cell: h2o times its liquid share. Read back every drain for the CPU consumers.
layout(set = 0, binding = LA_BIND_LIQUID, std430) restrict writeonly buffer Liquid { float liquid[]; };

// THE DEAD ORGANIC POOL'S COMPOSITION: molar H:C and O:C, and how far below fresh litter the nearer ratio
// sits. +inf where the pool is under the mole floor, so a MIN or COUNT_LT row cannot read noise.
layout(set = 0, binding = LA_BIND_ORG_HC, std430) restrict writeonly buffer OrgHC { float org_hc[]; };
layout(set = 0, binding = LA_BIND_ORG_OC, std430) restrict writeonly buffer OrgOC { float org_oc[]; };
layout(set = 0, binding = LA_BIND_ORG_FRESH, std430) restrict writeonly buffer OrgFresh { float org_fresh[]; };

// WHERE AND HOW FAST, so a band of latitude or altitude is an ordinary reduce gate rather than a CPU walk.
// speed is |v|, m/s; alt is the height of the cell above the sea shell, m; lat is the angle of its radius
// out of the equatorial plane, degrees.
layout(set = 0, binding = LA_BIND_SPEED, std430) restrict writeonly buffer Speed { float speed[]; };
layout(set = 0, binding = LA_BIND_LAT, std430) restrict writeonly buffer Lat { float lat[]; };
layout(set = 0, binding = LA_BIND_ALT, std430) restrict writeonly buffer Alt { float alt[]; };

// |r| over the sea shell's radius, NaN where the body carries none.
layout(set = 0, binding = LA_BIND_R_FRAC, std430) restrict writeonly buffer RFrac { float r_frac[]; };
// 0 buried, 1 open sea surface, 2 frozen sea surface, 3 the outermost rock of a column.
layout(set = 0, binding = LA_BIND_SURFACE_CLASS, std430) restrict writeonly buffer SurfClass { float surface_class[]; };
// 0 outside the melt body, 1 its rind, 2 its interior.
layout(set = 0, binding = LA_BIND_MELT_BODY, std430) restrict writeonly buffer MeltBody { float melt_body[]; };
// 1 at a cell the detect phase names one.
layout(set = 0, binding = LA_BIND_ERUPT, std430) restrict writeonly buffer Erupt { float erupt[]; };
layout(set = 0, binding = LA_BIND_CYCLONE, std430) restrict writeonly buffer Cyclone { float cyclone[]; };

// How many of this cell's channel amounts, its enthalpy and its momentum are NaN or infinite.
// Reduced by the `nonfinite_cells` row.
layout(set = 0, binding = LA_BIND_NONFINITE, std430) restrict writeonly buffer NonFinite { float nonfinite[]; };
layout(set = 0, binding = LA_BIND_MOM_ORPHAN, std430) restrict writeonly buffer MomOrphan { float mom_orphan[]; };
// 1 where the (T, p) solve spent its budget without meeting LA_STATE_TOL; the derive_unconverged_cells row sums it.
layout(set = 0, binding = LA_BIND_UNCONVERGED, std430) restrict writeonly buffer Unconverged { float unconverged[]; };

// The enthalpy each mixture entry holds, J/m^3, and the sensible entry's capacity, J/m^3/K.
layout(set = 0, binding = LA_BIND_H_H2O, std430) restrict writeonly buffer HH2O { float h_h2o[]; };
layout(set = 0, binding = LA_BIND_H_SILICATE, std430) restrict writeonly buffer HSilicate { float h_silicate[]; };
layout(set = 0, binding = LA_BIND_H_SENSIBLE, std430) restrict writeonly buffer HSensible { float h_sensible[]; };
layout(set = 0, binding = LA_BIND_CAP_SENSIBLE, std430) restrict writeonly buffer CapSensible { float cap_sensible[]; };

// The active list the transport substep walks, sorted by level. LATemporalLevels.SLOTS: 4 offset, 6 suffix.
layout(set = 0, binding = LA_BIND_LEVEL_IDX, std430) restrict readonly buffer LevelIdx { uint level_idx[]; };
layout(set = 0, binding = LA_BIND_LEVEL_ARGS, std430) restrict readonly buffer LevelArgs { uint level_args[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt_s;
	float omega_x;          // the body's angular velocity in the field's own axes, rad/s
	float omega_y;
	float omega_z;
	float centre_x;         // the spin axis passes through the body centre
	float centre_y;
	float centre_z;
	float fresh_grain_m;    // grain diameter given to newly-closed rock — LAPhysical.GRAIN_D_LOWLAND_M
	float lith_rate_per_pa; // LAPhysical.LITHIFICATION_RATE_PER_PA, per step per Pa of excess
	float lith_pressure_pa; // LAPhysical.LITHIFICATION_PRESSURE_PA
	float fresh_h_per_c;    // LASubstances.fresh_litter_per_carbon("H")
	float fresh_o_per_c;    // LASubstances.fresh_litter_per_carbon("O")
	float rad_w_kg_1;       // W/kg of radiogenic trace mix 1 at this epoch (PROP_RAD_GROUP indexes)
	float rad_w_kg_2;
	float rad_w_kg_3;
	float rad_w_kg_4;
	float sea_radius_m;     // the sea shell's radius from the body centre; 0 = the body carries no shell
	float grav_self;        // 1/2 where the box's own mass sources the potential, 1 for a declared body
	uint lithify;           // 1 where the ladder holds the "lithify" derive record
	uint detect;            // 1 = the detect phase: only the neighbour classes, off settled state
	// THE LAST THREE WORDS ARE THE RESTATE'S OWN: LAFieldDriver::run_transport writes them at
	// size-12, size-8 and size-4, so nothing may be appended after them.
	uint restate;           // 0 = the field step's derive; 1 = the transport substep's restate
	uint args_slot;         // where this substep's level args start, in words
	uint act_base;          // where this row group's sorted list starts, in cells
} params;

const float SOLID_IN = 0.6;    // LAPhysical.SEDIMENT_LOAD_BEARING_SOLID_FRAC
const float SOLID_OUT = 0.555; // LAPhysical.SEDIMENT_RIGIDITY_SOLID_FRAC

// One row of `props` per channel, built from LASubstances by StateDerivePass. A channel amount is mol/m^3.
const int PROP_STRIDE = 79;        // StateDerivePass.PROP_STRIDE
// The (T, p) solve's budget: under-relaxed, so a pair on a latent plateau converges onto it.
const int LA_STATE_STEPS = 64;
const float LA_STATE_TOL = 1.0e-6;
const int PROP_M = 0;              // kg/mol
const int PROP_MOL_PER_KG = 1;     // mol/kg, non-condensable gases only
const int PROP_ENTRY = 2;          // which transport buffer carries this channel's heat
const int PROP_LAMBDA = 3;         // W/m/K
const int PROP_FULL = 4;           // mol/m^3 at which a cell is full — amount/full is its volume fraction
const int PROP_LITHIC = 5;         // 1 = a rock or metal phase; the solid flag reads their summed volume
const int PROP_RAD_GROUP = 6;
const int PROP_CONDENSED = 7;      // fills volume of its own and resists being squeezed
// THE SOLID AND THE MELT, each a block of PH_* words off LASubstances.eos_of(): one rule for both phases.
const int PROP_SOLID = 8;
const int PROP_LIQUID = 17;
const int PH_FULL = 0;             // mol/m^3 of the phase at its reference; 0 = the table names none
const int PH_ALPHA = 1;            // 1/K at one atmosphere; NaN = unmeasured
const int PH_BULK = 2;             // Pa, isothermal; NaN = unmeasured
const int PH_KP = 3;
const int PH_B4 = 4;               // Birch-Murnaghan fourth-order coefficient; 0 at third order
const int PH_TREF = 5;             // C
const int PH_LINEAR = 6;           // 1 = the source gives rho, not V, linear in T
const int PH_F_LO = 7;             // the strain bracket where P(f) rises
const int PH_F_HI = 8;
// EVERY CHANNEL'S OWN PHASE LADDER, laid out by LAMixtureEnthalpy::thermal_row so no boundary of the
// substance table is spelled here a second time. LA_APPROX: constant_specific_heat_per_phase
const int PROP_LADDER = 26;        // LAMixtureEnthalpy::THERMAL_ROW_WORDS floats, from here
const int TH_C_SOL = 0;            // J/kg/K of the solid phase
const int TH_C_LIQ = 1;
const int TH_C_GAS = 2;
const int TH_LINE_A1 = 3;        // the melting line's first coefficient
const int TH_LINE_P0 = 4;           // Pa, the melting line's p0
const int TH_FUSION_T0 = 5;        // C the first melt appears
const int TH_FUSION_T1 = 6;        // C the last crystal goes
const int TH_VAPOUR_T = 7;         // C the vapour curve's second anchor
const int TH_VAPOUR_P = 8;         // Pa there
const int TH_TRIPLE_T = 9;
const int TH_TRIPLE_P = 10;
const int TH_CRIT_T = 11;
const int TH_CRIT_P = 12;
const int TH_L_FUS = 13;           // J/kg
const int TH_L_VAP = 14;           // J/kg at TH_L_VAP_T
const int TH_L_VAP_T = 15;
const int TH_ATOMISATION = 16;     // J/mol
const int TH_S_GAS = 17;           // J/mol/K of the molecule
const int TH_S_ATOMS = 18;         // J/mol/K of its free atoms
const int TH_NU = 19;              // atoms per formula unit
const int TH_HAS_FUSION = 20;
const int TH_HAS_VAPOUR = 21;
const int TH_IAPWS = 22;
const int TH_N_EL = 23;
const int TH_EL_N = 24;            // LA_MAX_EL slots each, in formula order
const int TH_EL_CHI = 29;
const int TH_EL_G0 = 34;
const int TH_EL_G1 = 39;
const int TH_LINE_KIND = 44;       // 0 Clapeyron, 1 Simon, 2 reduced polynomial
const int TH_LINE_T0 = 45;         // K
const int TH_LINE_C1 = 46;
const int TH_LINE_A2 = 47;
const int TH_LINE_C2 = 48;
const int TH_ANCHOR_PHASE = 49;    // 0 solid, 1 liquid, 2 gas at the standard state
const int TH_ANCHOR_T = 50;        // C
const int TH_LINE_PREF = 51;       // Pa below which the melting line has not begun
const int TH_PR_KAPPA = 52;        // Peng-Robinson kappa; NaN where the table gives no acentric factor

float rad_w_kg(int group) {
	if (group == 1) { return params.rad_w_kg_1; }
	if (group == 2) { return params.rad_w_kg_2; }
	if (group == 3) { return params.rad_w_kg_3; }
	if (group == 4) { return params.rad_w_kg_4; }
	return 0.0;
}

// Transport entries: which of the three heat buffers carries a channel's enthalpy when its matter moves.
// Every channel's enthalpy comes off its OWN ladder; the entry says only where that heat lands.
const int E_H2O = 0;               // LAMatterChannels.Entry.H2O
const int E_SILICATE = 1;          // LAMatterChannels.Entry.SILICATE
const int E_SENSIBLE = 2;          // LAMatterChannels.Entry.SENSIBLE

// THE TABLE ROW OF ONE CHANNEL. LASubstances fills `props`, so no substance is spelled twice.
SubstanceTh la_sub_of(int i) {
	int b = i * PROP_STRIDE + PROP_LADDER;
	float el_n[LA_MAX_EL];
	float el_chi[LA_MAX_EL];
	float el_g0[LA_MAX_EL];
	float el_g1[LA_MAX_EL];
	for (int k = 0; k < LA_MAX_EL; ++k) {
		el_n[k] = props[b + TH_EL_N + k];
		el_chi[k] = props[b + TH_EL_CHI + k];
		el_g0[k] = props[b + TH_EL_G0 + k];
		el_g1[k] = props[b + TH_EL_G1 + k];
	}
	return SubstanceTh(
		props[b + TH_C_SOL], props[b + TH_C_LIQ], props[b + TH_C_GAS],
		props[b + TH_LINE_A1], props[b + TH_LINE_P0],
		props[b + TH_FUSION_T0], props[b + TH_FUSION_T1],
		props[b + TH_VAPOUR_T], props[b + TH_VAPOUR_P],
		props[b + TH_TRIPLE_T], props[b + TH_TRIPLE_P],
		props[b + TH_CRIT_T], props[b + TH_CRIT_P],
		props[b + TH_L_FUS], props[b + TH_L_VAP], props[b + TH_L_VAP_T],
		props[i * PROP_STRIDE + PROP_M], props[b + TH_ATOMISATION],
		props[b + TH_S_GAS], props[b + TH_S_ATOMS], props[b + TH_NU],
		props[b + TH_HAS_FUSION] != 0.0, props[b + TH_HAS_VAPOUR] != 0.0,
		props[b + TH_IAPWS] != 0.0, int(props[b + TH_N_EL]),
		el_n, el_chi, el_g0, el_g1,
		int(props[b + TH_LINE_KIND]), props[b + TH_LINE_T0], props[b + TH_LINE_C1],
		props[b + TH_LINE_A2], props[b + TH_LINE_C2],
		int(props[b + TH_ANCHOR_PHASE]), props[b + TH_ANCHOR_T], props[b + TH_LINE_PREF],
		props[b + TH_PR_KAPPA]);
}

// THE CELL ON THE BENCH: the channels it holds, and what each weighs in the reservoir being solved.
// Compact, so the walk costs the cell's own channels rather than the binding table's.
int mix_n = 0;
int mix_ch[LA_CHANNEL_SLOTS];
float mix_mf[LA_CHANNEL_SLOTS];    // the fluid's, kg
float mix_ml[LA_CHANNEL_SLOTS];    // the cemented lattice's, kg
int mix_sel = 0;                   // 0 = the fluid, 1 = the lattice

int la_mix_n() { return mix_n; }
float la_mix_mass(int k) { return mix_sel == 0 ? mix_mf[k] : mix_ml[k]; }
SubstanceTh la_mix_sub(int k) { return la_sub_of(mix_ch[k]); }

// The capacity of the phase this substance stands in at (T, p): dh/dT off its own ladder, off a plateau.
float la_phase_c(SubstanceTh s, float t_c, float p_pa) {
	if (!s.has_melt && !s.has_boil) { return s.c_sol; }
	if (la_sublimes_at(s, p_pa)) {
		return t_c <= la_sublimation_c_at(s, p_pa) ? s.c_sol : s.c_gas;
	}
	if (s.has_melt && t_c <= la_melt_c_at(s, p_pa, 0.0)) { return s.c_sol; }
	if (!s.has_boil || t_c <= la_boil_c_at(s, p_pa)) { return s.c_liq; }
	return s.c_gas;
}

// Conductivity, W/m/K: Maxwell-Eucken (Maxwell 1873; Eucken 1932), one CONTINUOUS phase `l_c` with the
// others dispersed in it, lambda = SUM f_i l_i b_i / SUM f_i b_i, b_i = 3 l_c / (l_i + 2 l_c). The
// volume mean it replaces is the Wiener bound: parallel slabs, which grains in air are not.
float la_mix_lambda(uint g, float cem, bool lattice, float l_c) {
	if (l_c <= 0.0) {
		return 0.0;
	}
	float num = 0.0;
	float den = 0.0;
	for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
		float f = max(channel_at(i, g), 0.0);
		int base = i * PROP_STRIDE;
		if (f <= 0.0 || props[base + PROP_FULL] <= 0.0) {
			continue;
		}
		bool lithic = props[base + PROP_LITHIC] > 0.0;
		float share = lattice ? (lithic ? cem : 0.0) : (lithic ? 1.0 - cem : 1.0);
		float vf = f / props[base + PROP_FULL] * share;
		float li = props[base + PROP_LAMBDA];
		float b = 3.0 * l_c / (li + 2.0 * l_c);
		num += vf * li * b;
		den += vf * b;
	}
	return den > 0.0 ? num / den : 0.0;
}

float la_ph(int i, int blk, int w) {
	return props[i * PROP_STRIDE + blk + w];
}

float la_ph_strain(int i, int blk, float dp) {
	return la_bm_strain_in(dp, la_ph(i, blk, PH_BULK), 1.5 * (la_ph(i, blk, PH_KP) - 4.0), la_ph(i, blk, PH_B4),
		la_ph(i, blk, PH_F_LO), la_ph(i, blk, PH_F_HI));
}

float la_ph_k_t(int i, int blk, float strain) {
	return la_bm_k_t(strain, la_ph(i, blk, PH_BULK), 1.5 * (la_ph(i, blk, PH_KP) - 4.0), la_ph(i, blk, PH_B4));
}

// LA_APPROX: separable_thermal_compression
// m^3 of `mol` moles of one phase at (t, dp) squeezed by `sq`, alpha * K_T held. Twin LAPhaseEosFn::phase_volume.
float la_ph_volume(int i, int blk, float mol, float t, float dp, float sq) {
	float full = la_ph(i, blk, PH_FULL);
	if (!(full > 0.0) || mol <= 0.0) {
		return 0.0;
	}
	float k = la_ph(i, blk, PH_BULK);
	float dt = t - la_ph(i, blk, PH_TREF);
	float al = dt == 0.0 ? 0.0 : la_ph(i, blk, PH_ALPHA) * (dp == 0.0 ? 1.0 : k / (k + la_ph(i, blk, PH_KP) * dp));
	float th = la_ph(i, blk, PH_LINEAR) > 0.0 ? 1.0 / (1.0 - al * dt) : 1.0 + al * dt;
	return mol / full * th * sq;
}

// LA_APPROX: linear_melt_lever
// The melt share of one channel at t: linear across an interval, the pinned progress at a point.
float la_ph_phi(int i, float t, float sol, float wid, bool pinned, float progress) {
	if (!(la_ph(i, PROP_SOLID, PH_FULL) > 0.0)) {
		return 1.0;
	}
	return wid > 0.0 ? clamp((t - sol) / wid, 0.0, 1.0)
		: ((pinned && t == sol) ? progress : (t < sol ? 0.0 : 1.0));
}

// A channel whose volume the condensed sums carry: h2o is kept apart, its vapour share is the solve's.
bool la_cond_channel(int i) {
	int base = i * PROP_STRIDE;
	return props[base + PROP_CONDENSED] > 0.0 && props[base + PROP_FULL] > 0.0
		&& int(props[base + PROP_ENTRY]) != E_H2O;
}

// THE BENCH AT ONE PRESSURE: each slot's phases squeezed under the fluid's pressure, and its melting
// interval there. A function of p alone, so the room loop reuses it at every temperature.
float bench_sq_s[LA_CHANNEL_SLOTS];
float bench_sq_l[LA_CHANNEL_SLOTS];
float bench_kt_s[LA_CHANNEL_SLOTS];
float bench_kt_l[LA_CHANNEL_SLOTS];
float bench_sol[LA_CHANNEL_SLOTS];
float bench_wid[LA_CHANNEL_SLOTS];

void la_melt_interval(int i, float p_pa, out float sol, out float wid) {
	SubstanceTh r = la_sub_of(i);
	sol = r.has_melt ? la_melt_c_at(r, p_pa, 0.0) : uintBitsToFloat(0x7F800000u);
	wid = r.has_melt ? la_liquidus_over(r, sol) - sol : 0.0;
}

void la_bench_at(float p_pa) {
	float dp = p_pa - LA_P_STD;
	for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
		if (k >= mix_n) { break; }
		int i = mix_ch[k];
		if (mix_mf[k] <= 0.0 || !la_cond_channel(i)) {
			continue;
		}
		float fs = la_ph_strain(i, PROP_SOLID, dp);
		float fl = la_ph_strain(i, PROP_LIQUID, dp);
		bench_sq_s[k] = la_bm_squeeze(fs);
		bench_sq_l[k] = la_bm_squeeze(fl);
		bench_kt_s[k] = la_ph_k_t(i, PROP_SOLID, fs);
		bench_kt_l[k] = la_ph_k_t(i, PROP_LIQUID, fl);
		la_melt_interval(i, p_pa, bench_sol[k], bench_wid[k]);
	}
}

// The fluid's condensed volume at (t, p), m^3: `b` all of it, `g` its loose lithic grains, `c` the
// compressibility of the rest. LOOSE GRAINS PRESS NOTHING: they take volume; the fluid alone is compressed,
// at the compressibility each phase has AT this pressure.
struct FluidVol { float b; float g; float c; };

FluidVol la_fluid_volumes(float p_pa, float t, bool pinned, float progress) {
	FluidVol v = FluidVol(0.0, 0.0, 0.0);
	float dp = p_pa - LA_P_STD;
	for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
		if (k >= mix_n) { break; }
		int i = mix_ch[k];
		if (mix_mf[k] <= 0.0 || !la_cond_channel(i)) {
			continue;
		}
		float mol = mix_mf[k] / props[i * PROP_STRIDE + PROP_M];
		float phi = la_ph_phi(i, t, bench_sol[k], bench_wid[k], pinned, progress);
		float vs = phi < 1.0 ? (1.0 - phi) * la_ph_volume(i, PROP_SOLID, mol, t, dp, bench_sq_s[k]) : 0.0;
		float vl = phi > 0.0 ? phi * la_ph_volume(i, PROP_LIQUID, mol, t, dp, bench_sq_l[k]) : 0.0;
		v.b += vs + vl;
		if (props[i * PROP_STRIDE + PROP_LITHIC] > 0.0) {
			v.g += vs + vl;
		} else {
			v.c += (phi < 1.0 ? vs / bench_kt_s[k] : 0.0) + (phi > 0.0 ? vl / bench_kt_l[k] : 0.0);
		}
	}
	return v;
}

// THE LATTICE STANDS UNDER THE ROCK'S OWN PRESSURE, not the pore fluid's: a cemented frame carries the
// column over it. Its grains' volume at the lattice's own temperature, m^3.
float la_lattice_volume(float p_rock, float t_l, bool pinned_l, float progress_l) {
	float dp = p_rock - LA_P_STD;
	float v = 0.0;
	for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
		if (k >= mix_n) { break; }
		int i = mix_ch[k];
		if (mix_ml[k] <= 0.0 || !la_cond_channel(i)) {
			continue;
		}
		float mol = mix_ml[k] / props[i * PROP_STRIDE + PROP_M];
		float sol;
		float wid;
		la_melt_interval(i, p_rock, sol, wid);
		float phi = la_ph_phi(i, t_l, sol, wid, pinned_l, progress_l);
		v += phi < 1.0 ? (1.0 - phi)
			* la_ph_volume(i, PROP_SOLID, mol, t_l, dp, la_bm_squeeze(la_ph_strain(i, PROP_SOLID, dp))) : 0.0;
		v += phi > 0.0 ? phi
			* la_ph_volume(i, PROP_LIQUID, mol, t_l, dp, la_bm_squeeze(la_ph_strain(i, PROP_LIQUID, dp))) : 0.0;
	}
	return v;
}

// m^3/kg of the water channel at (t, p): liquid on the IAPWS curve or ice, each squeezed on its own
// isotherm, split by the melting point the way the free water is.
float la_water_v_m3_kg(int wc, SubstanceTh w, float t, float p_pa, bool pinned, float progress) {
	float dp = p_pa - LA_P_STD;
	float melt_t = la_melt_c_at(w, p_pa, 0.0);
	float molten = (pinned && t == melt_t) ? progress : (t < melt_t ? 0.0 : 1.0);
	float v_liq = la_water_liquid_v_m3_kg(t) * la_bm_squeeze(la_ph_strain(wc, PROP_LIQUID, dp));
	float v_ice = la_ph_volume(wc, PROP_SOLID, 1.0 / props[wc * PROP_STRIDE + PROP_M], t, dp,
		la_bm_squeeze(la_ph_strain(wc, PROP_SOLID, dp)));
	return molten * v_liq + (1.0 - molten) * v_ice;
}

// One species' share of the Peng-Robinson mixture sums at T, `n` moles of channel i's fluid: s_a =
// sum n sqrt(a(T)) with its first two T-derivatives, and s_b = sum n b.
void la_pr_add(int i, float n, float t_k, inout vec4 s) {
	if (n <= 0.0) {
		return;
	}
	int b = i * PROP_STRIDE + PROP_LADDER;
	float tc = props[b + TH_CRIT_T] + LA_KELVIN_OFFSET;
	float kap = props[b + TH_PR_KAPPA];
	float ra = sqrt(la_pr_a_c(tc, props[b + TH_CRIT_P]));
	float rt = sqrt(t_k / tc);
	float u = 1.0 + kap * (1.0 - rt);
	float sg = u < 0.0 ? -1.0 : 1.0;
	s.x += n * ra * abs(u);
	s.y += n * ra * sg * (-0.5 * kap / sqrt(t_k * tc));
	s.z += n * ra * sg * (0.25 * kap / (t_k * sqrt(t_k * tc)));
	s.w += n * la_pr_b(tc, props[b + TH_CRIT_P]);
}

// The cell's gas at T: every gas channel's own moles and its vapours'.
vec4 la_pr_sums(float t_k, int ch_w, float n_h2o_vap, int ch_r, float n_sil_vap) {
	vec4 s = vec4(0.0);
	la_pr_add(ch_w, n_h2o_vap, t_k, s);
	la_pr_add(ch_r, n_sil_vap, t_k, s);
	for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
		if (k >= mix_n) { break; }
		int i = mix_ch[k];
		la_pr_add(i, mix_mf[k] * props[i * PROP_STRIDE + PROP_MOL_PER_KG], t_k, s);
	}
	return s;
}

// The enthalpy one channel holds at the state the solve landed on, J.
float la_channel_h(SubstanceTh s, float m_kg, float t_c, float p_pa, float room_m3, bool pinned,
		float progress) {
	if (m_kg <= 0.0) {
		return 0.0;
	}
	float h = m_kg * la_mix_specific_enthalpy(s, t_c, p_pa, m_kg, room_m3, 0.0);
	return pinned ? h + progress * la_mix_jump_of(s, m_kg, t_c, p_pa, room_m3, 0.0) : h;
}

// Cementation and the solid flag, from the melt share this cell just derived. No mass moves here, and the
// pressure it reads is the one the enthalpy solve above read: the column solved at the end of the last step.
// `v_lithic` is the summed volume fraction of the cell's rock and metal phases.
void lithify(uint g, float melt, float v_lithic) {
	// A melt carries no cement.
	float cem = min(clamp(cement[g], 0.0, 1.0), 1.0 - melt);
	float excess = max(pressure[g] - params.lith_pressure_pa, 0.0);
	cem = clamp(cem + params.lith_rate_per_pa * excess * (1.0 - melt - cem), 0.0, 1.0 - melt);
	cement[g] = cem;

	// Rock volume fraction: the lithic phases over their full amounts, times the cemented share.
	float rock = v_lithic * cem;
	bool was = solid[g] != 0.0;
	bool now = was ? (rock >= SOLID_OUT) : (rock >= SOLID_IN);
	if (now) {
		// Enclosed h2o is now pore water: same channel, different place. The cell has become aquifer.
		if (h2o[g] > 0.0) {
			regolith[g] = 1.0;
			grain[g] = max(grain[g], params.fresh_grain_m);
		}
		solid[g] = 1.0;
		return;
	}
	solid[g] = 0.0;
}



// THE DETECT PHASE: a class about the cells AROUND one, dispatched after a barrier so every
// neighbour it reads is settled. Thresholds sit after the channel rows of `props`.
const int DET_WET = 0;        // mol/m^3 of liquid h2o that makes a cell wet
const int DET_ICE = 1;        // mol/m^3 of frozen h2o that makes a sea-surface cell frozen
const int DET_BODY = 2;       // mol/m^3 of melt an open cell holds to be part of the melt body
const int DET_DRAINED = 3;    // mol/m^3 under which a neighbour counts as drained of that melt
const int DET_MOLTEN = 4;     // mol/m^3 of melt the readback resolves above zero

float det(int k) {
	return props[LA_CHANNEL_SLOTS * PROP_STRIDE + k];
}

// The neighbour across cell `c`'s slot `d`; -1 where that slot carries no face.
int la_nb(uint c, uint d) {
	uint f = la_slot_lo(c, d);
	return (f < la_slot_hi(c, d)) ? nbr[f] : -1;
}

vec3 la_vel(uint c) {
	return vec3(vel_x[c], vel_y[c], vel_z[c]);
}

vec3 la_cell_pos(uint c) {
	return vec3(pos[c * 3u], pos[c * 3u + 1u], pos[c * 3u + 2u]);
}

// The local vertical: away from the mass. Zero where no solve has said which way is down.
vec3 la_up(uint c) {
	vec3 gv = vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
	float l = length(gv);
	return (l > 0.0) ? -gv / l : vec3(0.0);
}

float la_melt_at(uint c) {
	return max(silicate[c], 0.0) * clamp(silicate_melt[c], 0.0, 1.0);
}

float la_liquid_at(uint c) {
	return max(h2o[c], 0.0) * clamp(h2o_liquid[c], 0.0, 1.0);
}

// d(velocity)/d(axis) across the pair of slots on one axis, 1/s.
vec3 la_axis_deriv(uint c, uint lo_slot, uint hi_slot) {
	int lo = la_nb(c, lo_slot);
	int hi = la_nb(c, hi_slot);
	float d_lo = max(la_face_dist(c, lo), 1.0e-6);
	float d_hi = max(la_face_dist(c, hi), 1.0e-6);
	if (lo >= 0 && hi >= 0) {
		return (la_vel(uint(hi)) - la_vel(uint(lo))) / (d_lo + d_hi);
	}
	if (hi >= 0) {
		return (la_vel(uint(hi)) - la_vel(c)) / d_hi;
	}
	if (lo >= 0) {
		return (la_vel(c) - la_vel(uint(lo))) / d_lo;
	}
	return vec3(0.0);
}

// Air spin about the local vertical at `c`, 1/s.
float la_spin(uint c) {
	vec3 dx = la_axis_deriv(c, 0u, 1u);
	vec3 dy = la_axis_deriv(c, 2u, 3u);
	vec3 dz = la_axis_deriv(c, 4u, 5u);
	vec3 curl = vec3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x);
	return abs(dot(curl, la_up(c)));
}

// The outermost cell of a column: rock with sky over it, or free water with dry sky over it.
float la_surface_class(uint g) {
	if (la_up(g) == vec3(0.0)) {
		return 0.0;                                 // nothing has solved which way is up
	}
	int hi = vert_up[g];
	bool open_above = (hi < 0) || (solid[uint(hi)] == 0.0);
	if (solid[g] != 0.0) {
		return open_above ? 3.0 : 0.0;
	}
	if (la_liquid_at(g) < det(DET_WET)) {
		return 0.0;
	}
	if (hi >= 0 && (!open_above || la_liquid_at(uint(hi)) >= det(DET_WET))) {
		return 0.0;                                 // a mid-column cell, not the free surface
	}
	float ice = max(h2o[g], 0.0) * clamp(h2o_solid[g], 0.0, 1.0);
	return (ice > det(DET_ICE)) ? 2.0 : 1.0;
}

// Melt in the open: its INTERIOR is walled by rock or by more of itself, its RIND is not.
float la_melt_body(uint g) {
	if (solid[g] != 0.0 || silicate_melt[g] <= 0.0 || la_melt_at(g) < det(DET_BODY)) {
		return 0.0;
	}
	for (uint f = la_face_lo(g); f < la_face_hi(g); ++f) {
		int nb = nbr[f];
		if (nb < 0) {
			return 1.0;
		}
		if (solid[uint(nb)] != 0.0) {
			continue;
		}
		if (silicate_melt[uint(nb)] <= 0.0 || la_melt_at(uint(nb)) < det(DET_DRAINED)) {
			return 1.0;
		}
	}
	return 2.0;
}

// Melt standing in an open cell that no neighbour tops: melt that reached the surface.
float la_erupt(uint g) {
	float here = la_melt_at(g);
	if (solid[g] != 0.0 || here < det(DET_MOLTEN)) {
		return 0.0;
	}
	for (uint f = la_face_lo(g); f < la_face_hi(g); ++f) {
		int nb = nbr[f];
		if (nb >= 0 && la_melt_at(uint(nb)) > here) {
			return 0.0;
		}
	}
	return 1.0;
}

// A closed low with a warm core spinning harder than its ring, on the ground layer of an air column.
// The ring is the cell's own horizontal neighbours: the faces whose step is across the local vertical.
float la_cyclone(uint g) {
	vec3 up = la_up(g);
	if (up == vec3(0.0)) {
		return 0.0;                                 // nothing has solved which way is up
	}
	int lo = vert_down[g];
	if (solid[g] != 0.0 || lo < 0 || solid[uint(lo)] == 0.0) {
		return 0.0;
	}
	vec3 here = la_cell_pos(g);
	float p_sum = 0.0;
	float t_sum = 0.0;
	float z_sum = 0.0;
	uint n = 0u;
	for (uint f = la_face_lo(g); f < la_face_hi(g); ++f) {
		int nb = nbr[f];
		if (nb < 0) {
			continue;
		}
		vec3 d = la_cell_pos(uint(nb)) - here;
		float dl = length(d);
		if (dl <= 0.0 || abs(dot(d / dl, up)) >= 0.5) {
			continue;                               // the vertical pair, not the ring
		}
		if (solid[uint(nb)] != 0.0 || pressure[uint(nb)] <= pressure[g]) {
			return 0.0;                             // walled in, or the low is not closed
		}
		p_sum += pressure[uint(nb)];
		t_sum += temp[uint(nb)];
		z_sum += la_spin(uint(nb));
		n += 1u;
	}
	if (n < 4u) {
		return 0.0;                                 // an incomplete ring cannot say a low is closed
	}
	float w = float(n);
	return (temp[g] > t_sum / w && la_spin(g) > z_sum / w) ? 1.0 : 0.0;
}


void main() {
	uint g = gl_GlobalInvocationID.x;
	if (params.detect != 0u) {
		if (g < params.cell_count) {
			surface_class[g] = la_surface_class(g);
			melt_body[g] = la_melt_body(g);
			erupt[g] = la_erupt(g);
			cyclone[g] = la_cyclone(g);
		}
		return;
	}
	// THE SAME SOLVE INSIDE THE SUBSTEP: what the substep moved is at a new pressure before the next face
	// reads one.
	if (params.restate != 0u) {
		if (g >= level_args[params.args_slot + 6u]) {
			return;
		}
		g = level_idx[params.act_base + level_args[params.args_slot + 4u] + g];
	}
	if (g >= params.cell_count) {
		return;
	}

	float vol = cell_volume(g);

	// GEOMETRY, which does not depend on what the cell holds. No spin axis is no latitude and no sea shell
	// is no altitude, so both read NaN there and every gate then admits the cell nowhere.
	vec3 omega = vec3(params.omega_x, params.omega_y, params.omega_z);
	vec3 r_vec = vec3(pos[g * 3u], pos[g * 3u + 1u], pos[g * 3u + 2u])
		- vec3(params.centre_x, params.centre_y, params.centre_z);
	float r_len = length(r_vec);
	float w_len = length(omega);
	// WHAT MATTER AT REST IN THIS FRAME IS PULLED BY: gravitation and the spin's centrifugal term. Read
	// as geometry, before any matter is, so every balance stands against the one field.
	vec3 g_eff = vec3(g_field[g * 3u], g_field[g * 3u + 1u], g_field[g * 3u + 2u])
		- cross(omega, cross(omega, r_vec));
	float nf = 0.0;
	// GEOMETRY AND THE PER-STEP BOOKS: neither moves inside a step.
	if (params.restate == 0u) {
		alt[g] = (params.sea_radius_m > 0.0) ? r_len - params.sea_radius_m
			: uintBitsToFloat(0x7FC00000u);
		r_frac[g] = (params.sea_radius_m > 0.0) ? r_len / params.sea_radius_m
			: uintBitsToFloat(0x7FC00000u);
		g_rest[g * 3u] = g_eff.x;
		g_rest[g * 3u + 1u] = g_eff.y;
		g_rest[g * 3u + 2u] = g_eff.z;
		lat[g] = (w_len > 0.0 && r_len > 0.0)
			? degrees(asin(clamp(dot(r_vec / r_len, omega / w_len), -1.0, 1.0)))
			: uintBitsToFloat(0x7FC00000u);

		for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
			float v = channel_at(i, g);
			nf += (isnan(v) || isinf(v)) ? 1.0 : 0.0;
		}
		float hv = e_j_m3[g];
		nf += (isnan(hv) || isinf(hv)) ? 1.0 : 0.0;
		vec3 pv = vec3(mom_x[g], mom_y[g], mom_z[g]);
		nf += (isnan(pv.x) || isinf(pv.x)) ? 1.0 : 0.0;
		nf += (isnan(pv.y) || isinf(pv.y)) ? 1.0 : 0.0;
		nf += (isnan(pv.z) || isinf(pv.z)) ? 1.0 : 0.0;

		// The dead pool's molar ratios, from the same channels the reduce rows sum.
		float org_pool = max(detritus[g], 0.0) + max(fuel[g], 0.0);
		if (org_pool > 0.0) {
			float hc = max(org_h[g], 0.0) / org_pool;
			float oc = max(org_o[g], 0.0) / org_pool;
			org_hc[g] = hc;
			org_oc[g] = oc;
			org_fresh[g] = min(hc / params.fresh_h_per_c, oc / params.fresh_o_per_c);
		} else {
			float no_pool = uintBitsToFloat(0x7F800000u);
			org_hc[g] = no_pool;
			org_oc[g] = no_pool;
			org_fresh[g] = no_pool;
		}
	}

	// TWO RESERVOIRS: the cemented lattice with its pore water, and the fluid; each has its own energy and T.
	mix_n = 0;
	mix_sel = 0;
	float total = 0.0;       // kg the cell holds
	float total_f = 0.0;     // the fluid's
	float total_l = 0.0;     // the lattice's
	float m_h2o = 0.0;       // the FREE water, kg
	float m_h2o_lat = 0.0;   // pore water, the lattice's
	float m_sil_f = 0.0;     // the silicate entry's, fluid and lattice
	float m_sil_l = 0.0;
	int ch_h2o = -1;         // the channel whose substance is water, and the one that is rock
	int ch_sil = -1;
	float cp_gas = 0.0;      // sum of m*cp over the non-condensable gases, J/K: the mixture gamma's cp
	float m_gas = 0.0;       // kg of non-condensable gas
	float n_gas_mol = 0.0;   // moles of non-condensable gas
	// The CONTINUOUS phase of each reservoir: the one that fills most of it, the fluid's taken over its
	// non-grain phases so a grain pack's heat crosses the pore.
	float host_f = 0.0; float host_lambda_f = 0.0;
	float any_f = 0.0; float any_lambda_f = 0.0;
	float host_l = 0.0; float host_lambda_l = 0.0;
	float v_lat = 0.0;       // volume fraction of the cemented lattice
	float v_lithic = 0.0;    // volume fraction of rock and metal phases: what the solid flag reads
	float rad_w = 0.0;       // radiogenic power of the cell's matter, W/m^3
	float lith_frac = 0.0; float lith_kg = 0.0;
	float mol_h2o_f = 0.0;   // the free water's moles; the pore channel is the lattice's
	float full_h2o = 0.0;
	float cem = clamp(cement[g], 0.0, 1.0);

	for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
		int base = i * PROP_STRIDE;
		int entry = int(props[base + PROP_ENTRY]);
		// The water row and the rock row, by substance: the phase shares this pass publishes are theirs.
		ch_h2o = (entry == E_H2O && ch_h2o < 0) ? i : ch_h2o;
		ch_sil = (entry == E_SILICATE && ch_sil < 0) ? i : ch_sil;
		float f = max(channel_at(i, g), 0.0);
		if (f <= 0.0) {
			continue;
		}
		float m = f * props[base + PROP_M] * vol;
		bool lithic = props[base + PROP_LITHIC] > 0.0;
		bool is_water = entry == E_H2O;
		full_h2o = is_water ? props[base + PROP_FULL] : full_h2o;
		// The lattice's share: the cemented part of a lithic channel. Pore water joins it below.
		float sl = lithic ? cem : 0.0;
		float m_free = m * (1.0 - sl);
		float m_lat = m * sl;
		mix_ch[mix_n] = i;
		mix_mf[mix_n] = m_free;
		mix_ml[mix_n] = m_lat;
		mix_n += 1;
		total += m;
		total_f += m_free;
		total_l += m_lat;
		m_h2o += is_water ? m_free : 0.0;
		m_h2o_lat += is_water ? m_lat : 0.0;
		m_sil_f += entry == E_SILICATE ? m_free : 0.0;
		m_sil_l += entry == E_SILICATE ? m_lat : 0.0;
		float vf = f / props[base + PROP_FULL];
		float lam = props[base + PROP_LAMBDA];
		float vf_f = vf * (1.0 - sl);
		if (vf_f > any_f) { any_f = vf_f; any_lambda_f = lam; }
		if (!lithic && vf_f > host_f) { host_f = vf_f; host_lambda_f = lam; }
		if (vf * sl > host_l) { host_l = vf * sl; host_lambda_l = lam; }
		v_lat += vf * sl;
		v_lithic += lithic ? vf : 0.0;
		if (props[base + PROP_CONDENSED] > 0.0 && !is_water) {
			lith_frac += vf;
			lith_kg += m;
		}
		rad_w += f * props[base + PROP_M] * rad_w_kg(int(props[base + PROP_RAD_GROUP]));
		n_gas_mol += m * props[base + PROP_MOL_PER_KG];
		if (props[base + PROP_MOL_PER_KG] > 0.0) {
			cp_gas += m * props[base + PROP_LADDER + TH_C_GAS];
			m_gas += m;
		}
		// The free water's own moles. Its volume, and every other condensed volume, is read at the
		// pressure the solve stands on: la_bench_at.
		if (props[base + PROP_CONDENSED] > 0.0 && props[base + PROP_FULL] > 0.0) {
			mol_h2o_f += is_water ? f * vol * (1.0 - sl) : 0.0;
		}
	}

	rad_w_m3[g] = rad_w;
	float inv_vol = (vol > 0.0) ? 1.0 / vol : 0.0;
	// The water and rock rows, read once: the lattice's temperature comes off its own energy, with no gas
	// room and the rock's own pressure for its melting point.
	// StateDerivePass packs a water and a rock entry in every table, so both indices are set.
	SubstanceTh w_sub = la_sub_of(ch_h2o);
	SubstanceTh r_sub = la_sub_of(ch_sil);
	bool pinned_l = false;
	float progress_l = 0.0;
	// Solved with the fluid below, at the pressure that solve is standing on.
	float t_l = 0.0;
	float p_rock = 0.0;
	conductivity[g] = la_mix_lambda(g, cem, false, host_lambda_f > 0.0 ? host_lambda_f : any_lambda_f);
	conductivity_lith[g] = la_mix_lambda(g, cem, true, host_lambda_l);
	lattice_frac[g] = clamp(v_lat, 0.0, 1.0);
	float rho = total * inv_vol;     // kg/m^3, gas included: gravity pulls on all of it
	rho_bulk[g] = rho;
	// Pore water is the lattice's; its volume is read at the lattice's own state inside the solve.
	float pore_kg = m_h2o_lat;
	float pore_m3 = 0.0;
	lithic_kg[g] = (lith_kg + pore_kg) * inv_vol;
	vec3 v_frame = cross(omega, r_vec);
	pe_j_m3[g] = rho * (params.grav_self * (grav_phi[g] + grav_ref[g]) - 0.5 * dot(v_frame, v_frame));
	float ke = 0.0;              // J/m^3 of bulk motion, the reservoir a lockup dissipates into
	ke_j_m3[g] = ke;
	float f_melt = 0.0;
	vec3 v = vec3(0.0);
	// No matter: the cell is EMPTY, and its DERIVED bulk state is none. Momentum with no mass to carry it
	// is an orphan the momentum_orphan_cells row counts; it is never zeroed here.
	if (rho <= 0.0) {
		vec3 pm = vec3(mom_x[g], mom_y[g], mom_z[g]);
		mom_orphan[g] = dot(pm, pm) > 0.0 ? 1.0 : 0.0;
		temp[g] = -LA_KELVIN_OFFSET;   // no matter, so no temperature
		temp_lith[g] = -LA_KELVIN_OFFSET;
		cap_lith[g] = 0.0;
		lithic_frac[g] = 0.0;
		if (solid[g] == 0.0) {
			pressure[g] = 0.0;
		}
		p_fluid[g] = 0.0;
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		speed[g] = 0.0;
		h2o_solid[g] = 0.0;
		h2o_liquid[g] = 0.0;
		h2o_vapour[g] = 0.0;
		water_rho[g] = 0.0;
		liquid[g] = 0.0;
		silicate_melt[g] = 0.0;
		h_h2o[g] = 0.0;
		h_h2o_vap[g] = 0.0;
		h_silicate[g] = 0.0;
		h_sensible[g] = 0.0;
		cap_sensible[g] = 0.0;
		k_cond[g] = 0.0;
		gas_r[g] = 0.0;
		gas_gamma[g] = 0.0;
		mach[g] = 0.0;
		if (params.restate == 0u) {
			bodyf_x[g] = 0.0;
			bodyf_y[g] = 0.0;
			bodyf_z[g] = 0.0;
			nonfinite[g] = nf;
			unconverged[g] = 0.0;
			lithify(g, f_melt, v_lithic);
		}
		return;   // no mass, so the frame terms deliver no momentum either
	}
	mom_orphan[g] = 0.0;
	// v = p/rho over the matter that moves: the lattice's grains stand still.
	float rho_f = max(rho - lith_kg * inv_vol, 0.0);
	v = rho_f > 0.0 ? vec3(mom_x[g], mom_y[g], mom_z[g]) / rho_f : vec3(0.0);
	ke = 0.5 * rho_f * dot(v, v);
	// LOCKED ROCK HOLDS NO BULK MOTION, and the motion it loses is heat: it joins the internal energy
	// before this cell's temperature is read off it, so the state published is the one dissipation left.
	if (solid[g] != 0.0) {
		e_j_m3[g] += ke;
		mom_x[g] = 0.0;
		mom_y[g] = 0.0;
		mom_z[g] = 0.0;
		v = vec3(0.0);
		ke = 0.0;
	}
	vel_x[g] = v.x;
	vel_y[g] = v.y;
	vel_z[g] = v.z;
	speed[g] = length(v);
	ke_j_m3[g] = ke;

	// No channel carries a dissolved solute, so the freezing point is not depressed.
	bool pinned = false;
	float progress = 0.0;
	float mol_sil = r_sub.molar_mass > 0.0 ? m_sil_f / r_sub.molar_mass : 0.0;
	// Solved below. The pressure a LOCKED cell's free fluid was sealed with is state; an open cell's is
	// this solve's own last answer, a starting iterate the residual test below is free of.
	float t_c = 0.0;
	float p_pa = solid[g] != 0.0 ? p_fluid[g] : pressure[g];
	float e_fluid = e_j_m3[g];
	// The fluid's room: the cell less what its condensed lithic matter fills. H = U + pV over it.
	float room_f = 1.0 - clamp(lith_frac, 0.0, 1.0);
	float f_solid = 0.0;
	float f_liquid = 0.0;
	float f_vapour = 0.0;
	float f_vap_sil = 0.0;
	float b_vol = 0.0;
	float c_comp = 0.0;
	float vw = 0.0;          // m^3 of condensed h2o, its liquid and its ice each at its own density
	float cw = 0.0;
	// THE GAS ROOM: the cell less every condensed volume, where the vapour stands at saturation. The
	// lattice's volume is its grains and the water in its pores, liquid or ice by its own melting point.
	float lat_vol = 0.0;
	float room_gas = 0.0;
	FluidVol cv = FluidVol(0.0, 0.0, 0.0);
	// The free water's own phases, off its row's blocks: the one rule, not a copy of its numbers.
	int wc = ch_h2o;
	float mol_per_kg_h2o = 1.0 / props[wc * PROP_STRIDE + PROP_M];
	// ONE STATE: the ladder gives T(h, p) and the EOS p(T) off the same matter, so they solve together.
	float p_lo = 0.0;
	float p_hi = 0.0;
	bool has_lo = false;
	bool has_hi = false;
	float p_prev_it = p_pa;
	float p_was = p_pa;      // the pair the previous outer iteration stood on
	float t_was = 0.0;
	float f_prev = 0.0;
	bool converged = false;
	for (int it = 0; it < LA_STATE_STEPS; ++it) {
		// EVERY READING BELOW IS A FUNCTION OF THE CELL AND THIS PRESSURE. The lattice stands under the
		// column in a locked cell, and under the fluid plus half its own rock's weight in a cut one.
		p_rock = solid[g] != 0.0 ? pressure[g]
			: p_pa + 0.5 * total_l * inv_vol * length(g_eff) * cell_edge[g];
		la_bench_at(p_pa);
		if (total_l > 0.0) {
			mix_sel = 1;
			t_l = la_mix_state(e_lith_j_m3[g] * vol, p_rock, 0.0, 0.0, pinned_l, progress_l);
			mix_sel = 0;
		}
		pore_m3 = pore_kg * la_water_v_m3_kg(wc, w_sub, t_l, p_rock, pinned_l, progress_l);
		room_f = 1.0 - clamp(lith_frac + pore_m3 * inv_vol, 0.0, 1.0);
		lat_vol = la_lattice_volume(p_rock, t_l, pinned_l, progress_l) + pore_m3;
		if (total_f <= 0.0) {
			// Bare lattice with no fluid: nothing to solve a fluid state for, and the rock's is the cell's.
			converged = true;
			t_c = t_l;
			b_vol = lat_vol;
			break;
		}
		// THE ROOM'S OWN STARTING ITERATE, the cell less its lattice: what the fluid's condensed phases
		// take out of it is what the loop below settles. Never carried from another pressure.
		room_gas = vol - lat_vol;
		float room_prev = -1.0;
		// The free water's own squeeze here: the strain is a function of p, so the room loop re-reads it.
		float dp_w = p_pa - LA_P_STD;
		float f_bm_liq = la_ph_strain(wc, PROP_LIQUID, dp_w);
		float f_bm_ice = la_ph_strain(wc, PROP_SOLID, dp_w);
		float sq_liq = la_bm_squeeze(f_bm_liq);
		float sq_ice = la_bm_squeeze(f_bm_ice);
		float kt_liq = la_ph_k_t(wc, PROP_LIQUID, f_bm_liq);
		float kt_ice = la_ph_k_t(wc, PROP_SOLID, f_bm_ice);
		bool settled = false;
		for (int k = 0; k < LA_STATE_STEPS; ++k) {
			pinned = false;
			progress = 0.0;
			t_c = la_mix_state((e_fluid + p_pa * room_f) * vol, p_pa, room_gas, 0.0, pinned, progress);
			if (isnan(t_c)) { break; }   // no state: the cell is counted nonfinite, not iterated

			// The h2o split: the room's vapour, the rest solid or liquid by the melting point.
			f_solid = 0.0;
			f_liquid = 0.0;
			f_vapour = 0.0;
			if (m_h2o > 0.0) {
				SubstanceTh w = w_sub;
				f_vapour = la_mix_vapour_fraction(w, t_c, p_pa, m_h2o, room_gas, 0.0);
				float melt_t = la_melt_c_at(w, p_pa, 0.0);
				float molten = (pinned && t_c == melt_t) ? progress : (t_c < melt_t ? 0.0 : 1.0);
				float condensed = max(1.0 - f_vapour, 0.0);
				f_solid = condensed * (1.0 - molten);
				f_liquid = condensed * molten;
			}
			f_vap_sil = m_sil_f > 0.0
				? la_mix_vapour_fraction(r_sub, t_c, p_pa, m_sil_f, room_gas, 0.0) : 0.0;

			// Liquid and ice volumes, each squeezed on its own bulk modulus.
			vw = 0.0;
			cw = 0.0;
			if (m_h2o > 0.0) {
				float v_liq = la_water_liquid_v_m3_kg(t_c) * sq_liq;
				float v_ice = la_ph_volume(wc, PROP_SOLID, mol_per_kg_h2o, t_c, dp_w, sq_ice);
				vw = m_h2o * (f_liquid * v_liq + f_solid * v_ice);
				cw = m_h2o * (f_liquid * v_liq / kt_liq + f_solid * v_ice / kt_ice);
			}
			cv = la_fluid_volumes(p_pa, t_c, pinned, progress);
			b_vol = cv.b + lat_vol + vw;
			c_comp = cv.c + cw;
			float room_next = vol - b_vol;
			// The gas pressure is n R T over this room, so the room settles to the pressure's own
			// tolerance -- or, where it is a difference of volumes of the CELL's order and resolves no
			// finer than they do, to the float32 fixed point or two-cycle the iteration lands in.
			settled = abs(room_next - room_gas) <= LA_STATE_TOL * room_gas
				|| room_next == room_gas || room_next == room_prev;
			room_prev = room_gas;
			room_gas = room_next;
			if (settled) {
				break;
			}
		}
		if (!settled) {
			break;
		}
		float n_gas = n_gas_mol + f_vapour * mol_h2o_f + f_vap_sil * mol_sil;
		float tk = t_c + LA_KELVIN_OFFSET;
		// The gas mixture's Peng-Robinson sums, the vapours with their own rows' constants.
		vec4 pr = la_pr_sums(tk, ch_h2o, f_vapour * mol_h2o_f, ch_sil, f_vap_sil * mol_sil);
		float s_a = pr.x;
		float s_b = pr.w;
		// A LOCKED CELL'S FREE FLUID KEEPS THE PRESSURE IT WAS SEALED WITH: its room is the rock's volume
		// error, which the pressure split names hypersensitive, so no state function sets it there.
		if (solid[g] != 0.0) {
			converged = true;
			break;
		}
		// Linearised about the pressure this iteration stands on, which is where B and C were read.
		float p_next = la_eos_p(vol, n_gas * LA_R_J_MOL_K * tk, s_a, s_b, b_vol, c_comp, p_pa);
		float f = p_next - p_pa;
		// THE STATE STOPPED MOVING, and not only the residual: a residual bound accepts anywhere inside
		// its own ball, and which point it lands on depends on the arithmetic the driver compiled with.
		bool still = it > 0 && abs(p_pa - p_was) <= LA_STATE_TOL * max(p_pa, 1.0)
			&& abs(t_c - t_was) <= LA_STATE_TOL * max(abs(t_c), 1.0);
		if (still && abs(f) <= LA_STATE_TOL * max(p_pa, 1.0)) {
			converged = true;
			break;
		}
		// Full steps of p_eos(T(h, p)) until the residual changes sign, then secant inside the bracket.
		if (f > 0.0) { p_lo = p_pa; has_lo = true; } else { p_hi = p_pa; has_hi = true; }
		float p_step = p_next;
		if (has_lo && has_hi) {
			// The root is found when the bracket is: the residual carries T's rounding through p_sat(T).
			if (p_hi - p_lo <= LA_STATE_TOL * max(p_pa, 1.0)) {
				converged = true;
				break;
			}
			if (abs(f - f_prev) > 1.0e-30 * max(p_pa, 1.0)) {
				p_step = p_pa - f * (p_pa - p_prev_it) / (f - f_prev);
			}
			if (!(p_step > p_lo && p_step < p_hi)) {
				p_step = 0.5 * (p_lo + p_hi);
			}
		}
		p_prev_it = p_pa;
		f_prev = f;
		p_was = p_pa;
		t_was = t_c;
		p_pa = p_step;
	}
	// No lattice is no lattice temperature: the rock's reading is the cell's own.
	if (total_l <= 0.0) {
		t_l = t_c;
	}
	lithic_frac[g] = clamp(lith_frac + pore_m3 * inv_vol, 0.0, 1.0);
	temp[g] = t_c;
	temp_lith[g] = t_l;
	if (solid[g] == 0.0) {
		pressure[g] = p_pa;
	}
	p_fluid[g] = p_pa;

	// THE LATTICE'S ENTHALPY at its temperature: a solid cell's energy is split by it, lithification moves
	// energy by it, and its capacity is the one of the phase each of its channels stands in.
	float h_lat = 0.0;
	float cap_l = 0.0;
	for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
		if (k >= mix_n) { break; }
		SubstanceTh s = la_sub_of(mix_ch[k]);
		h_lat += la_channel_h(s, mix_ml[k], t_l, p_pa, 0.0, pinned_l, progress_l);
		cap_l += mix_ml[k] > 0.0 ? mix_ml[k] * la_phase_c(s, t_l, p_rock) : 0.0;
	}
	cap_lith[g] = cap_l * inv_vol;
	if (total_l <= 0.0) {
		e_lith_j_m3[g] = 0.0;
	}

	// THE HEAT EACH CHANNEL CARRIES, off its OWN ladder, summed into the buffer its entry names so
	// transport moves heat with matter: the free water's condensed part and its vapour apart, and an
	// entry the fluid does not hold keeps the lattice's.
	{
		float h_f[3] = float[3](0.0, 0.0, 0.0);
		float h_l[3] = float[3](0.0, 0.0, 0.0);
		float m_e[3] = float[3](0.0, 0.0, 0.0);
		float h_vap = 0.0;
		float cap_sen = 0.0;
		for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
			if (k >= mix_n) { break; }
			int i = mix_ch[k];
			int e = int(props[i * PROP_STRIDE + PROP_ENTRY]);
			SubstanceTh s = la_sub_of(i);
			float mf = mix_mf[k];
			m_e[e] += mf;
			if (e == E_H2O && mf > 0.0) {
				h_f[e] += (1.0 - f_vapour) * mf * la_mix_specific_enthalpy(s, t_c, p_pa, mf, 0.0, 0.0)
					+ (pinned ? progress * la_mix_jump_of(s, mf, t_c, p_pa, 0.0, 0.0) : 0.0);
				h_vap += f_vapour > 0.0
					? f_vapour * mf * la_mix_specific_enthalpy(s, t_c, p_pa, mf, 1.0e30, 0.0) : 0.0;
			} else {
				h_f[e] += la_channel_h(s, mf, t_c, p_pa, room_gas, pinned, progress);
			}
			h_l[e] += la_channel_h(s, mix_ml[k], t_l, p_rock, 0.0, pinned_l, progress_l);
			cap_sen += (e == E_SENSIBLE && mf > 0.0) ? mf * la_phase_c(s, t_c, p_pa) : 0.0;
		}
		h_h2o[g] = (m_e[E_H2O] > 0.0 ? h_f[E_H2O] : h_l[E_H2O]) * inv_vol;
		h_h2o_vap[g] = h_vap * inv_vol;
		h_silicate[g] = (m_e[E_SILICATE] > 0.0 ? h_f[E_SILICATE] : h_l[E_SILICATE]) * inv_vol;
		h_sensible[g] = (m_e[E_SENSIBLE] > 0.0 ? h_f[E_SENSIBLE] : h_l[E_SENSIBLE]) * inv_vol;
		cap_sensible[g] = cap_sen * inv_vol;
	}
	// Shares of the free water channel; the pore channel is the lattice's whole.
	h2o_solid[g] = f_solid;
	h2o_liquid[g] = f_liquid;
	h2o_vapour[g] = f_vapour;
	// The state its own water stands at: the IAPWS liquid curve at this temperature, squeezed here.
	float v_liq_here = la_water_liquid_v_m3_kg(t_c)
		* la_bm_squeeze(la_ph_strain(wc, PROP_LIQUID, p_pa - LA_P_STD));
	water_rho[g] = v_liq_here > 0.0 ? 1.0 / v_liq_here : 0.0;
	liquid[g] = max(h2o[g], 0.0) * f_liquid;
	// The condensed FLUID's bulk modulus: its own volume over its own compressibility, the grains out.
	float fluid_vol = b_vol - lat_vol - cv.g;
	k_cond[g] = (c_comp > 0.0 && fluid_vol > 0.0) ? fluid_vol / c_comp : 0.0;
	// THE GAS AS THE FACES READ IT: its own p / (rho T) and its isentropic exponent K_S / p off the
	// Peng-Robinson mixture in the room it stands in, vapours included. Ideal, they are R_s and cp/cv.
	float n_all = n_gas_mol + f_vapour * mol_h2o_f + f_vap_sil * mol_sil;
	float m_all = m_gas + f_vapour * m_h2o + f_vap_sil * m_sil_f;
	// A vapour that is not there adds no capacity, whether or not its row states one.
	float m_vap_w = f_vapour * m_h2o;
	float m_vap_r = f_vap_sil * m_sil_f;
	float cp_ig = cp_gas + (m_vap_w > 0.0 ? m_vap_w * w_sub.c_gas : 0.0)
		+ (m_vap_r > 0.0 ? m_vap_r * r_sub.c_gas : 0.0);
	float tk_g = t_c + LA_KELVIN_OFFSET;
	float r_s = 0.0;
	float gam = 0.0;
	if (n_all > 0.0 && room_gas > 0.0 && p_pa > 0.0) {
		vec4 pr = la_pr_sums(tk_g, ch_h2o, f_vapour * mol_h2o_f, ch_sil, f_vap_sil * mol_sil);
		float nr = n_all * LA_R_J_MOL_K;
		float vg = room_gas - pr.w;
		float dd = room_gas * room_gas + 2.0 * pr.w * room_gas - pr.w * pr.w;
		float a_mix = pr.x * pr.x;
		float da = 2.0 * pr.x * pr.y;
		float d2a = 2.0 * (pr.y * pr.y + pr.x * pr.z);
		float dp_dv = -nr * tk_g / (vg * vg) + 2.0 * a_mix * (room_gas + pr.w) / (dd * dd);
		float dp_dt = nr / vg - da / dd;
		float sq2 = sqrt(2.0);
		float lnf = pr.w > 0.0 ? log((room_gas + (1.0 - sq2) * pr.w) / (room_gas + (1.0 + sq2) * pr.w))
			/ (2.0 * sq2 * pr.w) : -1.0 / room_gas;
		float cv = cp_ig - nr - tk_g * d2a * lnf;
		float cp = cv - tk_g * dp_dt * dp_dt / dp_dv;
		r_s = m_all > 0.0 ? p_pa * room_gas / (m_all * tk_g) : 0.0;
		gam = cv > 0.0 ? -(cp / cv) * room_gas * dp_dv / p_pa : 0.0;
	}
	gas_r[g] = r_s;
	gas_gamma[g] = gam;
	float k_f = (c_comp > 0.0 && fluid_vol > 0.0) ? fluid_vol / c_comp : 0.0;
	float c_cell = (r_s > 0.0 && gam > 0.0) ? sqrt(gam * r_s * (t_c + LA_KELVIN_OFFSET))
		: ((k_f > 0.0 && rho_f > 0.0) ? sqrt(k_f / rho_f) : 0.0);
	float spd = length(v);
	mach[g] = c_cell > 0.0 ? spd / c_cell : (spd > 0.0 ? 1.0 / 0.0 : 0.0);

	// THE MELT SHARE OF THIS CELL'S ROCK, every mineral off its own ladder: the lattice's at its
	// temperature and the loose grains' at the fluid's. A phase with a melting INTERVAL reads back as a
	// linear share of it, and the latent heat is what put each temperature where it is.
	float f_melt_l = 0.0;
	float v_melt_lat = 0.0;    // volume fraction of the cell that is melt inside the lattice
	{
		float m_melt = 0.0; float m_lith = 0.0;
		float m_melt_l = 0.0; float m_lith_l = 0.0;
		for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
			if (k >= mix_n) { break; }
			int i = mix_ch[k];
			int base = i * PROP_STRIDE;
			if (props[base + PROP_LITHIC] <= 0.0 || int(props[base + PROP_ENTRY]) == E_H2O) { continue; }
			SubstanceTh r = la_sub_of(i);
			if (!r.has_melt) { continue; }
			float solidus = la_melt_c_at(r, p_pa, 0.0);
			float width = la_liquidus_over(r, solidus) - solidus;
			// A phase that melts at a POINT has no interval to read a share off: what it has melted is
			// where the latent heat the solve pinned on has got to.
			float ff = width > 0.0 ? clamp((t_c - solidus) / width, 0.0, 1.0)
				: ((pinned && t_c == solidus) ? progress : (t_c < solidus ? 0.0 : 1.0));
			float solidus_l = la_melt_c_at(r, p_rock, 0.0);
			float width_l = la_liquidus_over(r, solidus_l) - solidus_l;
			float fl = width_l > 0.0 ? clamp((t_l - solidus_l) / width_l, 0.0, 1.0)
				: ((pinned_l && t_l == solidus_l) ? progress_l : (t_l < solidus_l ? 0.0 : 1.0));
			m_melt += mix_mf[k] * ff + mix_ml[k] * fl;
			m_lith += mix_mf[k] + mix_ml[k];
			m_melt_l += mix_ml[k] * fl;
			m_lith_l += mix_ml[k];
			float molar = props[base + PROP_M];
			float full = props[base + PROP_FULL];
			v_melt_lat += (molar > 0.0 && full > 0.0 && vol > 0.0)
				? (mix_mf[k] + mix_ml[k]) / (molar * vol * full) * fl : 0.0;
		}
		f_melt = m_lith > 0.0 ? m_melt / m_lith : 0.0;
		f_melt_l = m_lith_l > 0.0 ? m_melt_l / m_lith_l : 0.0;
	}
	silicate_melt[g] = f_melt;
	// The molten share of the ROCK: the lattice's melt over the lithic volume, so a partial melt of one
	// phase does not unlock a cell whose crystals still touch.
	float melt_share = v_lithic > 0.0 ? clamp(v_melt_lat * cem / v_lithic, 0.0, 1.0) : f_melt_l;

	if (params.restate == 0u && params.lithify != 0u) {
		float cem_was = cem;
		lithify(g, melt_share, v_lithic);
		// ENERGY FOLLOWS THE CEMENT: what leaves the lattice leaves at the lattice's enthalpy, what
		// joins it joins at the loose grains'.
		float cem_now = clamp(cement[g], 0.0, 1.0);
		if (cem_now != cem_was) {
			float moved = 0.0;
			if (cem_now < cem_was && cem_was > 0.0) {
				moved = -h_lat * (cem_was - cem_now) / cem_was;
			} else if (cem_now > cem_was && cem_was < 1.0) {
				float h_loose = 0.0;
				for (int k = 0; k < LA_CHANNEL_SLOTS; ++k) {
					if (k >= mix_n) { break; }
					int i = mix_ch[k];
					if (props[i * PROP_STRIDE + PROP_LITHIC] <= 0.0) { continue; }
					h_loose += la_channel_h(la_sub_of(i), mix_mf[k], t_c, p_pa, room_gas, pinned,
						progress);
				}
				moved = h_loose * (cem_now - cem_was) / (1.0 - cem_was);
			}
			e_lith_j_m3[g] += moved * inv_vol;
			e_j_m3[g] -= moved * inv_vol;
		}
	}
	if (params.restate == 0u) {
		// The derived state, which breaks before the momentum does; a temperature of either reservoir at or
		// below absolute zero is no state.
		float dv[6] = float[6](pressure[g], k_cond[g], rho, p_fluid[g], t_c, t_l);
		for (int i = 0; i < 6; ++i) {
			nf += (isnan(dv[i]) || isinf(dv[i])) ? 1.0 : 0.0;
		}
		nf += (t_c + LA_KELVIN_OFFSET <= 0.0) ? 1.0 : 0.0;
		nf += (t_l + LA_KELVIN_OFFSET <= 0.0) ? 1.0 : 0.0;
		nonfinite[g] = nf;
		unconverged[g] = converged ? 0.0 : 1.0;
	}

	// QUASI-STATIC ROCK: the lattice carries its weight (LA_APPROX quasi_static_solid_pressure), so
	// locked matter holds no bulk momentum and a cell that unlocks starts from rest. `ke` is what a cell
	// the lithification above has just locked still carries; an already-locked one lost it above.
	if (solid[g] != 0.0) {
		e_j_m3[g] += ke;
		mom_x[g] = 0.0;
		mom_y[g] = 0.0;
		mom_z[g] = 0.0;
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		speed[g] = 0.0;
		mach[g] = 0.0;
		ke_j_m3[g] = 0.0;
		if (params.restate == 0u) {
			bodyf_x[g] = 0.0;
			bodyf_y[g] = 0.0;
			bodyf_z[g] = 0.0;
		}
		return;
	}
	if (params.restate != 0u) {
		return;
	}
	// WHAT THE CELL'S OWN PRESSURE STACK DOES NOT ALREADY CARRY, per volume: wherever the stack states
	// a pressure its six faces integrate to exactly rho*g*V, so only the frame's own terms are left.
	bool stacked = p_pa > 0.0 && length(g_eff) > 0.0;
	vec3 acc = stacked ? vec3(0.0) : g_eff;
	if (w_len > 0.0) {
		acc += -2.0 * cross(omega, v);
	}
	vec3 dp = acc * rho_f * params.dt_s;
	bodyf_x[g] = dp.x;
	bodyf_y[g] = dp.y;
	bodyf_z[g] = dp.z;
}
