#[compute]
#version 450

// Two passes over one dispatch: pass 0 writes what leaves each face into send/send_h, pass 1 gathers.
// Opposite of slot d is d ^ 1.

#include "neighbours.glsli"
#include "generated.glsli"
#include "stack.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) buffer Amount   { float amount[]; };
layout(set = 0, binding = 1, std430) restrict buffer Enthalpy { float h[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity per cell, flat cell*3, m/s^2.
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };

// Writable: a TF_VEL gather refreshes its own component from the momentum it just moved.
layout(set = 0, binding = 5, std430) restrict buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict buffer VelZ { float vel_z[]; };
// Per-face scratch, cell*6 + slot.
layout(set = 0, binding = 8, std430) restrict buffer Send   { float send[]; };
layout(set = 0, binding = 9, std430) restrict buffer SendH  { float send_h[]; };
// Charge rides the mass, exactly as enthalpy does: it is carried, never created by a move.
layout(set = 0, binding = 13, std430) buffer Charge { float charge[]; };
layout(set = 0, binding = 14, std430) restrict buffer SendQ  { float send_q[]; };
// Flow resistance 0..1 per cell.
layout(set = 0, binding = 10, std430) restrict readonly buffer Resist { float resist[]; };
// What the flux runs down; `amount` when a record has no separate potential. No `restrict`: the PGF
// rows bind the pressure buffer here, which PASS_ACOUSTIC writes through binding 16.
layout(set = 0, binding = 11, std430) readonly buffer Drive { float drive[]; };
// Whatever else the row's law reads per cell: conductivity for MODE_CONDUCT, cloud water for LAW_OHMIC.
layout(set = 0, binding = 12, std430) restrict readonly buffer Aux { float aux[]; };

layout(set = 0, binding = 15, std430) restrict readonly buffer TempBuf     { float temp[]; };
// Writable: PASS_ACOUSTIC advances it between substeps. Aliases Drive on the PGF rows.
layout(set = 0, binding = 16, std430) buffer PressureBuf { float pressure[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer PorosityBuf { float porosity[]; };
layout(set = 0, binding = 18, std430) restrict readonly buffer GrainBuf    { float grain[]; };
layout(set = 0, binding = 19, std430) readonly buffer CO2Buf      { float co2[]; };
// ONE H2O CHANNEL plus the three DERIVED shares state_derive.glsl publishes; they differ optically.
layout(set = 0, binding = 20, std430) readonly buffer H2OBuf       { float h2o[]; };
// LAAbsorptionBands.packed(): header, band edges, temperature slices, solar weights, eleven coefficients
// per (temperature, band), Planck CDF.
layout(set = 0, binding = 21, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer H2OSolidBuf  { float h2o_solid[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer H2OLiquidBuf { float h2o_liquid[]; };
layout(set = 0, binding = 24, std430) readonly buffer SilicateBuf { float silicate[]; };
layout(set = 0, binding = 25, std430) restrict readonly buffer BiomassBuf  { float biomass[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer SilicateMeltBuf { float silicate_melt[]; };
// Boundary redirect per face: a wrapped interior cell, a prescribed ghost tail cell, or -1 = shut wall.
layout(set = 0, binding = 27, std430) restrict readonly buffer Ghost { int ghost[]; };
layout(set = 0, binding = 28, std430) restrict readonly buffer H2OVapourBuf { float h2o_vapour[]; };
// TF_FRACTION rows move only this share of `amount`, 0..1. No `restrict` here or on the three below: the
// grain prologue writes the very buffers three silicate rows bind as their `frac`.
layout(set = 0, binding = 29, std430) readonly buffer FracBuf { float frac[]; };
// Consolidated share of the cell's silicate. A TF_DILUTE row rescales it when matter arrives, because what
// arrives is loose and cement is a share of a total that just grew.
layout(set = 0, binding = 30, std430) restrict buffer CementBuf { float cement[]; };
// Where the cell's loose mineral grains are, written by the PASS_GRAIN prologue.
layout(set = 0, binding = 31, std430) writeonly buffer SuspWater { float silicate_susp_water[]; };
layout(set = 0, binding = 32, std430) writeonly buffer SuspAir { float silicate_susp_air[]; };
layout(set = 0, binding = 33, std430) writeonly buffer Bed { float silicate_bed[]; };
// A detector list: the cells it found, and args slot 3 their count. No `restrict`:
// a full-grid row binds one buffer into all three slots.
layout(set = 0, binding = 34, std430) buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 35, std430) buffer ActiveArgs { uint active_args[]; };
// MODE_RADIATE's own books, J/m^3, assigned in the gather so each is a per-step rate needing no clear.
layout(set = 0, binding = 37, std430) restrict buffer RadAbs { float rad_absorbed[]; };
layout(set = 0, binding = 38, std430) restrict writeonly buffer RadEmit { float rad_emitted[]; };
// The column field and the breakdown it decides, published rather than re-derived on the CPU.
layout(set = 0, binding = 39, std430) restrict writeonly buffer ColE { float col_e[]; };
layout(set = 0, binding = 40, std430) restrict writeonly buffer Strike { float strike[]; };
// Rock channels two and three, the TF_RADIOGENIC deposit (J/m^3), and the RADIATE march's scratch.
layout(set = 0, binding = 41, std430) restrict readonly buffer RadW { float rad_w_m3[]; };  // W/m^3, from state_derive.glsl
// The greenhouse trace gases the band table resolves, mol/m^3.
layout(set = 0, binding = 42, std430) readonly buffer Ch4Buf { float ch4[]; };
layout(set = 0, binding = 43, std430) restrict writeonly buffer Radiogenic { float radiogenic[]; };
layout(set = 0, binding = 44, std430) restrict buffer LwEmis { float lw_emis[]; };
layout(set = 0, binding = 45, std430) restrict buffer SwAbs { float sw_absorbed[]; };
// Heat of the entry this row's substance sits in, and that entry's capacity, J/m^3 and J/m^3/K.
// Writable: a gather moves them with the matter, so the next row divides by the cell as it now is.
layout(set = 0, binding = 46, std430) restrict buffer HCarried { float h_carried[]; };
layout(set = 0, binding = 47, std430) restrict buffer CapSensible { float cap_sensible[]; };
// What crossed an OPEN box edge this step, per interior cell: amount in, joules riding along.
layout(set = 0, binding = 48, std430) restrict buffer BndAmt { float bnd_amt[]; };
layout(set = 0, binding = 49, std430) restrict buffer BndH { float bnd_h[]; };
// The REPLAY relaxation rim: the driving ghost cell and the per-step nudge fraction; 0 = outside the rim.
layout(set = 0, binding = 50, std430) restrict readonly buffer RimGhost { int rim_ghost[]; };
layout(set = 0, binding = 51, std430) restrict readonly buffer RimW { float rim_w[]; };
// The reflected-shortwave field: the share of upwelling flux a cell keeps as heat, each cell's reflected
// source W/m^2, what escapes to space J/m^3 per step, and the Stefan-Boltzmann residual of rad_emitted.
layout(set = 0, binding = 52, std430) restrict buffer SwKeep { float sw_keep[]; };
layout(set = 0, binding = 53, std430) restrict buffer SwSrc { float sw_src[]; };
layout(set = 0, binding = 54, std430) restrict writeonly buffer SwSpace { float sw_space[]; };
layout(set = 0, binding = 55, std430) restrict writeonly buffer RadResid { float rad_residual[]; };
// O3 partial density, kg/m^3. Zeros until a photochemical o3 channel exists to swap in: at 4.5 Ga,
// with free O2 at zero, there is no ozone layer.
layout(set = 0, binding = 56, std430) restrict readonly buffer O3Buf { float o3[]; };
// Mass density per cell, kg/m^3. Writable: each mass row's gather moves its substance's mass out of
// it, or momentum strands in a cell that empties.
layout(set = 0, binding = 57, std430) restrict buffer RhoBulk { float rho_bulk[]; };
// MASS MOVES WITH ITS MOMENTUM, exactly as with its heat: bulk momentum advection emerges from the
// mass fluxes. No `restrict`: a momentum row's own channel is one of these three buffers.
layout(set = 0, binding = 58, std430) buffer MomX { float mom_x[]; };
layout(set = 0, binding = 59, std430) buffer MomY { float mom_y[]; };
layout(set = 0, binding = 60, std430) buffer MomZ { float mom_z[]; };
layout(set = 0, binding = 61, std430) restrict buffer SendMX { float send_mx[]; };
layout(set = 0, binding = 62, std430) restrict buffer SendMY { float send_my[]; };
layout(set = 0, binding = 63, std430) restrict buffer SendMZ { float send_mz[]; };
// The mixture's own sound speed, m/s, off state_derive's EOS compressibility sum.
layout(set = 0, binding = 64, std430) restrict buffer CelerityBuf { float cel_m_s[]; };
layout(set = 0, binding = 89, std430) restrict readonly buffer KCondBuf { float k_cond[]; };
// |v| refreshed by the last momentum gather, so the drained CFL peak is next step's read.
layout(set = 0, binding = 65, std430) restrict buffer SpeedBuf { float speed[]; };
// The step's body impulse per cell, kg/(m^2 s), booked by state_derive; PASS_ACOUSTIC_APPLY deposits
// it a substep's share at a time, beside the pressure gradient it stands against.
layout(set = 0, binding = 66, std430) restrict readonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = 67, std430) restrict readonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = 68, std430) restrict readonly buffer BodyFZ { float bodyf_z[]; };
// The momentum riding a mass row's exterior crossing, booked beside the mass leg. No `restrict`: a
// signed row binds the void book here, and its own book through binding 48.
layout(set = 0, binding = 69, std430) buffer BndMomX { float bnd_mom_x[]; };
layout(set = 0, binding = 70, std430) buffer BndMomY { float bnd_mom_y[]; };
layout(set = 0, binding = 71, std430) buffer BndMomZ { float bnd_mom_z[]; };
layout(set = 0, binding = 72, std430) readonly buffer CoBuf { float co_gas[]; };
layout(set = 0, binding = 73, std430) readonly buffer So2Buf { float so2[]; };
layout(set = 0, binding = 74, std430) readonly buffer H2sBuf { float h2s[]; };
layout(set = 0, binding = 75, std430) readonly buffer O2Buf { float o2_gas[]; };
layout(set = 0, binding = 76, std430) readonly buffer N2Buf { float n2_gas[]; };
layout(set = 0, binding = 77, std430) readonly buffer H2Buf { float h2_gas[]; };
layout(set = 0, binding = 78, std430) restrict readonly buffer GravPhi { float grav_phi[]; };  // J/kg, zero at infinity
// The charge riding a mass row's exterior crossing, C/m^3 per step.
layout(set = 0, binding = 79, std430) buffer BndQ { float bnd_q[]; };
// TEMPORAL LEVELS. A cell's own stable timestep is dt/2^tlevel; the ghost tail is level 0. `level_idx`
// holds every cell sorted by level, and `level_args` per level: indirect groups, the histogram count,
// the sorted offset, the scatter cursor and the suffix count of cells at that level or finer.
layout(set = 0, binding = 80, std430) buffer TLevel { uint tlevel[]; };
layout(set = 0, binding = 81, std430) buffer LevelIdx { uint level_idx[]; };
layout(set = 0, binding = 82, std430) buffer LevelArgs { uint level_args[]; };
// Per row group: the coarsest level its state can afford, atomically reduced.
layout(set = 0, binding = 83, std430) buffer LevelPeak { uint level_peak[]; };
// ACTIVITY: substeps since matter last crossed a cell, one counter per row group.
layout(set = 0, binding = 84, std430) buffer Quiet { uint quiet[]; };
// The compaction's dedup claim and its unsorted queue, one entry per cell.
layout(set = 0, binding = 85, std430) buffer ActClaim { uint act_claim[]; };
layout(set = 0, binding = 86, std430) buffer ActQueue { uint act_q[]; };
// Cells another kernel changed, slot 3 of the args carrying their count.
layout(set = 0, binding = 87, std430) buffer WakeQueue { uint wake_q[]; };
layout(set = 0, binding = 88, std430) buffer WakeArgs { uint wake_args[]; };

#include "march.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // TransportPass.PASS_* — 0 = outflow, 1 = gather, 2 = the grain prologue
	uint mode;            // MODE_* — what drives the flux across a face
	uint law;             // LAW_* — which transport law sets the mobility
	uint band_count;
	uint flags;           // TF_SIGNED | TF_SETTLE | TF_EFIELD
	float cell_m;         // cell edge, metres. One number: the grid is uniform.
	float dt_s;
	float repose_tan;     // 0 = a fluid, which levels freely
	float rho_floor;      // kg/m^3 below which a cell is empty: it neither donates nor holds velocity
	float density;        // kg/m^3 of the substance this record carries
	float max_fill;       // mol/m^3 at which a cell is full of it; +inf for a row carrying no matter
	float fluid_rho;      // kg/m^3 of the fluid the row moves THROUGH
	float fluid_visc;     // Pa s of that fluid
	float grain_d;        // m, the row's own grain diameter where the cell declares none
	float sun_x;          // world-space vector toward the sun; its LENGTH carries relative insolation
	float sun_y;
	float sun_z;
	// PASS_GRAIN weighs a grain against BOTH fluids in one dispatch, so it cannot use fluid_rho/fluid_visc.
	float rho_water;      // LAPhysical.WATER_DENSITY_KG_M3
	float mu_water;       // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
	float rho_air;        // LAPhysical.AIR_DENSITY_KG_M3
	float mu_air;         // LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S
	// J/m^3/K a unit of fill adds to the sensible entry; 0 for a substance on its own phase ladder.
	float sub_cap_j_m3k;
	uint total_count;     // interior cells plus ghost tail cells; pass 0 runs the ghosts too
	uint axis;            // which momentum component a signed PGF row carries: 0=x 1=y 2=z
	float xuv_w_m2;       // XUV irradiance AT THIS BODY, W/m^2 — LAW_ESCAPE's driver
	uint level;           // the coarsest temporal level advancing on this substep; PEAK: the group slot
	uint substep_k;       // this substep's index on the finest level's axis
	uint substep_n;       // substeps the finest level takes across the field step, 2^levels
	uint act_group;       // the row group whose activity counter and cell list this dispatch walks
	uint act_group2;      // a second group this row's crossings wake; ACT_NO_GROUP for none
} params;

// The seconds THIS invocation integrates. A cell's own is dt/2^tlevel; a face's is the coarser of the
// pair's, so both sides of it write the same flux on the same substep and the books close across levels.
float la_dt;

// LEVEL_SLOTS: TransportPass.Arg.SLOTS. GROUPS_X 0, COUNT 3, OFFSET 4, CURSOR 5, SUFFIX 6.
const uint LEVEL_SLOTS = 8u;
// The bin past the levels holds the compaction queue's own length.
const uint ACT_QUEUE_BIN = ACT_BINS;
const uint ACT_NO_GROUP = ~0u;

// Where this dispatch's group starts in the per-cell activity counter and in the per-level args.
uint act_base() { return params.act_group * params.total_count; }
uint args_base() { return params.act_group * (ACT_QUEUE_BIN + 1u) * LEVEL_SLOTS; }

// Matter crossed this cell recently enough that it may still donate.
bool awake(uint c) { return quiet[act_base() + c] < ACT_QUIET_SUBSTEPS; }

float la_level_dt(uint lv) {
	return params.dt_s * exp2(-float(lv));
}

// TransportPass's PASS_* tags past outflow (0) and gather (1).
const uint PASS_GRAIN = 2u;
const uint PASS_LIST_RESET = 3u;
const uint PASS_LIST_APPEND = 4u;
const uint PASS_LIST_ARGS = 5u;
const uint PASS_SW = 6u;
const uint PASS_ACOUSTIC = 7u;
const uint PASS_ACOUSTIC_APPLY = 8u;
// The temporal-level machinery: seed a cell's level off its own state, relax it 2:1 against its
// neighbours, then counting-sort every cell by level so a substep dispatches over a suffix.
const uint PASS_LEVEL_SEED = 9u;
const uint PASS_LEVEL_RELAX = 10u;
const uint PASS_LEVEL_RESET = 11u;
const uint PASS_LEVEL_SCAN = 12u;
const uint PASS_LEVEL_SORT = 13u;
const uint PASS_LEVEL_PEAK = 14u;
// THE ACTIVE LIST: age every listed cell, take in what another kernel woke, then compact the awake
// cells and their receivers into the list the rows dispatch over.
const uint PASS_ACT_AGE = 15u;
const uint PASS_ACT_WAKE = 16u;
const uint PASS_ACT_MARK = 17u;
const uint PASS_ACT_WAKE_RESET = 18u;
const uint PASS_ACT_SEED = 19u;

const float KELVIN = 273.15;                        // LAPhysical.KELVIN_OFFSET
const float STEFAN = 5.670374419e-8;                // LAPhysical.STEFAN_BOLTZMANN
const float KOZENY_CARMAN_C = 180.0;                // LAPhysical.KOZENY_CARMAN_C
const float SMAGORINSKY_COEFF = 0.1650789493;             // LAPhysical.SMAGORINSKY_COEFF
const float DRY_AIR_R = 287.0222603;                // LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK
const float AIR_GAMMA = 1.399764846;                // LAPhysical.AIR_ADIABATIC_INDEX
const float AIR_DENSITY = 1.225;                    // LAPhysical.AIR_DENSITY_KG_M3
const float EPS0 = 8.8541878128e-12;                // LAPhysical.VACUUM_PERMITTIVITY_F_M
const float RREA_THRESHOLD = 2.84e5;                // LAPhysical.RREA_THRESHOLD_V_M
const float CLOUD_COND = 1.0e-14;                   // LAPhysical.CLOUD_CONDUCTIVITY_S_M
const float CLEAR_AIR_COND = 1.0e-13;               // LAPhysical.CLEAR_AIR_CONDUCTIVITY_S_M
const float CHANNEL_COND = 1.0e4;                   // LAPhysical.LIGHTNING_CHANNEL_CONDUCTIVITY_S_M
const float CHARGING_LWC = 1.0e-3;                  // LAPhysical.CHARGING_LWC_KG_M3
const float NIC_CHARGE_RATE = 1.0e-9;               // LAPhysical.NIC_CHARGE_RATE_C_M3_S
const float CHARGE_ZONE_WARM_C = -10.0;             // LAPhysical.CHARGE_ZONE_WARM_C
const float CHARGE_ZONE_COLD_C = -25.0;             // LAPhysical.CHARGE_ZONE_COLD_C
const float CONVECTIVE_UPDRAFT = 10.0;              // LAPhysical.CONVECTIVE_UPDRAFT_M_S
const float BASALT_SOLIDUS_C = 1000.0;              // LAPhysical.BASALT_SOLIDUS_C
const float BASALT_LIQUIDUS_C = 1200.0;             // LAPhysical.BASALT_LIQUIDUS_C
const float MELT_VISC = 100.0;                      // LAPhysical.BASALT_MELT_VISCOSITY_PA_S
const float ROSCOE_N = 2.5;                         // LAPhysical.EINSTEIN_ROSCOE_EXPONENT
const float LOCKUP_CRYSTAL_FRAC = 0.6;              // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float DIFFUSIVITY = 1.66;                     // LAPhysical.TWO_STREAM_DIFFUSIVITY
const float C2_CM_K = 1.4387768775;                 // LAPhysical.PLANCK_C2_CM_K
const float KAPPA_REF_PA = 1.0e4;                   // LAPhysical.ABSORPTION_REF_PRESSURE_PA
const float R_CO2 = 188.924269;                     // LAPhysical.CO2_GAS_CONST_J_KGK
const float RHO_WATER = 997.0;                      // LAPhysical.WATER_DENSITY_KG_M3
const float R_VAPOUR = 461.52;                      // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float M_H2O = 0.018015;                       // LASubstances.h2o.molar_mass
const float M_O2 = 0.0319988;                       // LASubstances.o2.molar_mass
const float M_N2 = 0.0280134;                       // LASubstances.n2.molar_mass
const float M_H2 = 0.00201588;                      // LASubstances.h2.molar_mass
const float M_CO2 = 0.0440095;                      // LASubstances.co2.molar_mass
const float M_CH4 = 0.01604276;                     // LASubstances.ch4.molar_mass
const float M_CO = 0.0280104;                       // LASubstances.co.molar_mass
const float M_SO2 = 0.0640588;                      // LASubstances.so2.molar_mass
const float M_H2S = 0.03407588;                     // LASubstances.h2s.molar_mass
const float RHO_SILICATE = 2900.0;                  // LASubstances.silicate.density
const float M_SILICATE = 0.1161612;                 // LASubstances.silicate.molar_mass
const float RHO_CELLULOSE = 500.0;                  // LASubstances.cellulose.density
const float M_CELLULOSE = 0.030026;                 // LASubstances.cellulose.molar_mass
// mol/m^3 at which a cell is FULL of a substance; amount/full is its volume fraction of the cell.
const float FULL_H2O = RHO_WATER / M_H2O;
const float FULL_SILICATE = RHO_SILICATE / M_SILICATE;
const float FULL_CELLULOSE = RHO_CELLULOSE / M_CELLULOSE;
const float ALBEDO_GROUND = 0.15;                   // LAPhysical.ALBEDO_BARE_GROUND
const float ALBEDO_WATER = 0.06;                    // LAPhysical.ALBEDO_OCEAN
const float ALBEDO_ICE = 0.65;                      // LAPhysical.ALBEDO_SNOW_ICE
const float ALBEDO_VEG = 0.12;                      // LAPhysical.ALBEDO_VEGETATION
const float EMIS_WATER = 0.96;                      // LAPhysical.EMISSIVITY_WATER
const float EMIS_SNOW = 0.99;                       // LAPhysical.EMISSIVITY_SNOW
const float EMIS_ROCK = 0.95;                       // LAPhysical.BASALT_EMISSIVITY
const float R_GAS = 8.314462618;                    // LAPhysical.GAS_CONSTANT_J_MOL_K
const float LAMBDA_HYDRO = 3.0;                     // LAPhysical.ESCAPE_PARAM_HYDRODYNAMIC
const float XUV_EFF = 0.15;                         // LAPhysical.XUV_HEATING_EFFICIENCY
const float SQRT_PI = sqrt(radians(180.0));
const int GHOST_SPACE = -2;                         // LAFieldBoundary3D.SPACE_REDIRECT
const float C_LIGHT = 299792458.0;                  // LAPhysical.SPEED_OF_LIGHT_M_S


vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

vec3 vel_at(uint c) {
	return vec3(vel_x[c], vel_y[c], vel_z[c]);
}

// The cell's own grain diameter, or the row's seed where the cell declares none, m.
float grain_d_at(uint c) {
	return grain[c] > 0.0 ? grain[c] : params.grain_d;
}

// Outward unit normal of face d. Slot order -X,+X,-Y,+Y,-Z,+Z.
vec3 face_normal(uint d) {
	float s = (d & 1u) == 1u ? 1.0 : -1.0;
	uint axis = d >> 1u;
	return vec3(axis == 0u ? s : 0.0, axis == 1u ? s : 0.0, axis == 2u ? s : 0.0);
}

float t_k(uint c) {
	return max(temp[c] + KELVIN, 1.0);
}

// Ideal-gas air density from the cell's own pressure and temperature, kg/m^3.
float air_rho(uint c) {
	return max(pressure[c], 0.0) / (DRY_AIR_R * t_k(c));
}

// kg one mole of this row's substance weighs: pure density over the full amount. 0 for a row that
// carries no matter, whose max_fill is +inf.
float sub_kg_mol() {
	return params.max_fill > 0.0 ? params.density / params.max_fill : 0.0;
}

// THE ONE EMPTINESS TEST, the floor state_derive.glsl empties a cell on: no bulk state of any kind.
bool no_matter(uint c) {
	return !(rho_bulk[c] >= params.rho_floor);
}

// The cell's h2o split by the shares the enthalpy ladder derived, mol/m^3.
float h2o_ice(uint c)    { return max(h2o[c], 0.0) * clamp(h2o_solid[c], 0.0, 1.0); }
float h2o_water(uint c)  { return max(h2o[c], 0.0) * clamp(h2o_liquid[c], 0.0, 1.0); }
float h2o_gas(uint c)    { return max(h2o[c], 0.0) * clamp(h2o_vapour[c], 0.0, 1.0); }

// CONDENSED cloud water, droplets and ice alike, kg/m^3: what a rebounding pair is made of and what the
// air's conductivity tracks.
float cloud_water_kg_m3(uint c) {
	return (h2o_water(c) + h2o_ice(c)) * M_H2O;
}

// Non-inductive charge separation in the riming band, C/m^3 this step: the pair creates nothing.
float separation_dq(uint c, vec3 up) {
	float band = clamp((CHARGE_ZONE_WARM_C - temp[c]) / (CHARGE_ZONE_WARM_C - CHARGE_ZONE_COLD_C),
		0.0, 1.0);
	float wet = clamp(cloud_water_kg_m3(c) / CHARGING_LWC, 0.0, 1.0);
	float lift = clamp(dot(vel_at(c), up) / CONVECTIVE_UPDRAFT, 0.0, 1.0);
	return NIC_CHARGE_RATE * band * wet * lift * la_dt;
}

// Volume fraction of the cell that is condensed, so a beam meets it geometrically.
float condensed_frac(uint c) {
	float f = solid[c] != 0.0 ? 1.0 : 0.0;
	f += max(silicate[c], 0.0) / FULL_SILICATE + (h2o_water(c) + h2o_ice(c)) / FULL_H2O;
	return clamp(f, 0.0, 1.0);
}

// Mass of the cell's condensed phases per unit CELL volume, kg/m^3: what lies at the bottom of it.
float cond_kg_m3(uint c) {
	return cloud_water_kg_m3(c) + max(silicate[c], 0.0) * M_SILICATE;
}

// Depth of face d below the cell's top, m: where the face cuts the stack.
float face_z(uint c, uint d) {
	vec3 gv = g_at(c);
	float gm = length(gv);
	return gm > 0.0 ? 0.5 * params.cell_m * (1.0 + dot(face_normal(d), gv) / gm)
		: 0.5 * params.cell_m;
}

// The cell's pressure at face d, off the LAYERS it holds, so an equilibrium column presents ONE pressure
// to a shared face however the interface cuts the cell.
float face_p(uint c, uint d) {
	vec3 gv = g_at(c);
	if (length(gv) <= 0.0) {
		return pressure[c];
	}
	return la_stack_p(face_z(c, d), params.cell_m, length(gv), condensed_frac(c), cond_kg_m3(c),
		max(rho_bulk[c], 0.0), max(pressure[c], 0.0));
}

// The layer this cell presents at face d. The gas takes the cell's own p and the density that p and its
// temperature state, never a bulk sum less a bulk sum.
vec2 face_layer(uint c, uint d) {
	return la_stack_layer(face_z(c, d), params.cell_m, condensed_frac(c), cond_kg_m3(c),
		air_rho(c), max(pressure[c], 0.0), max(k_cond[c], 0.0), AIR_GAMMA);
}

// Signal speed of the layer at face d, m/s: sqrt(K/rho) of what touches it, never a mixture mean.
float face_c(uint c, uint d) {
	vec2 lay = face_layer(c, d);
	return (lay.x > 0.0 && lay.y > 0.0) ? sqrt(lay.y / lay.x) : 0.0;
}

// Impedance rho*c of the layer at face d, kg/(m^2 s). LA_APPROX: acoustic_face_pressure
float impedance(uint c, uint d) {
	vec2 lay = face_layer(c, d);
	return (lay.x > 0.0 && lay.y > 0.0) ? sqrt(lay.x * lay.y) : 0.0;
}

// The CELL's bulk modulus, Pa (Wood 1930): compliances add by volume fraction. Its response to a
// uniform dp, and nothing else: no face and no clock takes a signal speed out of it.
float bulk_mod(uint c) {
	float fc = clamp(condensed_frac(c), 0.0, 1.0);
	float kc = max(k_cond[c], 0.0);
	float kg = AIR_GAMMA * max(pressure[c], 0.0);
	float comp = (kc > 0.0 ? fc / kc : 0.0) + (kg > 0.0 ? (1.0 - fc) / kg : 0.0);
	return comp > 0.0 ? 1.0 / comp : 0.0;
}


// Magnitude of the resolved strain-rate tensor, 1/s: |S| = sqrt(2 S_ij S_ij).
float strain_rate(uint c) {
	uint base = c * N_SLOTS;
	mat3 grad = mat3(0.0);
	for (uint a = 0u; a < 3u; ++a) {
		uint slot = a * 2u;
		int lo = nbr[base + slot];
		int hi = nbr[base + opposite_slot(slot)];
		if (lo < 0) { lo = ghost[base + slot]; }
		if (hi < 0) { hi = ghost[base + opposite_slot(slot)]; }
		vec3 vlo = lo >= 0 ? vel_at(uint(lo)) : vel_at(c);
		vec3 vhi = hi >= 0 ? vel_at(uint(hi)) : vel_at(c);
		vec3 d = (vhi - vlo) / (2.0 * params.cell_m);
		grad[0][a] = d.x;
		grad[1][a] = d.y;
		grad[2][a] = d.z;
	}
	float s2 = 0.0;
	for (uint i = 0u; i < 3u; ++i) {
		for (uint j = 0u; j < 3u; ++j) {
			float sij = 0.5 * (grad[i][j] + grad[j][i]);
			s2 += 2.0 * sij * sij;
		}
	}
	return sqrt(s2);
}

// Smagorinsky eddy viscosity, m^2/s: nu_t = (C_s dx)^2 |S| plus that fluid's molecular floor.
float eddy_viscosity_of(uint c, float rho, float mu) {
	float mixing = SMAGORINSKY_COEFF * params.cell_m;
	float nu_mol = rho > 0.0 ? mu / rho : 0.0;
	return nu_mol + mixing * mixing * strain_rate(c);
}

float eddy_viscosity(uint c) {
	return eddy_viscosity_of(c, params.fluid_rho, params.fluid_visc);
}

// Einstein-Roscoe: the melt's own viscosity times the crystal framework it is carrying, Pa s. The crystal
// fraction is what the enthalpy ladder derived, not a second reading of the temperature.
float melt_viscosity(uint c) {
	float crystal = 1.0 - clamp(silicate_melt[c], 0.0, 1.0);
	float r = clamp(crystal / LOCKUP_CRYSTAL_FRAC, 0.0, 0.9999);
	return MELT_VISC * pow(1.0 - r, -ROSCOE_N);
}

// Gauss's law along the field line: charge integrated outward is a surface charge, so a field. V/m.
float column_field(uint c) {
	vec3 gv = g_at(c);
	if (length(gv) <= 0.0) {
		return 0.0;
	}
	vec3 up = -normalize(gv);
	float sigma = 0.0;
	uint at = c;
	for (uint i = 0u; i < 64u; ++i) {
		if (solid[at] != 0.0) {
			break;
		}
		sigma += charge[at] * la_step_len(up, params.cell_m);
		int nx = la_step(at, up);
		if (nx < 0) {
			break;
		}
		at = uint(nx);
	}
	return abs(sigma) / EPS0;
}

// Relativistic runaway breakdown field at this cell, V/m: the threshold falls with air density, so it is
// reachable aloft where 3 MV/m conventional breakdown never is. 0 where there is no air to break down.
float rrea_threshold(uint c) {
	if (pressure[c] <= 0.0) {
		return 0.0;
	}
	return RREA_THRESHOLD * air_rho(c) / AIR_DENSITY;
}

// Past the runaway threshold the local air density sets, the dielectric stops being one: the conductivity
// jumps to a return-stroke channel's and the charge row becomes a stroke. `e` is this cell's column field.
float ohmic_conductivity_at(uint c, float e) {
	float ambient = mix(CLEAR_AIR_COND, CLOUD_COND,
		clamp(cloud_water_kg_m3(c) / CHARGING_LWC, 0.0, 1.0));
	float threshold = rrea_threshold(c);
	return (threshold > 0.0 && e >= threshold) ? CHANNEL_COND : ambient;
}

// The fraction of the driving imbalance that crosses a face in one step. Every branch is a transport law
// evaluated on this cell's own state; nothing here is a chosen rate.
float mobility_at(uint c, float amt) {
	float L = params.cell_m;
	float dt = la_dt;
	float g = length(g_at(c));
	// The matter's depth: its volume fraction of the cell (amount over the row's full amount) times the
	// cell edge, metres.
	float depth_m = params.max_fill > 0.0 ? (amt / params.max_fill) * L : 0.0;
	if (params.law == LAW_SHALLOW) {
		// Inviscid gravity adjustment: du/dt = -g dh/dx, so the head moves at g h dt^2 / L^2. Granular
		// piles take the same law with the repose slope already subtracted (Savage & Hutter 1989).
		return g * depth_m * dt * dt / (L * L);
	}
	if (params.law == LAW_FILM) {
		// Nusselt falling film: K = rho g h^2 / (3 mu), and mu climbs as the melt crystallises. The
		// laminar form holds only while drag beats inertia; past that the flow is its own gravity wave.
		float hh = depth_m;
		float mu = max(melt_viscosity(c), 1.0e-12);
		float film = params.density * g * hh * hh * dt / (3.0 * mu * L);
		float wave = g * hh * dt * dt / (L * L);
		return min(film, wave);
	}
	if (params.law == LAW_DARCY) {
		return 0.0;   // a bond property, not a cell property — see darcy_mobility
	}
	if (params.law == LAW_EDDY) {
		return eddy_viscosity(c) * dt / (L * L);
	}
	if (params.law == LAW_SOUND) {
		return sqrt(AIR_GAMMA * DRY_AIR_R * t_k(c)) * dt / L;
	}
	if (params.law == LAW_OHMIC) {
		// Ohmic relaxation of a space charge: d(rho)/dt = -(sigma/eps0) rho.
		return ohmic_conductivity_at(c, column_field(c)) * dt / EPS0;
	}
	return 0.0;
}

// Hydraulic resistance of half a cell to pore flow, the reciprocal of its Kozeny-Carman permeability.
// An OPEN cell has no matrix and resists nothing; rock with no pore space is impermeable.
float darcy_resistance(uint c) {
	if (solid[c] == 0.0) {
		return 0.0;
	}
	float phi = clamp(porosity[c], 0.0, 0.999);
	if (phi <= 0.0) {
		return 1.0e30;
	}
	float d = grain_d_at(c);
	float k = d * d * phi * phi * phi / (KOZENY_CARMAN_C * max((1.0 - phi) * (1.0 - phi), 1.0e-12));
	return 1.0 / max(k, 1.0e-30);
}

// Two half-cells in series across the bond: K = rho g k_bond / mu. Two open cells resist nothing.
float darcy_mobility(uint a, uint b) {
	float r = 0.5 * (darcy_resistance(a) + darcy_resistance(b));
	if (r <= 0.0) {
		return 0.0;
	}
	return params.fluid_rho * length(g_at(a)) * la_dt
		/ (r * max(params.fluid_visc, 1.0e-30) * params.cell_m);
}

// Terminal settling velocity of a grain of diameter `d` in a fluid, m/s (Stokes drag: the buoyant weight
// balanced by 3 pi mu d w).
float stokes_settling(uint c, float d, float rho, float mu) {
	return max(params.density - rho, 0.0) * length(g_at(c)) * d * d / (18.0 * max(mu, 1.0e-30));
}

float settling_speed(uint c) {
	if ((params.flags & TF_SETTLE) == 0u) {
		return 0.0;
	}
	return stokes_settling(c, grain_d_at(c), params.fluid_rho, params.fluid_visc);
}

// Share of grains a fluid holds up. u* = sqrt(nu_t |S|) is the friction velocity, which in a boundary
// layer is the scale of the vertical turbulent fluctuations (Bagnold: suspension once u* > w_s).
float suspended_share(uint c, float rho, float mu) {
	float w_s = stokes_settling(c, grain_d_at(c), rho, mu);
	if (w_s <= 0.0) {
		return 1.0;      // no denser than its fluid, so nothing pulls it out
	}
	return clamp(sqrt(max(eddy_viscosity_of(c, rho, mu) * strain_rate(c), 0.0)) / w_s, 0.0, 1.0);
}

// The velocity the row's matter actually travels at: the fluid's, plus its own fall through it.
vec3 transport_velocity(uint c) {
	vec3 v = vel_at(c);
	vec3 gv = g_at(c);
	if ((params.flags & TF_SETTLE) != 0u && length(gv) > 0.0) {
		v += normalize(gv) * settling_speed(c);
	}
	return v;
}


float wind_term(float n, float m, float m_max) {
	return m < m_max ? max(n, 0.0) * m : 0.0;   // kg/m^3 the wind lifts; a bound species adds none
}

// LAW_ESCAPE: the box edge is space. Bound gas: Jeans tail effusion (Jeans 1925; Chamberlain & Hunten
// 1987), tail excess out via `tail_j_mol`; unbound: the XUV energy-limited wind (Watson et al. 1981;
// Erkaev et al. 2007). LA_APPROX: top_cell_exobase
float escape_fraction(uint c, uint d, out float tail_j_mol) {
	tail_j_mol = 0.0;
	vec3 gv = g_at(c);
	float gmag = length(gv);
	float depth = -grav_phi[c];
	float kg_mol = sub_kg_mol();
	if (gmag <= 0.0 || depth <= 0.0 || kg_mol <= 0.0) {
		return 0.0;
	}
	vec3 up = -gv / gmag;
	float cosf = dot(up, face_normal(d));
	if (cosf <= 0.0) {
		return 0.0;
	}
	float tk = t_k(c);
	float lam = kg_mol * depth / (R_GAS * tk);
	float v_eff = 0.0;
	if (lam >= LAMBDA_HYDRO) {
		v_eff = sqrt(2.0 * R_GAS * tk / kg_mol) / (2.0 * SQRT_PI) * (1.0 + lam) * exp(-lam);
		tail_j_mol = R_GAS * tk * ((lam * lam + 2.0 * lam + 2.0) / (lam + 1.0) - 1.5);
	} else {
		vec3 sun = vec3(params.sun_x, params.sun_y, params.sun_z);
		float sl = length(sun);
		if (sl <= 0.0) {
			return 0.0;
		}
		float mu = dot(up, sun / sl);
		if (mu <= 0.0) {
			return 0.0;
		}
		float m_max = LAMBDA_HYDRO * R_GAS * tk / depth;
		float rho_wind = wind_term(h2o_gas(c), M_H2O, m_max) + wind_term(co2[c], M_CO2, m_max)
			+ wind_term(ch4[c], M_CH4, m_max) + wind_term(co_gas[c], M_CO, m_max)
			+ wind_term(so2[c], M_SO2, m_max) + wind_term(h2s[c], M_H2S, m_max)
			+ wind_term(o2_gas[c], M_O2, m_max) + wind_term(n2_gas[c], M_N2, m_max)
			+ wind_term(h2_gas[c], M_H2, m_max);
		if (rho_wind <= 0.0) {
			return 0.0;
		}
		v_eff = XUV_EFF * params.xuv_w_m2 * mu / (depth * rho_wind);
	}
	return min(v_eff * la_dt / params.cell_m, 1.0) * cosf;
}

#include "transport_radiate.glsli"

// Piezometric head at face d: drive head, plus elevation and p/(rho g) for a hydraulic POTENTIAL row.
float potential(uint c, uint d) {
	vec3 gv = g_at(c);
	float gmag = length(gv);
	bool hydraulic = params.mode == MODE_POTENTIAL
		&& (params.law == LAW_SHALLOW || params.law == LAW_FILM || params.law == LAW_DARCY);
	if (!hydraulic || (params.flags & TF_DRIVEN) != 0u || gmag <= 0.0) {
		return drive[c] * params.cell_m;
	}
	float z = 0.5 * params.cell_m * dot(gv / gmag, face_normal(d));
	float p_head = params.density > 0.0 ? max(pressure[c], 0.0) / (params.density * gmag) : 0.0;
	return drive[c] * params.cell_m + (z + p_head) * params.max_fill;
}

// PASS_GRAIN: a cell's loose grains — in water, in air, or on the bed. Shares sum to
// (1 - melt) * (1 - cement); runs before any row's pass 0, and reads neighbour velocity.
void grain_state(uint g) {
	float loose = (1.0 - clamp(silicate_melt[g], 0.0, 1.0)) * (1.0 - clamp(cement[g], 0.0, 1.0));
	if (loose <= 0.0) {
		silicate_susp_water[g] = 0.0;
		silicate_susp_air[g] = 0.0;
		silicate_bed[g] = 0.0;
		return;
	}
	float water = h2o_water(g) / FULL_H2O;
	float air = 1.0 - condensed_frac(g);
	float tot = water + air;
	float f_water = tot > 0.0 ? water / tot : 0.0;
	float f_air = tot > 0.0 ? air / tot : 0.0;

	float in_water = f_water * suspended_share(g, params.rho_water, params.mu_water);
	float in_air = f_air * suspended_share(g, params.rho_air, params.mu_air);

	silicate_susp_water[g] = loose * in_water;
	silicate_susp_air[g] = loose * in_air;
	silicate_bed[g] = loose * clamp(1.0 - in_water - in_air, 0.0, 1.0);
}


// Substeps this row's stability asks of THIS cell, off the cell's own state: per-face share <= 1/6,
// donor courant v dt <= L, acoustic c dt sqrt(3)/L <= 1, gravity adjustment g h (dt/n)^2/L^2 <= 1/6.
float la_row_need(uint c) {
	float L = params.cell_m;
	float dt = params.dt_s;
	float tk = t_k(c);
	float need = 0.0;
	// Rock holds no bulk momentum; each face carries its own layer, and the fastest is what is resolved.
	if ((params.flags & TF_VEL) != 0u && solid[c] == 0.0) {
		float w = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			w = max(w, abs(dot(vel_at(c), face_normal(d))) + face_c(c, d));
		}
		need = w * dt / L;
	}
	if (params.mode == MODE_ADVECT || params.mode == MODE_BOTH) {
		float v = max(speed[c], 0.0);
		if ((params.flags & TF_SETTLE) != 0u) {
			v += max(params.density - params.fluid_rho, 0.0) * length(g_at(c))
				* params.grain_d * params.grain_d / (18.0 * max(params.fluid_visc, 1.0e-30));
		}
		need += v * dt / L;
	}
	if (params.law == LAW_SHALLOW || params.law == LAW_FILM) {
		need = max(need, sqrt(6.0 * length(g_at(c)) * L) * dt / L);
	}
	if (params.law == LAW_EDDY && (params.flags & TF_VEL) == 0u) {
		float nu_mol = params.fluid_rho > 0.0 ? params.fluid_visc / params.fluid_rho : 0.0;
		float mix = SMAGORINSKY_COEFF * L;
		float nu = nu_mol + mix * mix * sqrt(18.0) * max(speed[c], 0.0) / L;
		need += 6.0 * nu * dt / (L * L);
	}
	if (params.law == LAW_SOUND) {
		need = max(need, 6.0 * sqrt(AIR_GAMMA * DRY_AIR_R * tk) * dt / L);
	}
	// NO SIGNAL CROSSES A CELL FASTER THAN LIGHT: a state asking for a shorter step is not a timestep.
	return min(need, params.dt_s * C_LIGHT / L);
}

uint la_row_level(uint c) {
	float need = la_row_need(c);
	return need > 1.0 ? uint(ceil(log2(need))) : 0u;
}


// PASS_LIST_APPEND: compact the interior cells whose `drive` is positive into active_idx. A DETECTOR,
// never a dispatch list: what the rows run over is the activity compaction above.
shared uint s_list_n;
shared uint s_list_base;

void list_append(uint g) {
	if (gl_LocalInvocationID.x == 0u) {
		s_list_n = 0u;
	}
	memoryBarrierShared();
	barrier();
	bool keep = false;
	if (g < params.cell_count) {
		keep = drive[g] > 0.0 && solid[g] == 0.0;
	}
	uint slot_local = 0u;
	if (keep) {
		slot_local = atomicAdd(s_list_n, 1u);
	}
	memoryBarrierShared();
	barrier();
	if (gl_LocalInvocationID.x == 0u) {
		s_list_base = atomicAdd(active_args[3], s_list_n);
	}
	memoryBarrierShared();
	barrier();
	if (keep) {
		uint slot = s_list_base + slot_local;
		if (slot < params.cell_count) {
			active_idx[slot] = g;
		}
	}
}


// The cells this group's list holds right now: bin 0's suffix is every level at once.
uint act_listed() { return level_args[args_base() + 6u]; }


// A ROW THE FIELD DOES NOT DRIVE CANNOT BE MEASURED ASLEEP BY THE FIELD. The escape law's push is the
// star's XUV and the zenith angle it arrives at, and both change while every cell stands still, so a
// face onto space stays awake whatever the field did.
bool la_outside_driven(uint c) {
	if (params.law != LAW_ESCAPE) {
		return false;
	}
	uint b = c * N_SLOTS;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		if (ghost[b + d] == GHOST_SPACE) {
			return true;
		}
	}
	return false;
}


// One cell into the compaction queue, counted into its level's bin; a second claimant is dropped.
void act_claim_append(uint n) {
	if (atomicExchange(act_claim[n], 1u) != 0u) {
		return;
	}
	uint slot = atomicAdd(level_args[args_base() + ACT_QUEUE_BIN * LEVEL_SLOTS + 3u], 1u);
	if (slot >= params.total_count) {
		return;
	}
	act_q[slot] = n;
	atomicAdd(level_args[args_base() + min(tlevel[n], ACT_BINS - 1u) * LEVEL_SLOTS + 3u], 1u);
}


// AN AWAKE CELL'S EVERY RECEIVER IS DISPATCHED, or what it donates lands nowhere.
void act_mark_ring(uint c) {
	act_claim_append(c);
	uint nbase = c * N_SLOTS;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int nb = nbr[nbase + d];
		if (nb < 0) { nb = ghost[nbase + d]; }
		if (nb >= 0 && uint(nb) < params.total_count) {
			act_claim_append(uint(nb));
		}
	}
}


void main() {
	uint gidx = gl_GlobalInvocationID.x;
	la_dt = params.dt_s;
	// pass_id is a push constant, so each branch here is uniform and APPEND's barriers are legal.
	if (params.pass_id == PASS_LIST_RESET) {
		if (gidx == 0u) {
			active_args[1] = 1u;
			active_args[2] = 1u;
			active_args[3] = 0u;
		}
		return;
	}
	if (params.pass_id == PASS_LIST_APPEND) {
		list_append(gidx);
		return;
	}
	if (params.pass_id == PASS_LIST_ARGS) {
		if (gidx == 0u) {
			// One workgroup minimum: a zero-group indirect dispatch is not uniformly safe across backends.
			active_args[0] = max(1u, (active_args[3] + 63u) / 64u);
		}
		return;
	}
	// THE TEMPORAL LEVELS. `params.level` carries the bin count on RESET and SCAN, the group slot on
	// PEAK, and the coarsest level advancing on every row dispatch.
	if (params.pass_id == PASS_LEVEL_PEAK) {
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			if (c < params.cell_count) {
				atomicMax(level_peak[params.level], la_row_level(c));
			}
		}
		return;
	}
	// ONE SUBSTEP OLDER. A cell whose counter reaches ACT_QUIET_SUBSTEPS has had nothing cross it and
	// stops donating; nothing reads its state either, which is why the books still close.
	if (params.pass_id == PASS_ACT_AGE) {
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			quiet[act_base() + c] = la_outside_driven(c) ? 0u : quiet[act_base() + c] + 1u;
		}
		return;
	}
	// EVERY CELL AWAKE AND EVERY CELL LISTED: what a world nobody has stepped yet looks like, and the
	// only pass here that walks the box. `act_group` carries the GROUP COUNT on this pass alone.
	if (params.pass_id == PASS_ACT_SEED) {
		uint gc = params.act_group;
		uint wide = max(1u, (params.total_count + 63u) / 64u);
		if (gidx < params.total_count) {
			wake_q[gidx] = gidx;
			for (uint g = 0u; g < gc; ++g) {
				level_idx[g * params.total_count + gidx] = gidx;
				quiet[g * params.total_count + gidx] = 0u;
			}
		}
		if (gidx < (ACT_QUEUE_BIN + 1u) * gc) {
			uint b = gidx * LEVEL_SLOTS;
			bool top = (gidx % (ACT_QUEUE_BIN + 1u)) == 0u;
			level_args[b] = top ? wide : 1u;
			level_args[b + 1u] = 1u;
			level_args[b + 2u] = 1u;
			level_args[b + 3u] = 0u;
			level_args[b + 4u] = 0u;
			level_args[b + 5u] = 0u;
			level_args[b + 6u] = top ? params.total_count : 0u;
		}
		if (gidx == 0u) {
			wake_args[0] = wide;
			wake_args[1] = 1u;
			wake_args[2] = 1u;
			wake_args[3] = params.total_count;
		}
		return;
	}
	// What another kernel changed is awake wherever it sits, in the list or out of it.
	if (params.pass_id == PASS_ACT_WAKE) {
		if (gidx < wake_args[3]) {
			uint c = wake_q[gidx];
			if (c < params.total_count) {
				quiet[act_base() + c] = 0u;
				act_mark_ring(c);
			}
		}
		return;
	}
	if (params.pass_id == PASS_ACT_WAKE_RESET) {
		if (gidx == 0u) {
			wake_args[0] = 1u;
			wake_args[1] = 1u;
			wake_args[2] = 1u;
			wake_args[3] = 0u;
		}
		return;
	}
	// THE LIST, rebuilt every substep: every awake cell, and every cell one face from one.
	if (params.pass_id == PASS_ACT_MARK) {
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			if (awake(c)) {
				act_mark_ring(c);
			}
		}
		return;
	}
	if (params.pass_id == PASS_LEVEL_RESET) {
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			tlevel[c] = 0u;
			uint rbase = c * N_SLOTS;
			for (uint d = 0u; d < N_SLOTS; ++d) {
				int rnb = nbr[rbase + d];
				if (rnb < 0) { rnb = ghost[rbase + d]; }
				if (rnb >= 0 && uint(rnb) < params.total_count) {
					tlevel[uint(rnb)] = 0u;
				}
			}
		}
		return;
	}
	if (params.pass_id == PASS_LEVEL_SEED) {
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			if (c < params.cell_count) {
				tlevel[c] = max(tlevel[c], la_row_level(c));
			}
		}
		return;
	}
	if (params.pass_id == PASS_LEVEL_RELAX) {
		// 2:1 IN TIME. A level only ever rises here, so an in-place sweep converges whichever order
		// the invocations land in.
		if (gidx < act_listed()) {
			uint c = level_idx[act_base() + gidx];
			uint rbase = c * N_SLOTS;
			uint mx = tlevel[c];
			for (uint d = 0u; d < N_SLOTS; ++d) {
				int rnb = nbr[rbase + d];
				if (rnb < 0) { rnb = ghost[rbase + d]; }
				if (rnb >= 0 && rnb < int(params.cell_count)) {
					uint ln = tlevel[uint(rnb)];
					mx = max(mx, ln > 0u ? ln - 1u : 0u);
				}
			}
			tlevel[c] = mx;
		}
		return;
	}
	if (params.pass_id == PASS_LEVEL_SCAN) {
		if (gidx == 0u) {
			uint b0 = args_base();
			uint run = 0u;
			for (uint b = 0u; b < ACT_BINS; ++b) {
				level_args[b0 + b * LEVEL_SLOTS + 4u] = run;
				level_args[b0 + b * LEVEL_SLOTS + 5u] = 0u;
				run += level_args[b0 + b * LEVEL_SLOTS + 3u];
			}
			for (uint b = 0u; b < ACT_BINS; ++b) {
				uint suffix = run - level_args[b0 + b * LEVEL_SLOTS + 4u];
				level_args[b0 + b * LEVEL_SLOTS + 6u] = suffix;
				level_args[b0 + b * LEVEL_SLOTS] = max(1u, (suffix + 63u) / 64u);
			}
			level_args[b0 + ACT_QUEUE_BIN * LEVEL_SLOTS] = max(1u, (run + 63u) / 64u);
		}
		return;
	}
	if (params.pass_id == PASS_LEVEL_SORT) {
		uint b0 = args_base();
		// Bin 0's suffix, which the scan just wrote: the queue's own count is cleared below.
		if (gidx < level_args[b0 + 6u]) {
			uint c = act_q[gidx];
			act_claim[c] = 0u;
			uint lv = min(tlevel[c], ACT_BINS - 1u);
			uint slot = level_args[b0 + lv * LEVEL_SLOTS + 4u]
				+ atomicAdd(level_args[b0 + lv * LEVEL_SLOTS + 5u], 1u);
			if (slot < params.total_count) {
				level_idx[act_base() + slot] = c;
			}
		}
		if (gidx < ACT_QUEUE_BIN + 1u) {
			level_args[b0 + gidx * LEVEL_SLOTS + 3u] = 0u;
		}
		return;
	}
	// EVERY PASS PAST HERE WALKS THIS GROUP'S ACTIVE LIST, never the box: the list is sorted by level,
	// so its suffix at params.level is exactly the cells moving on this substep. O(active), not O(cells).
	if ((params.flags & TF_LEVEL) != 0u) {
		uint la_b0 = args_base();
		if (gidx >= level_args[la_b0 + params.level * LEVEL_SLOTS + 6u]) {
			return;
		}
		gidx = level_idx[act_base() + level_args[la_b0 + params.level * LEVEL_SLOTS + 4u] + gidx];
	}
	// Acoustic half-step per momentum substep: dp = -rho c^2 div(u*) dt, in two passes.
	// LA_APPROX: split_explicit_acoustics
	if (params.pass_id == PASS_ACOUSTIC) {
		if (gidx >= params.cell_count) {
			return;
		}
		la_dt = la_level_dt(tlevel[gidx]);
		uint abase = gidx * N_SLOTS;
		send[abase] = 0.0;
		cel_m_s[gidx] = 0.0;
		// A cell with no bulk state carries no acoustic signal, and its impedance is rho c over a mass
		// that is not there. Asked FIRST, so nothing downstream evaluates it.
		if (solid[gidx] != 0.0 || no_matter(gidx)) {
			return;
		}
		float ks = bulk_mod(gidx);
		if (!(ks > 0.0)) {
			return;
		}
		float div_u = 0.0;
		float cel_top = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			int inb = nbr[abase + d];
			if (inb < 0) { inb = ghost[abase + d]; }
			vec3 nrm = face_normal(d);
			float ua = dot(vel_at(gidx), nrm);
			float za = impedance(gidx, d);
			cel_top = max(cel_top, face_c(gidx, d));
			// A FACE ONTO NOTHING IS A FREE SURFACE: vacuum presents no pressure, so the outgoing
			// characteristic alone sets the face velocity and the matter expands into it.
			if (inb == GHOST_SPACE
					|| (inb >= 0 && solid[inb] == 0.0 && no_matter(uint(inb)))) {
				div_u += za > 0.0 ? ua + face_p(gidx, d) / za : ua;
				continue;
			}
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			uint nb = uint(inb);
			float zb = impedance(nb, d ^ 1u);
			float zs = za + zb;
			if (zs <= 0.0) {
				continue;
			}
			float ub = dot(vel_at(nb), nrm);
			// Subtractive form of the same average: exact at equilibrium for any impedance pair.
			div_u += ua + (zb * (ub - ua) + (face_p(gidx, d) - face_p(nb, d ^ 1u))) / zs;
		}
		cel_m_s[gidx] = cel_top;
		send[abase] = -ks * div_u * la_dt / params.cell_m;
		return;
	}
	if (params.pass_id == PASS_ACOUSTIC_APPLY) {
		if (gidx < params.cell_count) {
			pressure[gidx] = pressure[gidx] + send[gidx * N_SLOTS];
			// This substep's share of the body impulse, beside the pressure gradient it stands against.
			float sf = exp2(-float(tlevel[gidx]));
			mom_x[gidx] += bodyf_x[gidx] * sf;
			mom_y[gidx] += bodyf_y[gidx] * sf;
			mom_z[gidx] += bodyf_z[gidx] * sf;
		}
		return;
	}
	// Ghost tail cells donate through the ordinary outflow law and are never updated: prescribed state.
	uint limit = (params.pass_id == 0u && params.mode != MODE_SEPARATE)
		? params.total_count : params.cell_count;
	if (gidx >= limit) {
		return;
	}
	uint la_lv = tlevel[gidx];
	la_dt = la_level_dt(la_lv);
	if (params.pass_id == PASS_GRAIN) {
		grain_state(gidx);
		return;
	}
	if (params.pass_id == PASS_SW) {
		sw_scatter(gidx);
		return;
	}
	uint base = gidx * N_SLOTS;
	bool is_signed = (params.flags & TF_SIGNED) != 0u;
	// Pore flow's domain IS the rock: its resistance, not a solid mask, is what stops it.
	bool through_pores = params.law == LAW_DARCY;
	// The solid mask stops MATTER. Heat is not matter, so conduction crosses rock both ways.
	bool blocks_solid = !through_pores && params.mode != MODE_RADIATE && params.mode != MODE_CONDUCT;

	if (params.pass_id == 0u) {
		for (uint d = 0u; d < N_SLOTS; ++d) {
			send[base + d] = 0.0;
			send_h[base + d] = 0.0;
			send_q[base + d] = 0.0;
			send_mx[base + d] = 0.0;
			send_my[base + d] = 0.0;
			send_mz[base + d] = 0.0;
		}
		// DETECTORS ONLY, stamped in pass 0 off the one pre-drain state the OHMIC mobility acts on.
		if ((params.flags & TF_EFIELD) != 0u && gidx < params.cell_count) {
			float e_here = column_field(gidx);
			float thr = rrea_threshold(gidx);
			col_e[gidx] = e_here;
			strike[gidx] = (thr > 0.0 && e_here >= thr) ? 1.0 : 0.0;
		}
		// A SLEEPING CELL DONATES NOTHING: it is listed to receive, and that is all.
		if (!awake(gidx)) {
			return;
		}
		if (solid[gidx] != 0.0 && blocks_solid) {
			return;
		}
		// MODE_RADIATE emits through every face; at the box edge nobody gathers and it leaves for space.
		if (params.mode == MODE_RADIATE) {
			float eps = longwave_emissivity(gidx);
			lw_emis[gidx] = eps;
			sw_absorbed[gidx] = shortwave_absorbed_frac(gidx, solar_step_m());
			// Share of an upwelling flux this cell keeps as heat over one vertical step: what it
			// intercepts, minus what it reflects onward.
			vec3 gsw = g_at(gidx);
			float up_len = length(gsw) > 0.0
				? la_step_len(-normalize(gsw), params.cell_m) : params.cell_m;
			sw_keep[gidx] = shortwave_absorbed_frac(gidx, up_len) * (1.0 - shortwave_albedo(gidx));
			float tk = t_k(gidx);
			float leaving = eps * STEFAN * tk * tk * tk * tk * la_dt / params.cell_m;
			for (uint d = 0u; d < N_SLOTS; ++d) {
				send[base + d] = leaving;
			}
			return;
		}
		// SEPARATION: the donor keeps the light phase's charge and sends the heavy phase's down.
		if (params.mode == MODE_SEPARATE) {
			vec3 gv = g_at(gidx);
			if (length(gv) <= 0.0) {
				return;
			}
			vec3 up = -normalize(gv);
			float dq = separation_dq(gidx, up);
			if (dq <= 0.0) {
				return;
			}
			int slot = la_slot_toward(-up);
			if (slot < 0) {
				return;
			}
			int below = nbr[base + uint(slot)];
			// A charge with nowhere to go is not a separated charge.
			if (below < 0 || solid[below] != 0.0) {
				return;
			}
			send[base + uint(slot)] = -dq;
			return;
		}
		// A TF_FRACTION row moves only the phase share `frac` names; the rest of the channel stays put.
		float share = (params.flags & TF_FRACTION) != 0u ? clamp(frac[gidx], 0.0, 1.0) : 1.0;
		float remaining = amount[gidx] * share;
		// The one floor in this row's own unit. None on a SIGNED row: it could never start moving.
		float kg_mol = sub_kg_mol();
		float donor_floor = kg_mol > 0.0 ? params.rho_floor / kg_mol : 0.0;
		if (!is_signed && remaining <= donor_floor) {
			return;
		}
		// MASS CARRIES ITS HEAT, ITS CHARGE AND ITS MOMENTUM, however thin the cell it leaves.
		bool carries = params.density > 0.0 && amount[gidx] > 0.0;
		// Heat per unit fill of THIS substance: its share of the entry its heat sits in.
		float h_per_unit = 0.0;
		if (carries) {
			if (params.sub_cap_j_m3k > 0.0) {
				float cap = cap_sensible[gidx];
				h_per_unit = cap > 0.0 ? h_carried[gidx] * params.sub_cap_j_m3k / cap : 0.0;
			} else {
				h_per_unit = h_carried[gidx] / amount[gidx];
			}
		}
		// The flux's mass share of the cell, floored by the substance's own mass.
		float denom_m = max(max(rho_bulk[gidx], 0.0), kg_mol * amount[gidx]);
		float m_share = (carries && denom_m > 0.0) ? kg_mol / denom_m : 0.0;
		float open = 1.0 - clamp(resist[gidx], 0.0, 1.0);
		if (open <= 0.0) {
			return;
		}
		float amt0 = abs(remaining);

		for (uint d = 0u; d < N_SLOTS; ++d) {
			if (!is_signed && remaining <= donor_floor) {
				break;
			}
			int inb = nbr[base + d];
			if (inb < 0) {
				inb = ghost[base + d];
			}
			// LA_APPROX: level_seam_coarse_clock
			// A face runs on the COARSER of the pair's clocks, so both sides write it on the same
			// substep with the same seconds; a coarser neighbour is not stepping now at all.
			if (inb >= 0 && uint(inb) < params.total_count) {
				uint lvn = tlevel[uint(inb)];
				if (lvn < params.level) {
					continue;
				}
				la_dt = la_level_dt(min(la_lv, lvn));
			} else {
				la_dt = la_level_dt(la_lv);
			}
			if (params.law == LAW_ESCAPE) {
				if (inb != GHOST_SPACE || gidx >= params.cell_count) {
					continue;
				}
				float tail = 0.0;
				float flow_e = clamp(remaining * escape_fraction(gidx, d, tail) * open, 0.0, remaining);
				if (flow_e <= 0.0) {
					continue;
				}
				send[base + d] = flow_e;
				send_h[base + d] = flow_e * (h_per_unit + tail);
				send_q[base + d] = flow_e * m_share * charge[gidx];
				send_mx[base + d] = flow_e * m_share * mom_x[gidx];
				send_my[base + d] = flow_e * m_share * mom_y[gidx];
				send_mz[base + d] = flow_e * m_share * mom_z[gidx];
				remaining -= flow_e;
				continue;
			}
			// A WALL STILL PUSHES: matter crosses neither a solid face nor a shut box edge, pressure does.
			bool wall = inb < 0 || (solid[inb] != 0.0 && blocks_solid);
			if (wall && !(is_signed && params.law == LAW_PGF)) {
				continue;
			}
			uint nb = uint(max(inb, 0));
			if (is_signed) {
				// ONE WRITER PER FACE (+axis side, or a wall's only fluid side), else applied twice.
				if (!wall && (d & 1u) == 0u) {
					continue;
				}
				vec3 nrm = face_normal(d);
				float ni_axis = params.axis == 0u ? nrm.x : (params.axis == 1u ? nrm.y : nrm.z);
				// This component's pressure flux through an off-axis face is zero by construction.
				if (params.law == LAW_PGF && ni_axis == 0.0) {
					continue;
				}
				float sflux = 0.0;
				if (params.law == LAW_PGF) {
					// Pressure's momentum flux. A wall meets the cell's own reconstructed face pressure,
					// a face onto vacuum meets none, an open face the linearized Riemann p*.
					bool onto_void = inb == GHOST_SPACE || (!wall && no_matter(nb));
					float p_face = onto_void ? 0.0 : face_p(gidx, d);
					float za = impedance(gidx, d);
					float zb = wall ? 0.0 : impedance(nb, d ^ 1u);
					if (!wall && !onto_void && !no_matter(gidx) && za + zb > 0.0) {
						float ua = dot(vel_at(gidx), nrm);
						float ub = dot(vel_at(nb), nrm);
						// Subtractive form: exact at equilibrium for any impedance pair.
						p_face = p_face
							+ za * (face_p(nb, d ^ 1u) - p_face + zb * (ua - ub)) / (za + zb);
					}
					float ni = params.axis == 0u ? nrm.x : (params.axis == 1u ? nrm.y : nrm.z);
					sflux = p_face * ni * la_dt / params.cell_m;
				} else {
					// VISCOSITY DIFFUSES VELOCITY, mu grad(v): the pair's exact frozen-coefficient
					// relaxation moves momentum toward equal velocities and never past them.
					// LA_APPROX: frozen_pair_relaxation
					float ra = max(rho_bulk[gidx], 0.0);
					float rb = max(rho_bulk[nb], 0.0);
					if (ra > 0.0 && rb > 0.0) {
						float va = amount[gidx] / ra;
						float vb = amount[nb] / rb;
						float mu = 0.5 * (ra + rb) * eddy_viscosity(gidx);
						float k = mu * (1.0 / ra + 1.0 / rb) / (params.cell_m * params.cell_m);
						float m_red = ra * rb / (ra + rb);
						// All six faces relax from ONE pre-state, so each takes at most a sixth of full
						// equalization; the summed pull can then never pass the neighbours' mean.
						sflux = m_red * (va - vb)
							* (1.0 - exp(-float(N_SLOTS) * k * la_dt)) / float(N_SLOTS) * open;
					}
				}
				send[base + d] = sflux;
				continue;
			}
			bool advective = params.mode == MODE_ADVECT || params.mode == MODE_BOTH;
			float drop = potential(gidx, d) - potential(nb, d ^ 1u);
			// A THRESHOLD GRADIENT. Granular material holds a slope up to its angle of repose; a column of
			// gas holds a temperature gradient up to its adiabat. Same construct, one cell of run either way.
			if (params.repose_tan > 0.0) {
				// One cell of run, amount-scaled exactly as the elevation term inside `potential`.
				drop -= params.repose_tan * params.cell_m * params.max_fill;
			}
			if (drop <= 0.0 && !advective && params.mode != MODE_CONDUCT) {
				continue;
			}
			float flow = 0.0;
			if (drop > 0.0) {
				float mob_face = through_pores
					? darcy_mobility(gidx, nb) : mobility_at(gidx, amt0);
				// The pair's imbalance decays as exp(-k t), so the share that crosses approaches it
				// rather than passing it. LA_APPROX: exponential_pair_relaxation
				flow = drop * (1.0 - exp(-mob_face * open / params.cell_m));
			}
			if (params.mode == MODE_CONDUCT) {
				// Series half-cells, so the interface conductivity is the harmonic mean, and
				// dh = lambda_i * (T_here - T_nb) * dt / dx^2 off `drive`: `drop` carries a spare cell_m.
				float a = aux[gidx];
				float b = aux[nb];
				float lam = 2.0 * a * b / max(a + b, 1.0e-12);
				flow = lam * (drive[gidx] - drive[nb]) * la_dt
					/ (params.cell_m * params.cell_m);
			}
			if (advective) {
				// Outgoing advective flux at the FACE velocity, the linearized Riemann u*: air falling
				// onto water compresses against it rather than entering it. Settling slip rides on top.
				vec3 nrm_a = face_normal(d);
				float ua = dot(vel_at(gidx), nrm_a);
				float ub = dot(vel_at(nb), nrm_a);
				float za = impedance(gidx, d);
				float zb = impedance(nb, d ^ 1u);
				float vn = (no_matter(nb) || za + zb <= 0.0)
					? (za > 0.0 ? ua + face_p(gidx, d) / za : ua)
					: ua + (zb * (ub - ua) + (face_p(gidx, d) - face_p(nb, d ^ 1u))) / (za + zb);
				vn += dot(transport_velocity(gidx) - vel_at(gidx), nrm_a);
				if (vn > 0.0) {
					flow += remaining * vn * la_dt / params.cell_m;
				}
			}
			flow = clamp(flow, 0.0, remaining);
			// LA_APPROX: shared_face_headroom
			if (!is_signed && params.max_fill > 0.0 && !isinf(params.max_fill)) {
				flow = min(flow, max(params.max_fill - amount[nb], 0.0) / float(N_SLOTS));
			}
			if (flow <= 0.0) {
				continue;
			}
			send[base + d] = flow;
			send_h[base + d] = flow * h_per_unit;
			send_q[base + d] = flow * m_share * charge[gidx];
			send_mx[base + d] = flow * m_share * mom_x[gidx];
			send_my[base + d] = flow * m_share * mom_y[gidx];
			send_mz[base + d] = flow * m_share * mom_z[gidx];
			remaining -= flow;
		}
		return;
	}

	// Pass 1: gather.
	// Rock is quasi-static: a wall's normal push goes to the body, never into a solid cell's momentum.
	if (is_signed && solid[gidx] != 0.0) {
		return;
	}
	float gained = 0.0;
	float gained_h = 0.0;
	float gained_q = 0.0;
	float lost = 0.0;
	float lost_h = 0.0;
	float lost_q = 0.0;
	vec3 gained_m = vec3(0.0);
	vec3 lost_m = vec3(0.0);
	float absorptivity = params.mode == MODE_RADIATE ? lw_emis[gidx] : 0.0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		lost += send[base + d];
		lost_h += send_h[base + d];
		lost_q += send_q[base + d];
		lost_m += vec3(send_mx[base + d], send_my[base + d], send_mz[base + d]);
		int inb = nbr[base + d];
		bool edge = inb < 0;
		if (edge) {
			inb = ghost[base + d];
		}
		// A wall books the signed push; the space edge books the escape law's matter, heat, charge, momentum.
		if (inb < 0) {
			if (is_signed) {
				bnd_amt[gidx] -= send[base + d];
			} else if (params.law == LAW_ESCAPE) {
				bnd_amt[gidx] -= send[base + d];
				bnd_h[gidx] -= send_h[base + d];
				bnd_q[gidx] -= send_q[base + d];
				bnd_mom_x[gidx] -= send_mx[base + d];
				bnd_mom_y[gidx] -= send_my[base + d];
				bnd_mom_z[gidx] -= send_mz[base + d];
			}
			continue;
		}
		uint nb = uint(inb);
		// The same face rule as the outflow: a neighbour coarser than this substep did not run, so its
		// face scratch is not this substep's and nothing crossed.
		if (nb < params.total_count && tlevel[nb] < params.level) {
			continue;
		}
		if (is_signed && solid[nb] != 0.0 && blocks_solid) {
			bnd_amt[gidx] -= send[base + d];
			continue;
		}
		// Exterior crossings book inflow-positive; a wrap partner is interior motion and books nothing.
		bool exterior = edge && nb >= params.cell_count;
		// SEPARATE moves charge down its own column, never across the box edge, and its ghost tail never
		// ran pass 0, so its face scratch there is another row's.
		if (exterior && params.mode == MODE_SEPARATE) {
			continue;
		}
		if (exterior && params.mode != MODE_RADIATE) {
			float in_a = awake(nb) ? send[nb * N_SLOTS + (d ^ 1u)] : 0.0;
			bnd_amt[gidx] += in_a - send[base + d];
			// A signed row (momentum) is not matter and carries no heat leg.
			if (!is_signed) {
				uint nbo = nb * N_SLOTS + (d ^ 1u);
				float in_h = awake(nb) ? send_h[nbo] : 0.0;
				bnd_h[gidx] += (params.flags & TF_ENTHALPY) != 0u
					? in_a - send[base + d]
					: in_h - send_h[base + d];
				float in_q = awake(nb) ? send_q[nbo] : 0.0;
				bnd_q[gidx] += in_q - send_q[base + d];
				// The momentum the crossing mass carries, booked on its own signed legs.
				vec3 in_m = awake(nb)
					? vec3(send_mx[nbo], send_my[nbo], send_mz[nbo]) : vec3(0.0);
				bnd_mom_x[gidx] += in_m.x - send_mx[base + d];
				bnd_mom_y[gidx] += in_m.y - send_my[base + d];
				bnd_mom_z[gidx] += in_m.z - send_mz[base + d];
			}
		}
		// ONLY AN AWAKE CELL RAN THE OUTFLOW, so only its face scratch is this substep's; a sleeping
		// cell's still holds whatever row wrote it last.
		if (!awake(nb)) {
			continue;
		}
		// Radiation arrives from the whole grid line behind this face, not just from the cell touching it.
		gained += params.mode == MODE_RADIATE
			? absorptivity * longwave_incident(gidx, d)
			: send[nb * N_SLOTS + (d ^ 1u)];
		gained_h += send_h[nb * N_SLOTS + (d ^ 1u)];
		gained_q += send_q[nb * N_SLOTS + (d ^ 1u)];
		gained_m += vec3(send_mx[nb * N_SLOTS + (d ^ 1u)], send_my[nb * N_SLOTS + (d ^ 1u)],
			send_mz[nb * N_SLOTS + (d ^ 1u)]);
	}
	if (params.mode == MODE_RADIATE) {
		float sun_w = solar_incident(gidx);
		float intercepted = sun_w * sw_absorbed[gidx];
		float albedo = shortwave_albedo(gidx);
		gained += intercepted * (1.0 - albedo) * la_dt / params.cell_m;
		rad_absorbed[gidx] = gained;
		rad_emitted[gidx] = lost;
		// What the beam march removed and this cell did not keep: PASS_SW carries it back out.
		sw_src[gidx] = intercepted * albedo;
		// Stefan-Boltzmann, recomputed against the published emission: six faces of e*sigma*T^4.
		float tk_sb = t_k(gidx);
		float sb = 6.0 * lw_emis[gidx] * STEFAN * tk_sb * tk_sb * tk_sb * tk_sb
			* la_dt / params.cell_m;
		rad_residual[gidx] = abs(lost - sb) / max(sb, 1.0e-30);
	}
	bool la_moved = lost != 0.0 || gained != 0.0;
	// No floor: clamping a negative up here would create the mass it is short of.
	float was = amount[gidx];
	amount[gidx] = was - lost + gained;
	// What arrives is loose, so the cemented SHARE falls by exactly the ratio the total grew.
	if ((params.flags & TF_DILUTE) != 0u && amount[gidx] > was && was > 0.0) {
		cement[gidx] = clamp(cement[gidx] * was / amount[gidx], 0.0, 1.0);
	}
	h[gidx] = h[gidx] - lost_h + gained_h;
	charge[gidx] = charge[gidx] - lost_q + gained_q;
	if (!is_signed) {
		mom_x[gidx] = mom_x[gidx] - lost_m.x + gained_m.x;
		mom_y[gidx] = mom_y[gidx] - lost_m.y + gained_m.y;
		mom_z[gidx] = mom_z[gidx] - lost_m.z + gained_m.z;
		// The derived sums follow their inputs: moved matter takes its mass, entry heat and sensible
		// capacity with it, and the pressure answers the arrived mass at once (dp = K_s da).
		if (params.density > 0.0) {
			float da = gained - lost;
			rho_bulk[gidx] = max(rho_bulk[gidx] + da * sub_kg_mol(), 0.0);
			h_carried[gidx] += gained_h - lost_h;
			if (params.sub_cap_j_m3k > 0.0) {
				cap_sensible[gidx] = max(cap_sensible[gidx] + da * params.sub_cap_j_m3k, 0.0);
			}
			// dp = K_s da: the mixture's bulk modulus times the VOLUME SHARE that arrived. A row whose
			// substance declares no full amount has no volume share, and 0/0 is not a pressure.
			if (solid[gidx] == 0.0 && params.max_fill > 0.0 && !isinf(params.max_fill)) {
				pressure[gidx] = pressure[gidx]
					+ bulk_mod(gidx) * (da / params.max_fill);
			}
		}
	}
	// LA_APPROX: boundary_relaxation_zone
	bool la_last = params.substep_k + (params.substep_n >> la_lv) >= params.substep_n;
	if ((params.flags & TF_RELAX) != 0u && la_last && rim_w[gidx] > 0.0
			&& !(solid[gidx] != 0.0 && blocks_solid)) {
		int rg = rim_ghost[gidx];
		if (rg >= int(params.cell_count) && rg < int(params.total_count)) {
			uint rgu = uint(rg);
			float dq = rim_w[gidx] * (amount[rgu] - amount[gidx]);
			if (dq != 0.0) {
				float dh = 0.0;
				if ((params.flags & TF_ENTHALPY) != 0u) {
					dh = dq;
				} else if (params.density > 0.0) {
					uint hc = dq > 0.0 ? rgu : gidx;
					float h_pu = 0.0;
					if (params.sub_cap_j_m3k > 0.0) {
						float cap = cap_sensible[hc];
						h_pu = cap > 0.0 ? h_carried[hc] * params.sub_cap_j_m3k / cap : 0.0;
					} else if (amount[hc] > 0.0) {
						h_pu = h_carried[hc] / amount[hc];
					}
					dh = dq * h_pu;
					h[gidx] += dh;
				}
				float held = amount[gidx];
				amount[gidx] = held + dq;
				if ((params.flags & TF_DILUTE) != 0u && dq > 0.0 && held > 0.0) {
					cement[gidx] = clamp(cement[gidx] * held / amount[gidx], 0.0, 1.0);
				}
				if (params.density > 0.0) {
					rho_bulk[gidx] = max(rho_bulk[gidx] + dq * sub_kg_mol(), 0.0);
					h_carried[gidx] += dh;
					if (params.sub_cap_j_m3k > 0.0) {
						cap_sensible[gidx] = max(cap_sensible[gidx] + dq * params.sub_cap_j_m3k, 0.0);
					}
				}
				bnd_amt[gidx] += dq;
				bnd_h[gidx] += dh;
				la_moved = true;
			}
		}
	}
	// v = p/rho off the momentum this gather settled, rim nudge included, so the next substep advects
	// the new field.
	if ((params.flags & TF_VEL) != 0u) {
		// Below the donation floor the cell is empty and at rest: a momentum residue over vanishing
		// mass is any velocity at all.
		float rb = rho_bulk[gidx];
		float vc = rb > params.rho_floor ? amount[gidx] / rb : 0.0;
		if (params.axis == 0u) {
			vel_x[gidx] = vc;
		} else if (params.axis == 1u) {
			vel_y[gidx] = vc;
		} else {
			vel_z[gidx] = vc;
			// The z gather runs last, so the drained CFL peak reads the step's final speed, not a
			// one-step-stale one.
			speed[gidx] = length(vel_at(gidx));
		}
	}
	if ((params.flags & TF_RADIOGENIC) != 0u) {
		// The rock warms itself, at this epoch's rate. This row carries h_j_m3, so `amount` IS enthalpy.
		float dq = max(rad_w_m3[gidx], 0.0) * la_dt;
		amount[gidx] += dq;
		radiogenic[gidx] = dq;
		la_moved = la_moved || dq != 0.0;
	}
	// PROPAGATION: the bubble grows one cell per substep, as fast as anything in it travels.
	if (la_moved) {
		quiet[act_base() + gidx] = 0u;
		if (params.act_group2 != ACT_NO_GROUP) {
			quiet[params.act_group2 * params.total_count + gidx] = 0u;
		}
		for (uint d = 0u; d < N_SLOTS; ++d) {
			int wnb = nbr[base + d];
			if (wnb < 0) { wnb = ghost[base + d]; }
			if (wnb >= 0 && uint(wnb) < params.total_count) {
				quiet[act_base() + uint(wnb)] = 0u;
			}
		}
	}
}
