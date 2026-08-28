#[compute]
#version 450

// ONE CONSERVATIVE FACE FLUX. Every face states one interface pressure and one interface velocity,
// solved once from the pair; mass, momentum, enthalpy and charge ride it. Each side reconstructs its
// own face state from its own hydrostatic profile, so a column in balance produces zero flux.

#include "cellvol.glsli"
#include "neighbours.glsli"
#include "generated.glsli"
#include "stack.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) buffer Amount   { float amount[]; };
layout(set = 0, binding = 1, std430) restrict buffer Enthalpy { float h[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity per cell, flat cell*3, m/s^2, the rotating frame's terms already in it.
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };

layout(set = 0, binding = 5, std430) restrict buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict buffer VelZ { float vel_z[]; };
// THE FACE STATE, indexed by FACE: the interface velocity along the owning cell's outward normal and
// the interface pressure. LAVoxelGrid.slot_off says where a cell's own faces begin.
layout(set = 0, binding = 8, std430) restrict buffer FaceU { float face_u[]; };
layout(set = 0, binding = 9, std430) restrict buffer FaceP { float fp_star[]; };
// Charge rides the mass, exactly as enthalpy does: it is carried, never created by a move.
layout(set = 0, binding = 13, std430) buffer Charge { float charge[]; };
// The RADIATE march's own per-face scratch: what each face emits, J/m^3.
layout(set = 0, binding = 14, std430) restrict buffer Send { float send[]; };
// Flow resistance 0..1 per cell.
layout(set = 0, binding = 10, std430) restrict readonly buffer Resist { float resist[]; };
// What a potential-driven row runs down; `amount` when a record names none. No `restrict`: the
// conduction row binds temperature here and reads it under another name too.
layout(set = 0, binding = 11, std430) readonly buffer Drive { float drive[]; };
// Whatever else the row's law reads per cell: conductivity for MODE_CONDUCT, cloud water for LAW_OHMIC.
layout(set = 0, binding = 12, std430) restrict readonly buffer Aux { float aux[]; };

layout(set = 0, binding = 15, std430) restrict readonly buffer TempBuf     { float temp[]; };
// READ ONLY. An open cell's pressure is state_derive.glsl's equation of state and nothing else's.
layout(set = 0, binding = 16, std430) readonly buffer PressureBuf { float pressure[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer PorosityBuf { float porosity[]; };
layout(set = 0, binding = 18, std430) restrict readonly buffer GrainBuf    { float grain[]; };
layout(set = 0, binding = 19, std430) readonly buffer CO2Buf      { float co2[]; };
// ONE H2O CHANNEL plus the three DERIVED shares state_derive.glsl publishes; they differ optically.
layout(set = 0, binding = 20, std430) readonly buffer H2OBuf       { float h2o[]; };
// LAAbsorptionBands.packed(), the band table.
layout(set = 0, binding = 21, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer H2OSolidBuf  { float h2o_solid[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer H2OLiquidBuf { float h2o_liquid[]; };
layout(set = 0, binding = 24, std430) readonly buffer SilicateBuf { float silicate[]; };
layout(set = 0, binding = 25, std430) restrict readonly buffer BiomassBuf  { float biomass[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer SilicateMeltBuf { float silicate_melt[]; };
// Boundary redirect per face: a wrapped interior cell, a prescribed ghost tail cell, or -1 = shut wall.
layout(set = 0, binding = 27, std430) restrict readonly buffer Ghost { int ghost[]; };
layout(set = 0, binding = 28, std430) restrict readonly buffer H2OVapourBuf { float h2o_vapour[]; };
// TF_FRACTION records move only this share of `amount`, 0..1. No `restrict`: the grain prologue
// writes the very buffers three silicate records bind as their `frac`.
layout(set = 0, binding = 29, std430) readonly buffer FracBuf { float frac[]; };
// Consolidated share of the cell's silicate. A TF_DILUTE row rescales it when matter arrives.
layout(set = 0, binding = 30, std430) restrict buffer CementBuf { float cement[]; };
// Where the cell's loose mineral grains are, written by the PASS_GRAIN prologue.
layout(set = 0, binding = 31, std430) writeonly buffer SuspWater { float silicate_susp_water[]; };
layout(set = 0, binding = 32, std430) writeonly buffer SuspAir { float silicate_susp_air[]; };
layout(set = 0, binding = 33, std430) writeonly buffer Bed { float silicate_bed[]; };
// MODE_RADIATE's own books, J/m^3, assigned in the gather so each is a per-step rate needing no clear.
layout(set = 0, binding = 37, std430) restrict buffer RadAbs { float rad_absorbed[]; };
layout(set = 0, binding = 38, std430) restrict writeonly buffer RadEmit { float rad_emitted[]; };
// The column field and the breakdown it decides, published rather than re-derived on the CPU.
layout(set = 0, binding = 39, std430) restrict writeonly buffer ColE { float col_e[]; };
layout(set = 0, binding = 40, std430) restrict writeonly buffer Strike { float strike[]; };
layout(set = 0, binding = 41, std430) restrict readonly buffer RadW { float rad_w_m3[]; };  // W/m^3
// The greenhouse trace gases the band table resolves, mol/m^3.
layout(set = 0, binding = 42, std430) readonly buffer Ch4Buf { float ch4[]; };
layout(set = 0, binding = 43, std430) restrict writeonly buffer Radiogenic { float radiogenic[]; };
layout(set = 0, binding = 44, std430) restrict buffer LwEmis { float lw_emis[]; };
layout(set = 0, binding = 45, std430) restrict buffer SwAbs { float sw_absorbed[]; };
// Heat of the entry this row's substance sits in, and that entry's capacity, J/m^3 and J/m^3/K.
layout(set = 0, binding = 46, std430) restrict buffer HCarried { float h_carried[]; };
layout(set = 0, binding = 47, std430) restrict buffer CapSensible { float cap_sensible[]; };
// What crossed an OPEN box edge this step, per interior cell: amount in, joules riding along.
layout(set = 0, binding = 48, std430) restrict buffer BndAmt { float bnd_amt[]; };
layout(set = 0, binding = 49, std430) restrict buffer BndH { float bnd_h[]; };
// The REPLAY relaxation rim: the driving ghost cell and the per-step nudge fraction; 0 = outside it.
layout(set = 0, binding = 50, std430) restrict readonly buffer RimGhost { int rim_ghost[]; };
layout(set = 0, binding = 51, std430) restrict readonly buffer RimW { float rim_w[]; };
// The reflected-shortwave field: what a cell keeps, its reflected source W/m^2, what escapes.
layout(set = 0, binding = 52, std430) restrict buffer SwKeep { float sw_keep[]; };
layout(set = 0, binding = 53, std430) restrict buffer SwSrc { float sw_src[]; };
layout(set = 0, binding = 54, std430) restrict writeonly buffer SwSpace { float sw_space[]; };
layout(set = 0, binding = 55, std430) restrict writeonly buffer RadResid { float rad_residual[]; };
// O3 partial density, kg/m^3. Zeros until a photochemical o3 channel exists to swap in.
layout(set = 0, binding = 56, std430) restrict readonly buffer O3Buf { float o3[]; };
// Mass density per cell, kg/m^3, written by every mass row's own delta.
layout(set = 0, binding = 57, std430) restrict buffer RhoBulk { float rho_bulk[]; };
// MASS MOVES WITH ITS MOMENTUM. No `restrict`: a record's own channel may be one of these three.
layout(set = 0, binding = 58, std430) buffer MomX { float mom_x[]; };
layout(set = 0, binding = 59, std430) buffer MomY { float mom_y[]; };
layout(set = 0, binding = 60, std430) buffer MomZ { float mom_z[]; };
// The mixture's own kinematic eddy viscosity, m^2/s, stated once per cell so both sides of a face
// read one number and the viscous flux is antisymmetric.
layout(set = 0, binding = 61, std430) restrict buffer NuT { float nu_t[]; };
// THIS RECORD'S FLUX THROUGH EACH FACE, positive OUT of the cell that owns it: matter, the heat
// riding it, the charge riding it. Read in one canonical order, so a face's two entries negate.
layout(set = 0, binding = 62, std430) restrict buffer XAmt { float x_amt[]; };
layout(set = 0, binding = 63, std430) restrict buffer XH { float x_h[]; };
layout(set = 0, binding = 90, std430) restrict buffer XQ { float x_q[]; };
// The mixture's own sound speed, m/s, off the layer each face presents.
layout(set = 0, binding = 64, std430) restrict buffer CelerityBuf { float cel_m_s[]; };
layout(set = 0, binding = 89, std430) restrict readonly buffer KCondBuf { float k_cond[]; };
// |v| refreshed by the momentum pass, so the drained CFL peak is next step's read.
layout(set = 0, binding = 65, std430) restrict buffer SpeedBuf { float speed[]; };
// The step's body impulse per cell, kg/(m^2 s), booked by state_derive.
layout(set = 0, binding = 66, std430) restrict readonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = 67, std430) restrict readonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = 68, std430) restrict readonly buffer BodyFZ { float bodyf_z[]; };
// The momentum riding a crossing, booked beside the mass leg.
layout(set = 0, binding = 69, std430) buffer BndMomX { float bnd_mom_x[]; };
layout(set = 0, binding = 70, std430) buffer BndMomY { float bnd_mom_y[]; };
layout(set = 0, binding = 71, std430) buffer BndMomZ { float bnd_mom_z[]; };
layout(set = 0, binding = 72, std430) readonly buffer CoBuf { float co_gas[]; };
layout(set = 0, binding = 73, std430) readonly buffer So2Buf { float so2[]; };
layout(set = 0, binding = 74, std430) readonly buffer H2sBuf { float h2s[]; };
layout(set = 0, binding = 75, std430) readonly buffer O2Buf { float o2_gas[]; };
layout(set = 0, binding = 76, std430) readonly buffer N2Buf { float n2_gas[]; };
layout(set = 0, binding = 77, std430) readonly buffer H2Buf { float h2_gas[]; };
layout(set = 0, binding = 78, std430) restrict readonly buffer GravPhi { float grav_phi[]; };  // J/kg
layout(set = 0, binding = 95, std430) restrict readonly buffer GravRef { float grav_ref[]; };  // J/kg
layout(set = 0, binding = 91, std430) restrict buffer PotBuf { float pe_j_m3[]; };  // the cell's own potential energy per volume
// The charge riding a crossing, C/m^3 per step.
layout(set = 0, binding = 79, std430) buffer BndQ { float bnd_q[]; };

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
	float fluid_rho;      // kg/m^3 of the fluid the row moves THROUGH
	float fluid_visc;     // Pa s of that fluid
	float grain_d;        // m, the row's own grain diameter where the cell declares none
	float sun_x;          // world-space vector toward the sun; its LENGTH carries relative insolation
	float sun_y;
	float sun_z;
	float rho_water;      // LAPhysical.WATER_DENSITY_KG_M3
	float mu_water;       // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
	float rho_air;        // LAPhysical.AIR_DENSITY_KG_M3
	float mu_air;         // LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S
	// J/m^3/K a unit of fill adds to the sensible entry; 0 for a substance on its own phase ladder.
	float sub_cap_j_m3k;
	uint total_count;     // interior cells plus ghost tail cells
	float xuv_w_m2;       // XUV irradiance AT THIS BODY, W/m^2 — LAW_ESCAPE's driver
	uint level;           // the coarsest temporal level advancing on this substep; PEAK: the group slot
	uint substep_k;       // this substep's index on the finest level's axis
	uint substep_n;       // substeps the finest level takes across the field step, 2^levels
	uint act_group;       // the row group whose activity counter and cell list this dispatch walks
	uint act_group2;      // a second group this row's crossings wake; ACT_NO_GROUP for none
	float phi_datum;      // J/kg: la_phi's zero against infinity
	float grav_self;      // share of rho*phi that is the cell's own potential energy: 0.5 self-gravitating, 1 in a body's field
} params;

// The seconds THIS invocation integrates. A cell's own is dt/2^tlevel.
float la_dt;

// FluxPass's PASS_* tags. 3-5 and 9-19 belong to active_levels.glsli; anything else is the apply.
const uint PASS_FLUX = 0u;
const uint PASS_GRAIN = 2u;
const uint PASS_SW = 6u;
const uint PASS_FACE = 7u;
const uint PASS_MOMENTUM = 8u;

#include "march.glsli"
#include "closures.glsli"
#include "active_levels.glsli"
#include "transport_radiate.glsli"



// The share of `amount` this row carries in cell `c`.
float row_share(uint c) {
	return (params.flags & TF_FRACTION) != 0u ? clamp(frac[c], 0.0, 1.0) : 1.0;
}

// This row's own matter in cell `c`, mol/m^3.
float row_amount(uint c) {
	return amount[c] * row_share(c);
}

// Heat per unit of THIS substance in cell `c`: its share of the mixture entry its heat sits in.
float h_per_unit(uint c) {
	if (params.sub_cap_j_m3k > 0.0) {
		float cap = cap_sensible[c];
		return cap > 0.0 ? h_carried[c] * params.sub_cap_j_m3k / cap : 0.0;
	}
	return amount[c] > 0.0 ? h_carried[c] / amount[c] : 0.0;
}

// Charge per unit of THIS substance in cell `c`: the cell's charge shared out by mass, so a mole
// leaving takes the charge its mass was carrying.
float charge_per_unit(uint c) {
	float rb = rho_bulk[c];
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
		if (k <= 0.0 || gm <= 0.0 || params.fluid_rho <= 0.0) {
			return 0.0;
		}
		// Piezometric head, m: elevation plus the pore pressure the fluid stands under.
		float dh = (-la_dphi(c, n, d) + (max(pressure[c], 0.0) - max(pressure[n], 0.0)) / params.fluid_rho) / gm;
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

// The DIFFUSIVE flux across the face, in this row's own units per m^2 per second, positive out of
// `c`. Turbulent mixing homogenises the MIXING RATIO, so a stratified column at rest carries none.
float diffusive_at(uint c, uint n, float dist) {
	if (params.law == LAW_EDDY) {
		float rc = max(rho_bulk[c], 0.0);
		float rn = max(rho_bulk[n], 0.0);
		if (rc <= 0.0 || rn <= 0.0) {
			return 0.0;
		}
		float kg_mol = sub_kg_mol();
		if (kg_mol <= 0.0) {
			return 0.0;
		}
		// Mass fraction of this row's matter in each cell, and the eddy diffusivity of the pair.
		float yc = row_amount(c) * kg_mol / rc;
		float yn = row_amount(n) * kg_mol / rn;
		float rho_face = 0.5 * (rc + rn);
		float nu = 0.5 * (nu_t[c] + nu_t[n]);
		return rho_face * nu * (yc - yn) / (dist * kg_mol);
	}
	if (params.mode == MODE_CONDUCT) {
		// Series half-cells, so the interface conductivity is the harmonic mean of the two.
		float a = aux[c];
		float b = aux[n];
		float lam = 2.0 * a * b / max(a + b, 1.0e-12);
		return lam * (drive[c] - drive[n]) / dist;
	}
	if (params.law == LAW_OHMIC) {
		// Ohmic relaxation of a space charge, carried between neighbours so the charge is conserved.
		float e_face = 0.5 * (column_field(c) + column_field(n));
		float sigma = 0.5 * (ohmic_conductivity_at(c, e_face) + ohmic_conductivity_at(n, e_face));
		float edge = 0.5 * (cell_edge[c] + cell_edge[n]);
		return sigma * edge * edge * (drive[c] - drive[n]) / (EPS0 * dist);
	}
	return 0.0;
}



// PASS_FACE: one interface pressure and one interface velocity per face, from the two cells' own
// hydrostatic reconstructions. A column in balance presents the same pressure from both sides, so the
// velocity is zero and every cell keeps exactly its own weight.
void face_states(uint c) {
	nu_t[c] = 0.0;
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		face_u[f] = 0.0;
		fp_star[f] = 0.0;
	}
	if (solid[c] != 0.0) {
		return;   // rock's pressure is PressurePass's column and never reaches the momentum equation
	}
	float fc = condensed_frac(c);
	float mu_mol = mix(params.mu_air, params.mu_water, fc);
	float rb = max(rho_bulk[c], 0.0);
	float mixl = SMAGORINSKY_COEFF * cell_edge[c];
	nu_t[c] = (rb > 0.0 ? mu_mol / rb : 0.0) + mixl * mixl * strain_rate(c);

	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		float pc = face_p(c, d);
		float zc = impedance(c, d);
		int inb = nbr[f];
		if (inb < 0) {
			inb = ghost[f];
		}
		// A FACE ONTO SPACE meets vacuum: p* is zero and the layer free-expands outward at u + p/Z.
		if (inb == GHOST_SPACE) {
			fp_star[f] = 0.0;
			face_u[f] = zc > 0.0 ? max(dot(vel_at(c), face_normal(d)) + pc / zc, 0.0) : 0.0;
			continue;
		}
		// A WALL STILL PUSHES: matter crosses neither a shut box edge nor rock, pressure does.
		if (inb < 0 || solid[uint(inb)] != 0.0) {
			fp_star[f] = pc;
			continue;
		}
		uint n = uint(inb);
		// A neighbour coarser than this substep, or not in its list, is not stepping now: its wall
		// stands, nothing crosses.
		if (tlevel[n] < params.level || !listed(n)) {
			fp_star[f] = pc;
			continue;
		}
		uint dn = opposite_slot(d);
		float pn = face_p(n, dn);
		float zn = impedance(n, dn);
		// CANONICAL ORIENTATION, the lower cell index left: both sides evaluate the same expression on
		// the same operands, so the interface velocity one side reads is the exact negation of the other's.
		bool c_lo = c < n;
		vec3 nrm = c_lo ? face_normal(d) : face_normal(dn);
		float p_l = c_lo ? pc : pn;
		float p_r = c_lo ? pn : pc;
		float z_l = c_lo ? zc : zn;
		float z_r = c_lo ? zn : zc;
		float u_l = dot(vel_at(c_lo ? c : n), nrm);
		float u_r = dot(vel_at(c_lo ? n : c), nrm);
		float zs = z_l + z_r;
		if (!(zs > 0.0)) {
			continue;   // nothing on either side carries a signal, so the face states nothing
		}
		// LA_APPROX: acoustic_face_pressure
		fp_star[f] = (z_r * p_l + z_l * p_r + z_l * z_r * (u_l - u_r)) / zs;
		float us = (z_l * u_l + z_r * u_r + (p_l - p_r)) / zs;
		face_u[f] = c_lo ? us : -us;
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
	if (solid[c] != 0.0 && !pores && !heat) {
		return;
	}
	float open_c = 1.0 - clamp(resist[c], 0.0, 1.0);
	bool carries = params.density > 0.0;
	bool rides = params.mode == MODE_ADVECT || params.mode == MODE_BOTH;
	uint lv_c = tlevel[c];
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
			float cross = row_amount(c) * escape_speed(c, d, tail) * open_c * la_level_dt(lv_c)
				* la_face_div(c, nbr[f]);
			if (cross <= 0.0) {
				continue;
			}
			x_amt[f] = cross;
			x_h[f] = cross * (h_per_unit(c) + tail);
			x_q[f] = cross * charge_per_unit(c);
			continue;
		}
		if (inb == GHOST_SPACE && rides && carries && awake(c)) {
			la_dt = la_level_dt(lv_c);
			float u_out = max(face_u[f], 0.0);
			float cross = row_amount(c) * u_out * open_c * la_dt * la_face_div(c, nbr[f]);
			if (cross > 0.0) {
				x_amt[f] = cross;
				x_h[f] = cross * h_per_unit(c);
				x_q[f] = cross * charge_per_unit(c);
			}
			continue;
		}
		if (inb < 0) {
			continue;   // a shut wall, or a space face this record has no law for
		}
		uint n = uint(inb);
		// The solid mask stops MATTER. Heat is not matter, so conduction crosses rock both ways.
		if (solid[n] != 0.0 && !pores && !heat) {
			continue;
		}
		// A face runs on the COARSER of the pair's clocks, and a sleeping pair moves nothing.
		if (tlevel[n] < params.level || !listed(n) || (!awake(c) && !awake(n))) {
			continue;
		}
		float dist_f = la_face_dist(c, inb);
		float div_f = la_face_div(c, inb);
		// LA_APPROX: level_seam_coarse_clock
		// ONE OPENNESS AND ONE CLOCK PER FACE, read the same by both sides: a resistance in series is
		// the harder of the pair's, and a face advances on the coarser of their timesteps.
		float open = min(open_c, 1.0 - clamp(resist[n], 0.0, 1.0));
		la_dt = la_level_dt(min(lv_c, tlevel[n]));
		float u = rides ? face_u[f] : 0.0;
		u += drift_at(c, n, d, dist_f);
		float cross = 0.0;
		if (u != 0.0) {
			cross = row_amount(u > 0.0 ? c : n) * u * open * la_dt * div_f;
		}
		cross += diffusive_at(c, n, dist_f) * open * la_dt * div_f;
		if (cross == 0.0) {
			continue;
		}
		x_amt[f] = cross;
		if ((params.flags & TF_ENTHALPY) != 0u) {
			x_h[f] = cross;   // this record's amount IS the enthalpy
		} else if (carries) {
			uint donor = cross > 0.0 ? c : n;
			x_h[f] = cross * h_per_unit(donor);
			x_q[f] = cross * charge_per_unit(donor);
		}
	}
}


// PASS_APPLY: sum this record's own faces into the cell. Momentum rides the mass at the donor's own
// velocity, which no record writes until the momentum pass, so it is read rather than stored.
void row_apply(uint c) {
	bool pores = params.law == LAW_DARCY;
	bool heat = params.mode == MODE_CONDUCT;
	if (solid[c] != 0.0 && !pores && !heat) {
		return;
	}
	float kg_mol = sub_kg_mol();
	bool carries = params.density > 0.0;
	float d_amt = 0.0;
	float d_h = 0.0;
	float d_q = 0.0;
	float ke_ride = 0.0;
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
		float ke_cross = 0.0;
		if (carries) {
			uint donor = cross > 0.0 ? c : uint(max(inb, 0));
			vec3 vd = vel_at(donor);
			d_m -= cross * kg_mol * vd;
			ke_cross = cross * kg_mol * 0.5 * dot(vd, vd);
			ke_ride -= ke_cross;
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
			bnd_h[c] -= cross_h + ke_cross + cross * kg_mol * pe_kg;
			bnd_q[c] -= cross_q;
			if (carries) {
				uint donor = cross > 0.0 ? c : uint(max(inb, 0));
				vec3 bm = cross * kg_mol * vel_at(donor);
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
	if ((params.flags & TF_ENTHALPY) == 0u) {
		h[c] += d_h;
	}
	if (carries) {
		charge[c] += d_q;
		// MOTION IS BOOKED WITH THE MASS: the kinetic energy the merged momentum cannot hold is heat.
		float rb0 = max(rho_bulk[c], 0.0);
		vec3 m0 = vec3(mom_x[c], mom_y[c], mom_z[c]);
		float ke0 = rb0 > 0.0 ? 0.5 * dot(m0, m0) / rb0 : 0.0;
		mom_x[c] += d_m.x;
		mom_y[c] += d_m.y;
		mom_z[c] += d_m.z;
		// The potential energy per volume follows the mass, so pe/rho stays the cell's own specific value.
		float pe_kg_c = rb0 > 0.0 ? pe_j_m3[c] / rb0 : 0.0;
		pe_j_m3[c] += d_amt * kg_mol * pe_kg_c;
		rho_bulk[c] += d_amt * kg_mol;
		float rb1 = max(rho_bulk[c], 0.0);
		vec3 m1 = m0 + d_m;
		float ke1 = rb1 > 0.0 ? 0.5 * dot(m1, m1) / rb1 : 0.0;
		h[c] += ke0 + ke_ride - ke1;
		h_carried[c] += d_h;
		if (params.sub_cap_j_m3k > 0.0) {
			cap_sensible[c] += d_amt * params.sub_cap_j_m3k;
		}
	}
	if ((params.flags & TF_RADIOGENIC) != 0u) {
		// The rock warms itself, at this epoch's rate. This record carries h_j_m3, so `amount` IS enthalpy.
		float dq = max(rad_w_m3[c], 0.0) * la_dt;
		amount[c] += dq;
		radiogenic[c] = dq;
		d_amt += dq;
	}
	// LA_APPROX: boundary_relaxation_zone
	bool last = params.substep_k + (params.substep_n >> tlevel[c]) >= params.substep_n;
	if ((params.flags & TF_RELAX) != 0u && last && rim_w[c] > 0.0) {
		int rg = rim_ghost[c];
		if (rg >= int(params.cell_count) && rg < int(params.total_count)) {
			uint rgu = uint(rg);
			float dq = rim_w[c] * (amount[rgu] - amount[c]);
			if (dq != 0.0) {
				float dh = 0.0;
				if ((params.flags & TF_ENTHALPY) != 0u) {
					dh = dq;
				} else if (carries) {
					dh = dq * h_per_unit(dq > 0.0 ? rgu : c);
					h[c] += dh;
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
	// PROPAGATION: the bubble grows one cell per substep, as fast as anything in it travels.
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


// PASS_MOMENTUM: the pressure the faces state, the viscous stress between the pair, and this
// substep's share of the body impulse. At rest the first is exactly the cell's own weight and the
// third is exactly minus it, so a column in balance stays in it.
void move_momentum(uint c) {
	cel_m_s[c] = 0.0;
	if (solid[c] != 0.0) {
		return;   // locked matter holds no bulk momentum
	}
	vec3 dm = vec3(0.0);
	float cel_top = 0.0;
	uint f_lo = la_face_lo(c);
	uint f_hi = la_face_hi(c);
	for (uint f = f_lo; f < f_hi; ++f) {
		uint d = la_face_slot(c, f);
		int inb = nbr[f];
		if (inb < 0) {
			inb = ghost[f];
		}
		cel_top = max(cel_top, face_c(c, d));
		float div_f = la_face_div(c, inb);
		// WHAT THE FACE STATES OVER WHAT THIS CELL'S OWN STACK ALREADY STATES THERE. The stack's six
		// faces integrate to exactly the cell's weight, so only the DEPARTURE from it is a net force,
		// and a column in balance never differences two full pressures to get one.
		vec3 push = -(fp_star[f] - face_p(c, d)) * face_normal(d) * div_f * la_dt;
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
		if (solid[n] != 0.0 || tlevel[n] < params.level || !listed(n)) {
			continue;
		}
		// VISCOSITY DIFFUSES VELOCITY: mu grad(v) across the face, one viscosity for the pair, integrated
		// EXACTLY over the substep: the pair's velocity difference decays at the rate the two masses set,
		// so a thin cell beside a dense one relaxes onto it instead of overshooting.
		float nu = n < params.cell_count ? 0.5 * (nu_t[c] + nu_t[n]) : nu_t[c];
		float rc = max(rho_bulk[c], 0.0);
		float rn = max(rho_bulk[n], 0.0);
		float mu = 0.5 * (rc + rn) * nu;
		float dt_f = la_level_dt(min(tlevel[c], tlevel[n]));
		float dist = la_face_dist(c, inb);
		float k_c = mu * div_f / dist;
		float k_n = mu * la_face_div(n, int(c)) / dist;
		float rate = (rc > 0.0 ? k_c / rc : 0.0) + (rn > 0.0 ? k_n / rn : 0.0);
		float t_eff = rate * dt_f > 1.0e-6 ? (1.0 - exp(-rate * dt_f)) / rate : dt_f;
		dm += k_c * (vel_at(n) - vel_at(c)) * t_eff;
	}
	// This substep's share of the body impulse the stack does not already carry: state_derive booked
	// the weight leg out of it wherever the cell's own faces state one.
	float sf = exp2(-float(tlevel[c]));
	vec3 v_old = vel_at(c);
	mom_x[c] += dm.x + bodyf_x[c] * sf;
	mom_y[c] += dm.y + bodyf_y[c] * sf;
	mom_z[c] += dm.z + bodyf_z[c] * sf;
	// v = p/rho off the momentum this pass settled, so the next substep's faces read the new field.
	float rb = rho_bulk[c];
	vec3 v = rb > 0.0 ? vec3(mom_x[c], mom_y[c], mom_z[c]) / rb : vec3(0.0);
	// THE WORK THE FACES DID: what the pressure and viscous impulse gave to motion, the enthalpy
	// loses (rho Dh/Dt = v.grad p). A stacked cell's departure impulse carries its weight, and that
	// leg is the potential book's, so it is taken back out before the debit.
	vec3 gv = g_at(c);
	vec3 fg = (max(pressure[c], 0.0) > 0.0 && length(gv) > 0.0) ? rb * gv * la_level_dt(tlevel[c]) : vec3(0.0);
	h[c] -= dot(0.5 * (v_old + v), dm - fg);
	vel_x[c] = v.x;
	vel_y[c] = v.y;
	vel_z[c] = v.z;
	speed[c] = length(v);
	cel_m_s[c] = no_matter(c) ? 0.0 : cel_top;
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



// The Courant number per substep the face solve, momentum close and record moves stay stable
// under as a SEQUENCE, docs/MODEL_PARAMETERS.md.
const float LA_COURANT_LIMIT = 0.5;

// Substeps this record's stability asks of THIS cell, off the cell's own state: the acoustic signal,
// the donor courant, the drift closure's own speed and the diffusive limit.
float la_row_need(uint c) {
	float L = cell_edge[c];
	float dt = params.dt_s;
	float need = 0.0;
	// The fastest signal any of this cell's faces carries: |v.n| + c of the layer touching it.
	if ((params.flags & TF_VEL) != 0u && solid[c] == 0.0) {
		float w = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			w = max(w, abs(dot(vel_at(c), face_normal(d))) + face_c(c, d));
		}
		need = w * dt / L;
	}
	float v = 0.0;
	if (params.mode == MODE_ADVECT || params.mode == MODE_BOTH) {
		v = max(speed[c], 0.0);
	}
	if ((params.flags & TF_SETTLE) != 0u) {
		v += stokes_settling(c, params.grain_d, params.fluid_rho, params.fluid_visc);
	}
	if (params.law == LAW_SHALLOW || params.law == LAW_FILM) {
		// The steepest slope a cell can present is one, so the closure's own speed is bounded by it.
		v += length(g_at(c)) * dt;
	}
	if (params.law == LAW_ESCAPE) {
		float tail = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			v = max(v, escape_speed(c, d, tail));
		}
	}
	need += v * dt / L;
	if (params.law == LAW_EDDY || params.mode == MODE_CONDUCT || params.law == LAW_OHMIC) {
		// The Smagorinsky term off the cell's own strain scale, which |v|/L bounds.
		float mix_l = SMAGORINSKY_COEFF * L;
		float rb = max(rho_bulk[c], 0.0);
		float nu = (rb > 0.0 ? mix(params.mu_air, params.mu_water, condensed_frac(c)) / rb : 0.0)
			+ mix_l * mix_l * sqrt(18.0) * max(speed[c], 0.0) / L;
		if (params.mode == MODE_CONDUCT) {
			nu = max(aux[c], 0.0) / max(cap_sensible[c], 1.0e-12);
		}
		need += 6.0 * nu * dt / (L * L);
	}
	// NO SIGNAL CROSSES A CELL FASTER THAN LIGHT: a state asking for a shorter step is not a timestep.
	return min(need / LA_COURANT_LIMIT, params.dt_s * C_LIGHT / L);
}

uint la_row_level(uint c) {
	float need = la_row_need(c);
	return need > 1.0 ? uint(ceil(log2(need))) : 0u;
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
	float eps = longwave_emissivity(c);
	lw_emis[c] = eps;
	sw_absorbed[c] = shortwave_absorbed_frac(c, solar_step_m(c));
	// Share of an upwelling flux this cell keeps as heat over one vertical step.
	vec3 gsw = g_at(c);
	float edge = cell_edge[c];
	float up_len = length(gsw) > 0.0 ? la_step_len(-normalize(gsw), edge) : edge;
	sw_keep[c] = shortwave_absorbed_frac(c, up_len) * (1.0 - shortwave_albedo(c));
	float tk = t_k(c);
	float leaving = eps * STEFAN * tk * tk * tk * tk * la_dt;
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
	// Stefan-Boltzmann against the published emission: every face of e*sigma*T^4 over its own area.
	float tk = t_k(c);
	float sb = lw_emis[c] * STEFAN * tk * tk * tk * tk * la_dt * div_sum;
	rad_residual[c] = abs(lost - sb) / max(sb, 1.0e-30);
	amount[c] += gained - lost;
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
	if (la_active_levels(gidx)) {
		return;
	}
	// EVERY PASS PAST HERE WALKS THIS GROUP'S ACTIVE LIST, never the box: the list is sorted by level,
	// so its suffix at params.level is exactly the cells moving on this substep. O(active), not O(cells).
	if ((params.flags & TF_LEVEL) != 0u) {
		uint b0 = args_base();
		if (gidx >= level_args[b0 + params.level * LEVEL_SLOTS + 6u]) {
			return;
		}
		gidx = level_idx[act_base() + level_args[b0 + params.level * LEVEL_SLOTS + 4u] + gidx];
	}
	// A ghost tail cell holds a prescribed state: the interior cell beside it reads that state and
	// states the face itself, so nothing here ever dispatches over one.
	if (gidx >= params.cell_count) {
		return;
	}
	la_dt = la_level_dt(tlevel[gidx]);
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
