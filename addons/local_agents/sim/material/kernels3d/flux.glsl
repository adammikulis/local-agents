#[compute]
#version 450

#include "bindings.glsli"

// ONE CONSERVATIVE FACE FLUX: mass, momentum, enthalpy and charge ride one interface velocity, and a
// column in balance produces zero flux.

#include "cellvol.glsli"
#include "neighbours.glsli"
#include "generated.glsli"
#include "stack.glsli"
#include "band.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_FLUX_AMOUNT, std430) buffer Amount   { float amount[]; };
// No `restrict`: a record whose channel IS an energy reservoir binds one buffer here and at Amount.
layout(set = 0, binding = LA_BIND_FLUX_ENERGY, std430) buffer Energy { float e[]; };
layout(set = 0, binding = LA_BIND_NBR, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = LA_BIND_SOLID, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity per cell, flat cell*3, m/s^2, the rotating frame's terms already in it.
layout(set = 0, binding = LA_BIND_G_REST, std430) restrict readonly buffer Grav { float g_field[]; };

layout(set = 0, binding = LA_BIND_VEL_X, std430) restrict buffer VelX { float vel_x[]; };
layout(set = 0, binding = LA_BIND_VEL_Y, std430) restrict buffer VelY { float vel_y[]; };
layout(set = 0, binding = LA_BIND_VEL_Z, std430) restrict buffer VelZ { float vel_z[]; };
// THE FACE STATE, indexed by FACE: the interface velocity along the owning cell's outward normal and
// the interface pressure. LAVoxelGrid.slot_off says where a cell's own faces begin.
layout(set = 0, binding = LA_BIND_FLUX_FACE_U, std430) restrict buffer FaceU { float face_u[]; };
layout(set = 0, binding = LA_BIND_FLUX_FP_STAR, std430) restrict buffer FaceP { float fp_star[]; };
// The WATER PAIR of the same face: the band's interface velocity and pressure, stated where both
// sides are wet.
layout(set = 0, binding = LA_BIND_FLUX_FACE_UW, std430) restrict buffer FaceUW { float face_uw[]; };
layout(set = 0, binding = LA_BIND_FLUX_FPW_STAR, std430) restrict buffer FacePW { float fpw_star[]; };
// Depth of the ground under the cell's fluid below its centre, m, along its own vertical: the seeded
// shape, until something moves rock.
layout(set = 0, binding = LA_BIND_GROUND_D, std430) restrict readonly buffer GroundD { float ground_d[]; };
// The free surface each cell solved this step, depth below its centre, m.
layout(set = 0, binding = LA_BIND_FLUX_W_TOP, std430) restrict buffer WaterTop { float w_top[]; };
// Charge rides the mass, exactly as enthalpy does: it is carried, never created by a move.
layout(set = 0, binding = LA_BIND_CHARGE, std430) buffer Charge { float charge[]; };
// The RADIATE march's own per-face scratch: what each face emits, J/m^3.
layout(set = 0, binding = LA_BIND_FLUX_SEND, std430) restrict buffer Send { float send[]; };
// Flow resistance 0..1 per cell.
layout(set = 0, binding = LA_BIND_FLUX_RESIST, std430) restrict readonly buffer Resist { float resist[]; };
// What a potential-driven row runs down; `amount` when a record names none. No `restrict`: the
// conduction row binds temperature here and reads it under another name too.
layout(set = 0, binding = LA_BIND_FLUX_DRIVE, std430) readonly buffer Drive { float drive[]; };
// Whatever else the row's law reads per cell: conductivity for MODE_CONDUCT, cloud water for LAW_OHMIC.
layout(set = 0, binding = LA_BIND_FLUX_AUX, std430) restrict readonly buffer Aux { float aux[]; };

layout(set = 0, binding = LA_BIND_TEMP, std430) restrict readonly buffer TempBuf     { float temp[]; };
// The lattice reservoir: temperature, sensible capacity, volume share.
layout(set = 0, binding = LA_BIND_TEMP_LITH, std430) restrict readonly buffer TempLith { float temp_lith[]; };
layout(set = 0, binding = LA_BIND_CAP_LITH, std430) restrict readonly buffer CapLith { float cap_lith[]; };
layout(set = 0, binding = LA_BIND_LATTICE_FRAC, std430) restrict readonly buffer LatticeFrac { float lattice_frac[]; };
// READ ONLY. An open cell's pressure is state_derive.glsl's equation of state and nothing else's.
layout(set = 0, binding = LA_BIND_PRESSURE, std430) readonly buffer PressureBuf { float pressure[]; };
layout(set = 0, binding = LA_BIND_POROSITY, std430) restrict readonly buffer PorosityBuf { float porosity[]; };
layout(set = 0, binding = LA_BIND_GRAIN, std430) restrict readonly buffer GrainBuf    { float grain[]; };
layout(set = 0, binding = LA_BIND_CO2, std430) readonly buffer CO2Buf      { float co2[]; };
// ONE H2O CHANNEL plus the three DERIVED shares state_derive.glsl publishes; they differ optically.
layout(set = 0, binding = LA_BIND_H2O, std430) readonly buffer H2OBuf       { float h2o[]; };
// LAAbsorptionBands.packed(), the band table.
layout(set = 0, binding = LA_BIND_FLUX_RAD_TABLE, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = LA_BIND_H2O_SOLID, std430) restrict readonly buffer H2OSolidBuf  { float h2o_solid[]; };
layout(set = 0, binding = LA_BIND_H2O_LIQUID, std430) restrict readonly buffer H2OLiquidBuf { float h2o_liquid[]; };
layout(set = 0, binding = LA_BIND_SILICATE, std430) readonly buffer SilicateBuf { float silicate[]; };
layout(set = 0, binding = LA_BIND_BIOMASS, std430) restrict readonly buffer BiomassBuf  { float biomass[]; };
layout(set = 0, binding = LA_BIND_SILICATE_MELT, std430) restrict readonly buffer SilicateMeltBuf { float silicate_melt[]; };
// Boundary redirect per face: a wrapped interior cell, a prescribed ghost tail cell, or -1 = shut wall.
layout(set = 0, binding = LA_BIND_GHOST, std430) restrict readonly buffer Ghost { int ghost[]; };
layout(set = 0, binding = LA_BIND_H2O_VAPOUR, std430) restrict readonly buffer H2OVapourBuf { float h2o_vapour[]; };
// TF_FRACTION records move only this share of `amount`, 0..1. No `restrict`: the grain prologue
// writes the very buffers three silicate records bind as their `frac`.
layout(set = 0, binding = LA_BIND_FLUX_FRAC, std430) readonly buffer FracBuf { float frac[]; };
// Consolidated share of the cell's silicate. A TF_DILUTE row rescales it when matter arrives.
layout(set = 0, binding = LA_BIND_CEMENT, std430) restrict buffer CementBuf { float cement[]; };
// Where the cell's loose mineral grains are, written by the PASS_GRAIN prologue.
layout(set = 0, binding = LA_BIND_SILICATE_SUSP_WATER, std430) writeonly buffer SuspWater { float silicate_susp_water[]; };
layout(set = 0, binding = LA_BIND_SILICATE_SUSP_AIR, std430) writeonly buffer SuspAir { float silicate_susp_air[]; };
layout(set = 0, binding = LA_BIND_SILICATE_BED, std430) writeonly buffer Bed { float silicate_bed[]; };
// MODE_RADIATE's own books, J/m^3, assigned in the gather so each is a per-step rate needing no clear.
layout(set = 0, binding = LA_BIND_RAD_ABSORBED, std430) restrict buffer RadAbs { float rad_absorbed[]; };
layout(set = 0, binding = LA_BIND_RAD_EMITTED, std430) restrict writeonly buffer RadEmit { float rad_emitted[]; };
// The column field and the breakdown it decides, published rather than re-derived on the CPU.
layout(set = 0, binding = LA_BIND_COL_E, std430) restrict writeonly buffer ColE { float col_e[]; };
layout(set = 0, binding = LA_BIND_STRIKE, std430) restrict writeonly buffer Strike { float strike[]; };
layout(set = 0, binding = LA_BIND_RAD_W_M3, std430) restrict readonly buffer RadW { float rad_w_m3[]; };  // W/m^3
// The greenhouse trace gases the band table resolves, mol/m^3.
layout(set = 0, binding = LA_BIND_CH4, std430) readonly buffer Ch4Buf { float ch4[]; };
layout(set = 0, binding = LA_BIND_RADIOGENIC, std430) restrict writeonly buffer Radiogenic { float radiogenic[]; };
layout(set = 0, binding = LA_BIND_FLUX_LW_EMIS, std430) restrict buffer LwEmis { float lw_emis[]; };
layout(set = 0, binding = LA_BIND_FLUX_SW_ABSORBED, std430) restrict buffer SwAbs { float sw_absorbed[]; };
// Heat of the entry this row's substance sits in, and that entry's capacity, J/m^3 and J/m^3/K.
layout(set = 0, binding = LA_BIND_FLUX_H_CARRIED, std430) restrict buffer HCarried { float h_carried[]; };
layout(set = 0, binding = LA_BIND_CAP_SENSIBLE, std430) restrict buffer CapSensible { float cap_sensible[]; };
// What crossed an OPEN box edge this step, per interior cell: amount in, joules riding along.
layout(set = 0, binding = LA_BIND_FLUX_BND_AMT, std430) restrict buffer BndAmt { float bnd_amt[]; };
layout(set = 0, binding = LA_BIND_FLUX_BND_H, std430) restrict buffer BndH { float bnd_h[]; };
// The REPLAY relaxation rim: the driving ghost cell and the per-step nudge fraction; 0 = outside it.
layout(set = 0, binding = LA_BIND_RIM_GHOST, std430) restrict readonly buffer RimGhost { int rim_ghost[]; };
layout(set = 0, binding = LA_BIND_RIM_W, std430) restrict readonly buffer RimW { float rim_w[]; };
// The reflected-shortwave field: what a cell keeps, its reflected source W/m^2, what escapes.
layout(set = 0, binding = LA_BIND_FLUX_SW_KEEP, std430) restrict buffer SwKeep { float sw_keep[]; };
layout(set = 0, binding = LA_BIND_FLUX_SW_SRC, std430) restrict buffer SwSrc { float sw_src[]; };
layout(set = 0, binding = LA_BIND_SW_SPACE, std430) restrict writeonly buffer SwSpace { float sw_space[]; };
layout(set = 0, binding = LA_BIND_RAD_RESIDUAL, std430) restrict writeonly buffer RadResid { float rad_residual[]; };
// O3 partial density, kg/m^3. Zeros until a photochemical o3 channel exists to swap in.
layout(set = 0, binding = LA_BIND_FLUX_O3, std430) restrict readonly buffer O3Buf { float o3[]; };
// Mass density per cell, kg/m^3, written by every mass row's own delta.
layout(set = 0, binding = LA_BIND_RHO_BULK, std430) restrict buffer RhoBulk { float rho_bulk[]; };
// MASS MOVES WITH ITS MOMENTUM. No `restrict`: a record's own channel may be one of these three.
layout(set = 0, binding = LA_BIND_MOM_X, std430) buffer MomX { float mom_x[]; };
layout(set = 0, binding = LA_BIND_MOM_Y, std430) buffer MomY { float mom_y[]; };
layout(set = 0, binding = LA_BIND_MOM_Z, std430) buffer MomZ { float mom_z[]; };
// The mixture's own kinematic eddy viscosity, m^2/s, stated once per cell so both sides of a face
// read one number and the viscous flux is antisymmetric.
layout(set = 0, binding = LA_BIND_FLUX_NU_T, std430) restrict buffer NuT { float nu_t[]; };
// THIS RECORD'S FLUX THROUGH EACH FACE, positive OUT of the cell that owns it: matter, the heat
// riding it, the charge riding it. Read in one canonical order, so a face's two entries negate.
layout(set = 0, binding = LA_BIND_FLUX_X_AMT, std430) restrict buffer XAmt { float x_amt[]; };
layout(set = 0, binding = LA_BIND_FLUX_X_H, std430) restrict buffer XH { float x_h[]; };
layout(set = 0, binding = LA_BIND_FLUX_X_Q, std430) restrict buffer XQ { float x_q[]; };
layout(set = 0, binding = LA_BIND_HZ_P, std430) restrict readonly buffer HzP { float hz_p[]; };
// What pressure_helmholtz.glsl assembles its row from: kg/Pa, kg/s and m.
layout(set = 0, binding = LA_BIND_HZ_COMP, std430) restrict buffer HzComp { float hz_comp[]; };
layout(set = 0, binding = LA_BIND_HZ_FLUX, std430) restrict buffer HzFlux { float hz_flux[]; };
layout(set = 0, binding = LA_BIND_HZ_COND, std430) restrict buffer HzCond { float hz_cond[]; };
// The mixture's own sound speed, m/s, off the layer each face presents.
layout(set = 0, binding = LA_BIND_GAS_R, std430) restrict readonly buffer GasR { float gas_r[]; };
layout(set = 0, binding = LA_BIND_GAS_GAMMA, std430) restrict readonly buffer GasGamma { float gas_gamma[]; };
layout(set = 0, binding = LA_BIND_K_COND, std430) restrict readonly buffer KCondBuf { float k_cond[]; };
// |v| refreshed by the momentum pass, so the drained CFL peak is next step's read.
layout(set = 0, binding = LA_BIND_SPEED, std430) restrict buffer SpeedBuf { float speed[]; };
// The step's body impulse per cell, kg/(m^2 s), booked by state_derive.
layout(set = 0, binding = LA_BIND_BODYF_X, std430) restrict readonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = LA_BIND_BODYF_Y, std430) restrict readonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = LA_BIND_BODYF_Z, std430) restrict readonly buffer BodyFZ { float bodyf_z[]; };
// The momentum riding a crossing, booked beside the mass leg.
layout(set = 0, binding = LA_BIND_FLUX_BND_MOM_X, std430) buffer BndMomX { float bnd_mom_x[]; };
layout(set = 0, binding = LA_BIND_FLUX_BND_MOM_Y, std430) buffer BndMomY { float bnd_mom_y[]; };
layout(set = 0, binding = LA_BIND_FLUX_BND_MOM_Z, std430) buffer BndMomZ { float bnd_mom_z[]; };
layout(set = 0, binding = LA_BIND_CO, std430) readonly buffer CoBuf { float co_gas[]; };
layout(set = 0, binding = LA_BIND_SO2, std430) readonly buffer So2Buf { float so2[]; };
layout(set = 0, binding = LA_BIND_H2S, std430) readonly buffer H2sBuf { float h2s[]; };
layout(set = 0, binding = LA_BIND_O2, std430) readonly buffer O2Buf { float o2_gas[]; };
layout(set = 0, binding = LA_BIND_N2, std430) readonly buffer N2Buf { float n2_gas[]; };
layout(set = 0, binding = LA_BIND_H2, std430) readonly buffer H2Buf { float h2_gas[]; };
layout(set = 0, binding = LA_BIND_GRAV_PHI, std430) restrict readonly buffer GravPhi { float grav_phi[]; };  // J/kg
layout(set = 0, binding = LA_BIND_GRAV_REF, std430) restrict readonly buffer GravRef { float grav_ref[]; };  // J/kg
layout(set = 0, binding = LA_BIND_PE_J_M3, std430) restrict buffer PotBuf { float pe_j_m3[]; };
layout(set = 0, binding = LA_BIND_LITHIC_FRAC, std430) restrict readonly buffer LithicFrac { float lithic_frac[]; };
layout(set = 0, binding = LA_BIND_LITHIC_KG, std430) restrict readonly buffer LithicKg { float lithic_kg[]; };  // the cell's own potential energy per volume
// The charge riding a crossing, C/m^3 per step.
layout(set = 0, binding = LA_BIND_FLUX_BND_Q, std430) buffer BndQ { float bnd_q[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // FluxPass.PASS_*
	uint mode;            // MODE_* — what this record's matter rides
	uint law;             // LAW_* — which drift closure sets its slip through the mixture
	uint band_count;
	uint flags;           // TF_*
	float dt_s;
	float repose_tan;     // 0 = a fluid, which levels freely
	float density;        // kg/m^3 of the substance this record carries
	float max_fill;       // mol/m^3 at which a cell is full of it; +inf for a row carrying no matter
	float grain_d;        // m, the row's own grain diameter where the cell declares none
	float sun_x;          // world-space vector toward the sun; its LENGTH carries relative insolation
	float sun_y;
	float sun_z;
	// J/m^3/K a unit of fill adds to the sensible entry; 0 for a substance on its own phase ladder.
	float sub_cap_j_m3k;
	uint total_count;     // interior cells plus ghost tail cells
	float xuv_w_m2;       // XUV irradiance AT THIS BODY, W/m^2 — LAW_ESCAPE's driver
	uint act_group;       // the row group whose activity counter and cell list this dispatch walks
	uint act_group2;      // a second group this row's crossings wake; ACT_NO_GROUP for none
	float phi_datum;      // J/kg: la_phi's zero against infinity
	float grav_self;      // share of rho*phi that is the cell's own potential energy: 0.5 self-gravitating, 1 in a body's field
} params;

// The seconds THIS invocation integrates: one field step, at the Courant number below.
float la_dt;

// FluxPass's PASS_* tags. 3-5 and 12-19 belong to active_cells.glsli; anything else is the apply.
const uint PASS_FLUX = 0u;
const uint PASS_GRAIN = 2u;
const uint PASS_SW = 6u;
const uint PASS_FACE = 7u;
const uint PASS_MOMENTUM = 8u;

#include "march.glsli"
#include "closures.glsli"
#include "active_cells.glsli"
#include "transport_radiate.glsli"



// The share of `amount` this row carries in cell `c`.
float row_share(uint c) {
	return (params.flags & TF_FRACTION) != 0u ? clamp(frac[c], 0.0, 1.0) : 1.0;
}

// This row's own matter in cell `c`, mol/m^3.
float row_amount(uint c) {
	return amount[c] * row_share(c);
}

// Heat per unit of THIS row's matter in cell `c`; a row moving one phase divides by that phase's amount.
float h_per_unit(uint c) {
	if (params.sub_cap_j_m3k > 0.0) {
		float cap = cap_sensible[c];
		return cap > 0.0 ? h_carried[c] * params.sub_cap_j_m3k / cap : 0.0;
	}
	float own = (params.flags & TF_FRACTION) != 0u ? row_amount(c) : amount[c];
	return own > 0.0 ? h_carried[c] / own : 0.0;
}

float face_gas_factor(uint c, uint d) {
	float m_gas = max(rho_fluid(c) - cond_kg_m3(c), 0.0);
	return m_gas > 0.0 ? face_layer(c, d).x / m_gas : 0.0;
}

// THE ENERGY A CROSSING CARRIES, J: the face enthalpy of the donor's layer. (rho E + p)* u* along the
// donor's isentrope is rho* u* h_face by Bernoulli, however much of it the interface turned into motion.
float carried_energy(uint donor, float cross_mean, float f_face) {
	return cross_mean * f_face * h_per_unit(donor);
}

// Charge per unit of THIS substance in cell `c`: the cell's charge shared out by mass, so a mole
// leaving takes the charge its mass was carrying.
float charge_per_unit(uint c) {
	float rb = rho_fluid(c);
	return rb > 0.0 ? sub_kg_mol() * charge[c] / rb : 0.0;
}

// The cell's own depth of this row's matter, m: its volume fraction times the cell edge.
float row_depth(uint c) {
	return params.max_fill > 0.0 ? (row_amount(c) / params.max_fill) * cell_edge[c] : 0.0;
}

// Drop of the row's free surface from c to n across face d, m: the geopotential read as an altitude
// with what stands on it. One gravity for the pair, so both sides read the same surface.
float surface_drop(uint c, uint n, uint d, float g_pair) {
	return (g_pair > 0.0 ? -la_dphi(c, n, d) / g_pair : 0.0) + row_depth(c) - row_depth(n);
}

// THE DRIFT VELOCITY of this row's phase through the mixture across the face, m/s, positive out of
// `c`. Every branch is a closure on the pair's own state, evaluated in a canonical orientation so the
// two sides of the face read exact negations of one number.
float drift_at(uint c, uint n, uint d, float dist) {
	uint lo = min(c, n);
	vec3 gv = g_at(lo);
	float gm = length(gv);
	// Down-gravity component of THIS cell's outward normal: + where the face faces downhill.
	float down = gm > 0.0 ? dot(gv / gm, face_normal(d)) : 0.0;
	if (params.law == LAW_DARCY) {
		float k = darcy_conductivity(lo, max(c, n));
		float rho_f = carrier_rho(lo);
		if (k <= 0.0 || gm <= 0.0 || rho_f <= 0.0) {
			return 0.0;
		}
		// Piezometric head, m: elevation, plus the pressure the fluid stands under where BOTH cells are
		// open. A locked cell's pressure is its lattice's stress; the water in its pores stands at
		// hydrostatic head. LA_APPROX: hydrostatic_pore_pressure
		float p_c = solid[c] == 0.0 ? max(pressure[c], 0.0) : 0.0;
		float p_n = solid[n] == 0.0 ? max(pressure[n], 0.0) : 0.0;
		bool both_open = solid[c] == 0.0 && solid[n] == 0.0;
		float dh = (-la_dphi(c, n, d) + (both_open ? (p_c - p_n) / rho_f : 0.0)) / gm;
		return k * dh / dist;
	}
	if (params.law == LAW_SHALLOW) {
		// Inviscid gravity adjustment: du/dt = -g d(h+z)/dx. A granular pile holds a slope up to its
		// angle of repose, so only the excess over it drives anything.
		float slope = surface_drop(c, n, d, gm) / dist;
		float excess = max(abs(slope) - params.repose_tan, 0.0) * sign(slope);
		return gm * la_dt * excess;
	}
	if (params.law == LAW_FILM) {
		// Nusselt falling film: u = rho g h^2 sin(theta) / (3 mu), mu climbing as the melt crystallises.
		float slope = surface_drop(c, n, d, gm) / dist;
		float hh = 0.5 * (row_depth(c) + row_depth(n));
		float mu = max(melt_viscosity(lo), 1.0e-12);
		return params.density * gm * hh * hh * slope / (3.0 * mu);
	}
	if ((params.flags & TF_SETTLE) != 0u) {
		return settling_speed(lo) * down;
	}
	return 0.0;
}

// The DIFFUSIVE crossing per face area this step, out of `c`: eddy mixing homogenises the MIXING
// RATIO, relaxed over the step at the rate the pair's masses set.
float diffusive_at(uint c, uint n, float dist, float open) {
	if (params.law == LAW_EDDY) {
		// The FLUID each side holds: the bulk less its lithic grains, which do not mix with a gas.
		float rc = rho_fluid(c);
		float rn = rho_fluid(n);
		if (rc <= 0.0 || rn <= 0.0) {
			return 0.0;
		}
		float kg_mol = sub_kg_mol();
		if (kg_mol <= 0.0) {
			return 0.0;
		}
		float yc = row_amount(c) * kg_mol / rc;
		float yn = row_amount(n) * kg_mol / rn;
		float rho_face = 0.5 * (rc + rn);
		float nu = 0.5 * (nu_t[c] + nu_t[n]);
		float k = rho_face * nu / dist;
		float rate = k * open * (la_face_div(c, int(n)) / rc + la_face_div(n, int(c)) / rn);
		float t_eff = rate * la_dt > 1.0e-6 ? (1.0 - exp(-rate * la_dt)) / rate : la_dt;
		return k * (yc - yn) * t_eff / kg_mol;
	}
	if (params.mode == MODE_CONDUCT) {
		// Series half-cells, so the interface conductivity is the harmonic mean of the two.
		float a = aux[c];
		float b = aux[n];
		float lam = 2.0 * a * b / max(a + b, 1.0e-12);
		return lam * (drive[c] - drive[n]) * la_dt / dist;
	}
	if (params.law == LAW_OHMIC) {
		// Ohmic relaxation of a space charge, carried between neighbours so the charge is conserved.
		float e_face = 0.5 * (column_field(c) + column_field(n));
		float sigma = 0.5 * (ohmic_conductivity_at(c, e_face) + ohmic_conductivity_at(n, e_face));
		float edge = 0.5 * (cell_edge[c] + cell_edge[n]);
		return sigma * edge * edge * (drive[c] - drive[n]) * la_dt / (EPS0 * dist);
	}
	return 0.0;
}



// Linear interpolation weight toward c across a face: the share of the centre distance on n's side.
float face_w(uint c, uint n) {
	float ec = cell_edge[c];
	float en = cell_edge[n];
	return (ec + en) > 0.0 ? en / (ec + en) : 0.5;
}

// Acoustic compliance, kg/Pa, over the Reuss average of the phases' bulk moduli (Wood 1930).
float acoustic_compliance(uint c) {
	float e = cell_edge[c];
	float v = e * e * e;
	float rho = rho_fluid(c);
	if (v <= 0.0 || rho <= 0.0 || solid[c] != 0.0 || collisionless(c)) {
		return 0.0;
	}
	float f_w = water_vol_frac(c);
	float f_s = clamp(max(lithic_frac[c], 0.0), 0.0, 1.0);
	float f_g = max(1.0 - f_w - f_s, 0.0);
	float k_gas = gas_gamma[c] * max(pressure[c], 0.0);
	float k_w = max(k_cond[c], 0.0);
	float compress = (k_gas > 0.0 ? f_g / k_gas : 0.0) + (k_w > 0.0 ? f_w / k_w : 0.0);
	return compress > 0.0 ? v * rho * compress : 0.0;
}

// LA_APPROX: implicit_acoustics
// PASS_FACE: one shared pressure and one predicted velocity per band per face, off the two cells'
// own hydrostatic reconstructions and this step's body impulse.
void face_states(uint c) {
	nu_t[c] = 0.0;
	w_top[c] = 1.0e30;
	hz_comp[c] = 0.0;
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		face_u[f] = 0.0;
		fp_star[f] = 0.0;
		face_uw[f] = 0.0;
		fpw_star[f] = 0.0;
		hz_flux[f] = 0.0;
		hz_cond[f] = 0.0;
	}
	if (solid[c] != 0.0 || collisionless(c)) {
		return;   // rock's pressure is PressurePass's column; a collisionless cell holds no fluid
	}
	nu_t[c] = eddy_viscosity(c);
	hz_comp[c] = acoustic_compliance(c);
	float top_c = water_top(c);
	w_top[c] = top_c;
	float rho_c = rho_fluid(c);
	// The velocity increment this step's body impulse gives the cell, m/s.
	vec3 acc_c = rho_c > 0.0 ? vec3(bodyf_x[c], bodyf_y[c], bodyf_z[c]) / rho_c : vec3(0.0);

	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		float pc = face_p(c, d);
		vec3 wc = water_face(c, d, top_c);
		fp_star[f] = pc;
		fpw_star[f] = wc.z;
		int inb = nbr[f];
		if (inb < 0) {
			inb = ghost[f];
		}
		float area = la_face_area(c, inb);
		float dist = la_face_dist(c, inb);
		// Vacuum: the exact rarefaction puts the SONIC state at the face, and the outside holds no
		// acoustic pressure, so the solve sees a Dirichlet zero across it.
		if (inb == GHOST_SPACE) {
			vec2 sonic = la_sonic_vacuum(pc, face_c(c, d), dot(vel_at(c), face_normal(d)), gas_gamma[c]);
			fp_star[f] = sonic.y;
			face_u[f] = sonic.x;
			float gs = max(1.0 - wc.x - wc.y, 0.0);
			hz_flux[f] = area * gs * face_layer(c, d).x * sonic.x;
			hz_cond[f] = dist > 0.0 ? area * gs / dist : 0.0;
			continue;
		}
		// A WALL STILL PUSHES: matter crosses neither a shut box edge nor rock, pressure does.
		// Beyond the exobase there is no fluid to push back: what goes up on a ballistic path comes down.
		if (inb < 0 || solid[uint(inb)] != 0.0 || collisionless(uint(inb)) || !listed(uint(inb))) {
			continue;
		}
		uint n = uint(inb);
		uint dn = opposite_slot(d);
		float pn = face_p(n, dn);
		vec3 wn = water_face(n, dn, water_top(n));
		// ONE SHARE PER BAND PER FACE, read the same from both sides: a band crosses only where both
		// cells present it.
		float wet = min(wc.x, wn.x);
		float gas = min(max(1.0 - wc.x - wc.y, 0.0), max(1.0 - wn.x - wn.y, 0.0));
		// Each side's own reconstruction interpolated to the face: equal from both sides in balance.
		float w_c = face_w(c, n);
		fp_star[f] = w_c * pc + (1.0 - w_c) * pn;
		fpw_star[f] = w_c * wc.z + (1.0 - w_c) * wn.z;
		vec3 nrm = face_normal(d);
		float rho_n = rho_fluid(n);
		vec3 acc_n = rho_n > 0.0 ? vec3(bodyf_x[n], bodyf_y[n], bodyf_z[n]) / rho_n : vec3(0.0);
		// The pair's own velocity plus this step's body impulse, interpolated onto the face.
		float u_mean = dot(w_c * (vel_at(c) + acc_c) + (1.0 - w_c) * (vel_at(n) + acc_n), nrm);
		float rho_g = 0.5 * (face_layer(c, d).x + face_layer(n, dn).x);
		float rho_w = 0.5 * (water_rho[c] + water_rho[n]);
		// THE IMBALANCE ACCELERATES THE BAND over the step, each band against its own density.
		float dpg = pn - pc;
		float dpw = wn.z - wc.z;
		face_u[f] = u_mean - (rho_g > 0.0 && dist > 0.0 ? params.dt_s * dpg / (dist * rho_g) : 0.0);
		face_uw[f] = u_mean - (rho_w > 0.0 && dist > 0.0 ? params.dt_s * dpw / (dist * rho_w) : 0.0);
		// kg/s through the face, and what one pascal of acoustic difference takes back; the density
		// cancels, so one coefficient serves both bands.
		hz_flux[f] = area * (gas * rho_g * face_u[f] + wet * rho_w * face_uw[f]);
		hz_cond[f] = dist > 0.0 ? area * (gas + wet) / dist : 0.0;
	}
}


// PASS_FLUX: what this record sends through each of `c`'s own faces, positive OUT. Every face is
// evaluated from the pair in one canonical orientation, so the entry the neighbour writes for the
// same face is the exact negation of this one and the books close by construction.
void row_flux(uint c) {
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		x_amt[f] = 0.0;
		x_h[f] = 0.0;
		x_q[f] = 0.0;
	}
	bool pores = params.law == LAW_DARCY;
	bool heat = params.mode == MODE_CONDUCT;
	if ((solid[c] != 0.0 || collisionless(c)) && !pores && !heat) {
		return;
	}
	float open_c = 1.0 - clamp(resist[c], 0.0, 1.0);
	bool carries = params.density > 0.0;
	bool rides = params.mode == MODE_ADVECT || params.mode == MODE_BOTH;
	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		int inb = nbr[f];
		if (inb < 0) {
			inb = ghost[f];
		}
		if (params.law == LAW_ESCAPE) {
			// THE BOX EDGE IS SPACE. Nothing else lets matter leave the world.
			if (inb != GHOST_SPACE) {
				continue;
			}
			float tail = 0.0;
			float cross = row_amount(c) * escape_speed(c, d, tail) * open_c * la_dt
				* la_face_div(c, nbr[f]);
			if (cross <= 0.0) {
				continue;
			}
			x_amt[f] = cross;
			x_h[f] = cross * (h_per_unit(c) + tail);
			x_q[f] = cross * charge_per_unit(c);
			continue;
		}
		bool water_row = (params.flags & TF_WATER) != 0u;
		if (inb == GHOST_SPACE && rides && carries && awake(c) && !water_row) {
			float u_out = max(face_u[f], 0.0);
			float cross_mean = row_amount(c) * u_out * open_c * la_dt * la_face_div(c, nbr[f]);
			float f_face = face_gas_factor(c, d);
			float cross = cross_mean * f_face;
			if (cross > 0.0) {
				x_amt[f] = cross;
				x_h[f] = carried_energy(c, cross_mean, f_face);
				x_q[f] = cross * charge_per_unit(c);
			}
			continue;
		}
		if (inb < 0) {
			continue;   // a shut wall, or a space face this record has no law for
		}
		uint n = uint(inb);
		// The solid mask stops MATTER. Heat is not matter, so conduction crosses rock both ways.
		if ((solid[n] != 0.0 || collisionless(n)) && !pores && !heat) {
			continue;
		}
		// A face runs on the COARSER of the pair's clocks, and a sleeping pair moves nothing.
		if (!listed(n) || (!awake(c) && !awake(n))) {
			continue;
		}
		float dist_f = la_face_dist(c, inb);
		float div_f = la_face_div(c, inb);
		// ONE OPENNESS PER FACE, read the same by both sides: the harder resistance of the pair.
		float open = min(open_c, 1.0 - clamp(resist[n], 0.0, 1.0));
		float u = rides ? (water_row ? face_uw[f] : face_u[f]) : 0.0;
		u += drift_at(c, n, d, dist_f);
		float cross_adv = 0.0;
		float cross_mean = 0.0;
		float f_face = 1.0;
		uint donor_adv = c;
		if (u != 0.0) {
			donor_adv = u > 0.0 ? c : n;
			uint dd = donor_adv == c ? d : opposite_slot(d);
			cross_mean = row_amount(donor_adv) * u * open * la_dt * div_f;
			if (water_row) {
				// The band crosses through its wet share of the face at the liquid's own concentration,
				// against its own interface pressure.
				vec3 wd = water_face(donor_adv, dd, w_top[donor_adv]);
				cross_mean = sign(u) * min(abs(cross_mean),
					full_h2o_at(donor_adv) * wd.x * abs(u) * open * la_dt * div_f);
			} else if (rides) {
				f_face = face_gas_factor(donor_adv, dd);
			}
			cross_adv = cross_mean * f_face;
		}
		float cross_diff = diffusive_at(c, n, dist_f, open) * open * div_f;
		float cross = cross_adv + cross_diff;
		if (cross == 0.0) {
			continue;
		}
		x_amt[f] = cross;
		if ((params.flags & TF_ENERGY) != 0u) {
			x_h[f] = cross;   // this record's amount IS the energy
		} else if (carries) {
			// Mixing carries the donor's own enthalpy; bulk flow carries the interface's flow work.
			uint donor_diff = cross_diff > 0.0 ? c : n;
			x_h[f] = carried_energy(donor_adv, cross_mean, f_face) + cross_diff * h_per_unit(donor_diff);
			uint donor = cross > 0.0 ? c : n;
			x_q[f] = cross * charge_per_unit(donor);
		}
	}
}


// PASS_APPLY: sum this record's own faces into the cell. A crossing carries the interface's momentum,
// the face velocity along its normal and the donor's across it; its energy is the face enthalpy, whose
// flow work is already that motion, so the kinetic merge trades only what one momentum cannot hold.
void row_apply(uint c) {
	bool pores = params.law == LAW_DARCY;
	bool heat = params.mode == MODE_CONDUCT;
	if ((solid[c] != 0.0 || collisionless(c)) && !pores && !heat) {
		return;
	}
	float kg_mol = sub_kg_mol();
	bool carries = params.density > 0.0;
	bool rides = params.mode == MODE_ADVECT || params.mode == MODE_BOTH;
	bool water_row = (params.flags & TF_WATER) != 0u;
	float d_amt = 0.0;
	float d_h = 0.0;
	float d_q = 0.0;
	vec3 d_m = vec3(0.0);
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		float cross = x_amt[f];
		float cross_h = x_h[f];
		float cross_q = x_q[f];
		if (cross == 0.0 && cross_h == 0.0) {
			continue;
		}
		int inb = nbr[f];
		bool edge = inb < 0;
		if (edge) {
			inb = ghost[f];
		}
		d_amt -= cross;
		d_h -= cross_h;
		d_q -= cross_q;
		vec3 vs = vec3(0.0);
		if (carries) {
			uint donor = cross > 0.0 ? c : uint(max(inb, 0));
			vs = vel_at(donor);
			if (rides) {
				vec3 nrm = face_normal(la_face_slot(c, f));
				float un = water_row ? face_uw[f] : face_u[f];
				vs += (un - dot(vs, nrm)) * nrm;
			}
			d_m -= cross * kg_mol * vs;
			// A parcel the potential carried DOWN arrives with what it lost as heat; nothing here gave
			// it motion instead. Only the receiving side books it, and only from an interior donor.
			if (params.mode == MODE_POTENTIAL && cross < 0.0 && inb >= 0
					&& uint(inb) < params.cell_count) {
				d_h += (-cross) * kg_mol * la_dphi(c, uint(inb), la_face_slot(c, f));
			}
		}
		// Exterior crossings book inflow-positive; a wrap partner is interior motion and books nothing.
		if (inb < 0 || uint(inb) >= params.cell_count) {
			bnd_amt[c] -= cross;
			// What leaves takes its potential energy at the donor's own specific value, the same one the
			// potential book weighs it at.
			uint pd = cross > 0.0 ? c : uint(max(inb, 0));
			float pe_kg = rho_bulk[pd] > 0.0 ? pe_j_m3[pd] / rho_bulk[pd] : 0.0;
			bnd_h[c] -= cross_h + cross * kg_mol * pe_kg;
			bnd_q[c] -= cross_q;
			if (carries) {
				vec3 bm = cross * kg_mol * vs;
				bnd_mom_x[c] -= bm.x;
				bnd_mom_y[c] -= bm.y;
				bnd_mom_z[c] -= bm.z;
			}
		}
	}
	float was = amount[c];
	amount[c] = was + d_amt;
	// What arrives is loose, so the cemented SHARE falls by exactly the ratio the total grew.
	if ((params.flags & TF_DILUTE) != 0u && amount[c] > was && was > 0.0) {
		cement[c] = clamp(cement[c] * was / amount[c], 0.0, 1.0);
	}
	if ((params.flags & TF_ENERGY) == 0u) {
		e[c] += d_h;
	}
	if (carries) {
		charge[c] += d_q;
		// MOTION IS BOOKED WITH THE MASS: the kinetic energy the merged momentum cannot hold is heat.
		float rb0 = rho_fluid(c);
		vec3 m0 = vec3(mom_x[c], mom_y[c], mom_z[c]);
		float ke0 = rb0 > 0.0 ? 0.5 * dot(m0, m0) / rb0 : 0.0;
		mom_x[c] += d_m.x;
		mom_y[c] += d_m.y;
		mom_z[c] += d_m.z;
		// The potential energy per volume follows the mass, so pe/rho stays the cell's own specific value.
		float pe_kg_c = rb0 > 0.0 ? pe_j_m3[c] / rb0 : 0.0;
		pe_j_m3[c] += d_amt * kg_mol * pe_kg_c;
		rho_bulk[c] += d_amt * kg_mol;
		float rb1 = rho_fluid(c);
		vec3 m1 = m0 + d_m;
		float ke1 = rb1 > 0.0 ? 0.5 * dot(m1, m1) / rb1 : 0.0;
		e[c] += ke0 - ke1;
		h_carried[c] += d_h;
		if (params.sub_cap_j_m3k > 0.0) {
			cap_sensible[c] += d_amt * params.sub_cap_j_m3k;
		}
	}
	if ((params.flags & TF_RADIOGENIC) != 0u) {
		// The rock warms itself, at this epoch's rate. This record's `amount` IS the lattice's energy.
		float dq = max(rad_w_m3[c], 0.0) * la_dt;
		amount[c] += dq;
		radiogenic[c] = dq;
		d_amt += dq;
	}
	// ACROSS THE GROUND: the lattice conducts into the fluid on it through one face over half its thickness.
	if ((params.flags & TF_LATTICE) != 0u) {
		float vl = lattice_frac[c];
		if (vl > 0.0 && vl < 1.0 && rho_fluid(c) > 0.0) {
			float L = cell_edge[c];
			float q = 2.0 * aux[c] * (drive[c] - temp[c]) * la_dt / (vl * L * L);
			amount[c] -= q;
			e[c] += q;
			d_amt -= q;
		}
	}
	// LA_APPROX: boundary_relaxation_zone
	if ((params.flags & TF_RELAX) != 0u && rim_w[c] > 0.0) {
		int rg = rim_ghost[c];
		if (rg >= int(params.cell_count) && rg < int(params.total_count)) {
			uint rgu = uint(rg);
			float dq = rim_w[c] * (amount[rgu] - amount[c]);
			if (dq != 0.0) {
				float dh = 0.0;
				if ((params.flags & TF_ENERGY) != 0u) {
					dh = dq;
				} else if (carries) {
					dh = dq * h_per_unit(dq > 0.0 ? rgu : c);
					e[c] += dh;
				}
				float held = amount[c];
				amount[c] = held + dq;
				if ((params.flags & TF_DILUTE) != 0u && dq > 0.0 && held > 0.0) {
					cement[c] = clamp(cement[c] * held / amount[c], 0.0, 1.0);
				}
				if (carries) {
					rho_bulk[c] += dq * kg_mol;
					h_carried[c] += dh;
					if (params.sub_cap_j_m3k > 0.0) {
						cap_sensible[c] += dq * params.sub_cap_j_m3k;
					}
				}
				bnd_amt[c] += dq;
				bnd_h[c] += dh;
				d_amt += dq;
			}
		}
	}
	// PROPAGATION: the bubble grows one cell per step, as fast as anything in it travels.
	if (d_amt != 0.0) {
		quiet[act_base() + c] = 0u;
		if (params.act_group2 != ACT_NO_GROUP) {
			quiet[params.act_group2 * params.total_count + c] = 0u;
		}
		for (uint f = f_lo; f < f_hi; ++f) {
			int wnb = nbr[f];
			if (wnb < 0) { wnb = ghost[f]; }
			if (wnb >= 0 && uint(wnb) < params.total_count) {
				quiet[act_base() + uint(wnb)] = 0u;
			}
		}
	}
}


// The acoustic pressure at a face, Pa: the cell's own where nothing pushes back, vacuum's zero at
// a face onto space, so a uniform correction over a closed cell is exactly no force.
float face_hz(uint c, int inb, uint f) {
	if (inb == GHOST_SPACE) {
		return 0.0;
	}
	if (inb < 0 || solid[uint(inb)] != 0.0 || collisionless(uint(inb)) || !listed(uint(inb))) {
		return hz_p[c];
	}
	uint n = uint(inb);
	float w_c = face_w(c, n);
	return w_c * hz_p[c] + (1.0 - w_c) * hz_p[n];
}


// PASS_MOMENTUM: the face pressures, the solved acoustic pressure on them, the viscous stress and
// this step's body impulse. At rest each is zero or cancels, so a column in balance stays in it.
void move_momentum(uint c) {
	if (solid[c] != 0.0 || collisionless(c)) {
		return;   // locked matter holds no bulk momentum, and a collisionless cell is no fluid
	}
	vec3 dm = vec3(0.0);
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		int inb = nbr[f];
		if (inb < 0) {
			inb = ghost[f];
		}
		float div_f = la_face_div(c, inb);
		float dist = la_face_dist(c, inb);
		// The six faces integrate to the cell's weight, so only the DEPARTURE is a net force, each
		// layer's over the share of the face it wets; the ground strip is a wall.
		vec3 wf = water_face(c, d, w_top[c]);
		float gas_share = max(1.0 - wf.x - wf.y, 0.0);
		float dp_hz = face_hz(c, inb, f) - hz_p[c];
		vec3 push = -((fp_star[f] - face_p(c, d)) * gas_share + (fpw_star[f] - wf.z) * wf.x
			+ dp_hz * (gas_share + wf.x)) * face_normal(d) * div_f * la_dt;
		dm += push;
		// A wall's push and a space face's loss are what the box exchanged with the outside.
		if (inb < 0 || uint(inb) >= params.cell_count) {
			bnd_mom_x[c] += push.x;
			bnd_mom_y[c] += push.y;
			bnd_mom_z[c] += push.z;
		}
		if (inb < 0) {
			continue;
		}
		uint n = uint(inb);
		if (solid[n] != 0.0 || collisionless(n) || !listed(n)) {
			continue;
		}
		// The projection corrects the face too: the records move the mass continuity just closed on.
		if (dist > 0.0) {
			uint dn = opposite_slot(d);
			float rho_g = 0.5 * (face_layer(c, d).x + face_layer(n, dn).x);
			float rho_w = 0.5 * (water_rho[c] + water_rho[n]);
			float grad = (hz_p[n] - hz_p[c]) / dist;
			if (rho_g > 0.0) { face_u[f] -= la_dt * grad / rho_g; }
			if (rho_w > 0.0) { face_uw[f] -= la_dt * grad / rho_w; }
		}
		// mu grad(v) across the face, one viscosity for the pair, integrated EXACTLY over the step: the
		// velocity difference decays at the rate the two masses set.
		float nu = n < params.cell_count ? 0.5 * (nu_t[c] + nu_t[n]) : nu_t[c];
		float rc = rho_fluid(c);
		float rn = rho_fluid(n);
		float mu = 0.5 * (rc + rn) * nu;
		float k_c = mu * div_f / dist;
		float k_n = mu * la_face_div(n, int(c)) / dist;
		float rate = (rc > 0.0 ? k_c / rc : 0.0) + (rn > 0.0 ? k_n / rn : 0.0);
		float t_eff = rate * la_dt > 1.0e-6 ? (1.0 - exp(-rate * la_dt)) / rate : la_dt;
		dm += k_c * (vel_at(n) - vel_at(c)) * t_eff;
	}
	// The body impulse the stack does not already carry; state_derive booked the weight leg out.
	vec3 v_old = vel_at(c);
	mom_x[c] += dm.x + bodyf_x[c];
	mom_y[c] += dm.y + bodyf_y[c];
	mom_z[c] += dm.z + bodyf_z[c];
	// v = p/rho off the momentum this pass settled, so the records read the new field.
	float rb = rho_fluid(c);
	vec3 v = rb > 0.0 ? vec3(mom_x[c], mom_y[c], mom_z[c]) / rb : vec3(0.0);
	// The pressure's work on the cell's motion comes out of e; the weight's share is the potential book's.
	vec3 gv = g_at(c);
	vec3 fg = (max(pressure[c], 0.0) > 0.0 && length(gv) > 0.0) ? rb * gv * la_dt : vec3(0.0);
	e[c] -= dot(0.5 * (v_old + v), dm - fg);
	vel_x[c] = v.x;
	vel_y[c] = v.y;
	vel_z[c] = v.z;
	speed[c] = length(v);
	if (dm != vec3(0.0)) {
		quiet[act_base() + c] = 0u;
	}
}


// SEPARATION: the riming pair keeps the light phase's charge and sends the heavy phase's down. Each
// cell writes only itself: what it separates, and what the cell above it sent down onto it.
void separate_charge(uint c) {
	vec3 gv = g_at(c);
	float gm = length(gv);
	if (gm <= 0.0) {
		return;
	}
	vec3 up = -gv / gm;
	float dq = 0.0;
	int down = la_slot_toward(-up);
	int over = la_slot_toward(up);
	if (down >= 0) {
		int below = nbr[la_slot_lo(c, uint(down))];
		// A charge with nowhere to go is not a separated charge.
		if (below >= 0 && solid[below] == 0.0) {
			dq = separation_dq(c, up, la_dt);
		}
	}
	if (over >= 0) {
		int above = nbr[la_slot_lo(c, uint(over))];
		if (above >= 0 && uint(above) < params.cell_count && solid[c] == 0.0) {
			vec3 ga = g_at(uint(above));
			float gam = length(ga);
			if (gam > 0.0) {
				dq -= separation_dq(uint(above), -ga / gam, la_dt) * vol_ratio(uint(above), c);
			}
		}
	}
	if (dq != 0.0) {
		charge[c] += dq;
		quiet[act_base() + c] = 0u;
	}
}


// PASS_GRAIN: a cell's loose grains — in water, in air, or on the bed. Shares sum to
// (1 - melt) * (1 - cement); runs before any record moves, and reads neighbour velocity.
void grain_state(uint g) {
	float loose = (1.0 - clamp(silicate_melt[g], 0.0, 1.0)) * (1.0 - clamp(cement[g], 0.0, 1.0));
	if (loose <= 0.0) {
		silicate_susp_water[g] = 0.0;
		silicate_susp_air[g] = 0.0;
		silicate_bed[g] = 0.0;
		return;
	}
	vec2 sh = pore_shares(g);

	float in_water = sh.x * suspended_share(g, water_rho[g], water_visc(g));
	float in_air = sh.y * suspended_share(g, air_rho(g), air_visc(g));

	silicate_susp_water[g] = loose * in_water;
	silicate_susp_air[g] = loose * in_air;
	silicate_bed[g] = loose * clamp(1.0 - in_water - in_air, 0.0, 1.0);
}



// Seconds this record's stability affords this cell: the Courant number over every face's outflow
// summed. The acoustic signal is absent — the Helmholtz solve carries it. INF where nothing binds.
float la_row_dt(uint c) {
	float L = cell_edge[c];
	bool heat = params.mode == MODE_CONDUCT;
	// Heat is not matter: it crosses rock, and a ballistic cell still holds a lattice that conducts.
	if (no_matter(c) || L <= 0.0 || (collisionless(c) && !heat)) {
		return 1.0 / 0.0;
	}
	float rate = 0.0;                      // 1/s: the fastest thing this row does to this cell
	vec3 vc = vel_at(c);
	if ((params.flags & TF_VEL) != 0u && solid[c] == 0.0) {
		float f_w = water_vol_frac(c);
		float top = f_w > 0.0 ? water_top(c) : 1.0e30;
		float w = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			float vn = max(dot(vc, face_normal(d)), 0.0);
			// The band drains by the face's wet share over its own, and only through a face it can CROSS.
			bool crossable = false;
			bool to_space = false;
			for (uint f = la_slot_lo(c, d); f < la_slot_hi(c, d); ++f) {
				int nb = nbr[f];
				if (nb < 0) {
					nb = ghost[f];
				}
				if (nb == GHOST_SPACE) {
					crossable = true;
					to_space = true;
				} else if (nb >= 0 && (uint(nb) >= params.cell_count
						|| (solid[nb] == 0.0 && !collisionless(uint(nb))))) {
					crossable = true;
				}
			}
			// A face onto vacuum is still explicit, so the layer's own signal speed stays in the bound.
			float gas = (vn + (to_space ? face_c(c, d) : 0.0)) * max(face_gas_factor(c, d), 1.0);
			float wet = (f_w > 0.0 && crossable) ? water_face(c, d, top).x : 0.0;
			float water = (vn + (to_space ? water_c(c) : 0.0))
				* max(f_w > 0.0 ? wet / f_w : 0.0, 1.0);
			w += max(gas, water);
		}
		rate = w / L;
	}
	float v = 0.0;
	if (params.mode == MODE_ADVECT || params.mode == MODE_BOTH) {
		v = abs(vc.x) + abs(vc.y) + abs(vc.z);
	}
	if ((params.flags & TF_SETTLE) != 0u) {
		v += settling_speed_max(c);
	}
	if (params.law == LAW_ESCAPE) {
		float tail = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			v = max(v, escape_speed(c, d, tail));
		}
	}
	rate = max(rate, v / L);
	// Eddy mixing relaxes each pair exactly and asks no step; conduction still marches.
	if (heat) {
		bool lattice_row = (params.flags & TF_LATTICE) != 0u;
		float cap = lattice_row ? cap_lith[c] : cap_sensible[c];
		if (cap > 0.0) {
			rate += 6.0 * max(aux[c], 0.0) / (cap * L * L);
		}
		// The ground exchange drains whichever reservoir is the smaller.
		float vl = lattice_frac[c];
		if (lattice_row && vl > 0.0 && vl < 1.0) {
			float small = min(cap_lith[c] > 0.0 ? cap_lith[c] : 1.0e30, cap_sensible[c] > 0.0 ? cap_sensible[c] : 1.0e30);
			if (small < 1.0e30) {
				rate += 2.0 * max(aux[c], 0.0) / (vl * small * L * L);
			}
		}
	}
	float dt = rate > 0.0 ? LA_COURANT_LIMIT / rate : 1.0 / 0.0;
	// A body released from rest crosses L in sqrt(2 L / |a|); locked matter does not fall.
	float gm = solid[c] == 0.0 ? length(g_at(c)) : 0.0;
	if (gm > 0.0) {
		dt = min(dt, sqrt(2.0 * LA_COURANT_LIMIT * L / gm));
	}
	// NO SIGNAL CROSSES A CELL FASTER THAN LIGHT: a state asking for less is not a timestep.
	return max(dt, L / C_LIGHT);
}

// A RECORD THE FIELD DOES NOT DRIVE CANNOT BE MEASURED ASLEEP BY THE FIELD. The escape law's push is
// the star's XUV and the zenith angle it arrives at, and both change while every cell stands still.
bool la_outside_driven(uint c) {
	if (params.law != LAW_ESCAPE) {
		return false;
	}
	for (uint f = la_face_lo(c); f < la_face_hi(c); ++f) {
		if (ghost[f] == GHOST_SPACE) {
			return true;
		}
	}
	return false;
}



void radiate_emit(uint c) {
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		send[f] = 0.0;
	}
	vec2 eps2 = longwave_emissivity_parts(c);
	float eps = eps2.x + eps2.y;
	lw_emis[c] = eps;
	sw_absorbed[c] = shortwave_absorbed_frac(c, solar_step_m(c));
	// Share of an upwelling flux this cell keeps as heat over one vertical step.
	vec3 gsw = g_at(c);
	float edge = cell_edge[c];
	float up_len = length(gsw) > 0.0 ? la_step_len(-normalize(gsw), edge) : edge;
	sw_keep[c] = shortwave_absorbed_frac(c, up_len) * (1.0 - shortwave_albedo(c));
	// Each reservoir radiates at its own temperature: the fluid and its condensate, the bare lattice.
	float leaving = radiated_by(c, eps2) * la_dt;
	for (uint f = f_lo; f < f_hi; ++f) {
		send[f] = leaving * la_face_div(c, nbr[f]);
	}
}

void radiate_gather(uint c) {
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	float absorptivity = lw_emis[c];
	float gained = 0.0;
	float lost = 0.0;
	float div_sum = 0.0;
	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		lost += send[f];
		div_sum += la_face_div(c, nbr[f]);
		if (nbr[f] < 0) {
			continue;   // nobody gathers at the box edge and it leaves for space
		}
		// LA_APPROX: six_ray_longwave_gather
		gained += absorptivity * longwave_incident(c, f, d);
	}
	float sun_w = solar_incident(c);
	float intercepted = sun_w * sw_absorbed[c];
	float albedo = shortwave_albedo(c);
	gained += intercepted * (1.0 - albedo) * la_dt / cell_edge[c];
	rad_absorbed[c] = gained;
	rad_emitted[c] = lost;
	// What the beam march removed and this cell did not keep: PASS_SW carries it back out.
	sw_src[c] = intercepted * albedo;
	// Stefan-Boltzmann against the published emission: every face of each reservoir's e*sigma*T^4.
	vec2 eps2 = longwave_emissivity_parts(c);
	float sb = radiated_by(c, eps2) * la_dt * div_sum;
	rad_residual[c] = abs(lost - sb) / max(sb, 1.0e-30);
	// The lattice's share of what was exchanged is its share of the emissivity; `amount` is the fluid's
	// energy and `e` the lattice's on this record.
	float share_l = (eps2.x + eps2.y) > 0.0 ? eps2.y / (eps2.x + eps2.y) : 0.0;
	float net = gained - lost;
	amount[c] += net * (1.0 - share_l);
	e[c] += net * share_l;
	if (gained != lost) {
		quiet[act_base() + c] = 0u;
	}
}


// THE ELECTRIC DETECTORS, off the one pre-drain state the OHMIC closure acts on.
void field_detect(uint c) {
	float e_here = column_field(c);
	float thr = rrea_threshold(c);
	col_e[c] = e_here;
	strike[c] = (thr > 0.0 && e_here >= thr) ? 1.0 : 0.0;
}


void main() {
	uint gidx = gl_GlobalInvocationID.x;
	la_dt = params.dt_s;
	// pass_id is a push constant, so each branch here is uniform and APPEND's barriers are legal.
	if (la_active_cells(gidx)) {
		return;
	}
	// EVERY PASS PAST HERE WALKS THIS GROUP'S ACTIVE LIST, never the box. O(active), not O(cells).
	if (gidx >= act_listed()) {
		return;
	}
	gidx = act_idx[act_base() + gidx];
	// A ghost tail cell holds a prescribed state: the interior cell beside it reads that state and
	// states the face itself, so nothing here ever dispatches over one.
	if (gidx >= params.cell_count) {
		return;
	}
	if (params.pass_id == PASS_FACE) {
		face_states(gidx);
		return;
	}
	if (params.pass_id == PASS_MOMENTUM) {
		move_momentum(gidx);
		return;
	}
	if (params.pass_id == PASS_GRAIN) {
		grain_state(gidx);
		return;
	}
	if (params.pass_id == PASS_SW) {
		sw_scatter(gidx);
		return;
	}
	if (params.pass_id == PASS_FLUX) {
		if ((params.flags & TF_EFIELD) != 0u) {
			field_detect(gidx);
		}
		if (params.mode == MODE_RADIATE) {
			radiate_emit(gidx);
			return;
		}
		if (params.mode != MODE_SEPARATE) {
			row_flux(gidx);
		}
		return;
	}
	if (params.mode == MODE_RADIATE) {
		radiate_gather(gidx);
		return;
	}
	if (params.mode == MODE_SEPARATE) {
		separate_charge(gidx);
		return;
	}
	row_apply(gidx);
}
