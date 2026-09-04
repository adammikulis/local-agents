#[compute]
#version 450

layout(local_size_x = 64) in;

// enthalpy.glsli FIRST: Godot does not expand a nested #include inside a .glsli.
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"
#include "cellvol.glsli"
#include "matter_channels.glsli"
#include "eos.glsli"

// THE STATE: internal energy per volume, J/m^3. Enthalpy is derived from it at the pressure solved.
layout(set = 0, binding = 21, std430) restrict buffer Energy { float e_j_m3[]; };
layout(set = 0, binding = 22, std430) restrict buffer Pressure { float pressure[]; };
// Read as well as written: this pass is the ONE writer, and reads the temperature it replaces.
layout(set = 0, binding = 23, std430) restrict buffer Temp { float temp[]; };
// THE LATTICE'S RESERVOIR: its internal energy and temperature, beside the fluid's above.
layout(set = 0, binding = 69, std430) restrict buffer EnergyLith { float e_lith_j_m3[]; };
layout(set = 0, binding = 70, std430) restrict buffer TempLith { float temp_lith[]; };
layout(set = 0, binding = 71, std430) restrict writeonly buffer CondLith { float conductivity_lith[]; };
layout(set = 0, binding = 73, std430) restrict writeonly buffer CapLith { float cap_lith[]; };
layout(set = 0, binding = 74, std430) restrict writeonly buffer LatticeFrac { float lattice_frac[]; };
layout(set = 0, binding = 76, std430) restrict writeonly buffer HH2OVap { float h_h2o_vap[]; };
// THE FLUID'S OWN PRESSURE in every cell: the published pressure of an open cell, and the state a
// locked cell's band and air stand at under whatever column its rock carries.
layout(set = 0, binding = 77, std430) restrict buffer PFluid { float p_fluid[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Props { float props[]; };

// Cementation state and the solid flag. Read-modify-write: the lockup branch is hysteretic.
layout(set = 0, binding = 14, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict buffer Cement { float cement[]; };
layout(set = 0, binding = 16, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = 17, std430) restrict buffer Grain { float grain[]; };
// Cell centre, flat cell*3, model units. The centrifugal term needs the radius vector.
layout(set = 0, binding = 18, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = 49, std430) restrict readonly buffer Grav { float g_field[]; };  // m/s^2, cell*3
layout(set = 0, binding = 39, std430) restrict writeonly buffer GravRest { float g_rest[]; };
// The body impulse this step deposits per cell (weight + rotating frame), kg/(m^2 s): the ledger's book.
layout(set = 0, binding = 50, std430) restrict writeonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = 51, std430) restrict writeonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = 52, std430) restrict writeonly buffer BodyFZ { float bodyf_z[]; };
// The mixture's sound speed, m/s: Wood's one-pressure compressibility sum over the cell's own matter.
layout(set = 0, binding = 53, std430) restrict buffer KCond { float k_cond[]; };
layout(set = 0, binding = 66, std430) restrict writeonly buffer GasR { float gas_r[]; };        // J/(kg K), the gas mixture
layout(set = 0, binding = 67, std430) restrict writeonly buffer GasGamma { float gas_gamma[]; };
layout(set = 0, binding = 68, std430) restrict writeonly buffer Mach { float mach[]; };         // |v| over the cell's own sound speed
// The energy of MOTION, J/m^3, which the enthalpy state does not hold. A function of state and nothing
// else, read only by the reduce, so a book can weigh it against the enthalpy it trades with.
layout(set = 0, binding = 90, std430) restrict writeonly buffer KinBuf { float ke_j_m3[]; };
// The energy of POSITION, J/m^3: this cell's mass in the potential `g_rest` is the gradient of.
layout(set = 0, binding = 78, std430) restrict readonly buffer GravPhi { float grav_phi[]; };   // deviation from grav_ref
layout(set = 0, binding = 95, std430) restrict readonly buffer GravRef { float grav_ref[]; };   // J/kg, the monopole reference  // J/kg
layout(set = 0, binding = 91, std430) restrict writeonly buffer PotBuf { float pe_j_m3[]; };
// The cell's condensed matter other than water: volume fraction and kg/m^3, every lithic channel summed.
layout(set = 0, binding = 96, std430) restrict writeonly buffer LithicFrac { float lithic_frac[]; };
layout(set = 0, binding = 97, std430) restrict writeonly buffer LithicKg { float lithic_kg[]; };
// Radiogenic power of this cell's own matter, W/m^3: sum over channels of amount * M * W/kg(mix, epoch).
// flux.glsl's RADIOGENIC leg deposits it into the enthalpy.
layout(set = 0, binding = 75, std430) restrict writeonly buffer RadW { float rad_w_m3[]; };

// MOMENTUM is the state, kg m/s per m^3. Velocity is what you read off it once you know the mass.
layout(set = 0, binding = 25, std430) restrict buffer MomX { float mom_x[]; };
layout(set = 0, binding = 26, std430) restrict buffer MomY { float mom_y[]; };
layout(set = 0, binding = 27, std430) restrict buffer MomZ { float mom_z[]; };
layout(set = 0, binding = 28, std430) restrict writeonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 29, std430) restrict writeonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 30, std430) restrict writeonly buffer VelZ { float vel_z[]; };

// What the pressure kernel needs and this pass already computes: the cell's gas in mol/m^3 and the
// density of its CONDENSED matter alone, kg/m^3.
layout(set = 0, binding = 32, std430) restrict writeonly buffer RhoBulk { float rho_bulk[]; };
layout(set = 0, binding = 33, std430) restrict writeonly buffer Cond { float conductivity[]; };

// THE PHASE OF THE CELL'S H2O, as three shares of h2o[] summing to 1. Derived, never stored.
layout(set = 0, binding = 34, std430) restrict writeonly buffer H2OSolid { float h2o_solid[]; };
layout(set = 0, binding = 35, std430) restrict writeonly buffer H2OLiquid { float h2o_liquid[]; };
layout(set = 0, binding = 36, std430) restrict writeonly buffer H2OVapour { float h2o_vapour[]; };

// THE MELT SHARE OF THE CELL'S SILICATE: the lever rule across the solidus-liquidus interval. Derived from
// the same enthalpy ladder the temperature came off, never stored.
layout(set = 0, binding = 37, std430) restrict writeonly buffer SilicateMelt { float silicate_melt[]; };

// LIQUID water per cell: h2o times its liquid share. Read back every drain for the CPU consumers.
layout(set = 0, binding = 19, std430) restrict writeonly buffer Liquid { float liquid[]; };

// THE DEAD ORGANIC POOL'S COMPOSITION: molar H:C and O:C, and how far below fresh litter the nearer ratio
// sits. +inf where the pool is under the mole floor, so a MIN or COUNT_LT row cannot read noise.
layout(set = 0, binding = 20, std430) restrict writeonly buffer OrgHC { float org_hc[]; };
layout(set = 0, binding = 31, std430) restrict writeonly buffer OrgOC { float org_oc[]; };
layout(set = 0, binding = 38, std430) restrict writeonly buffer OrgFresh { float org_fresh[]; };

// WHERE AND HOW FAST, so a band of latitude or altitude is an ordinary reduce gate rather than a CPU walk.
// speed is |v|, m/s; alt is the height of the cell above the sea shell, m; lat is the angle of its radius
// out of the equatorial plane, degrees.
layout(set = 0, binding = 41, std430) restrict writeonly buffer Speed { float speed[]; };
layout(set = 0, binding = 42, std430) restrict writeonly buffer Lat { float lat[]; };
layout(set = 0, binding = 43, std430) restrict writeonly buffer Alt { float alt[]; };

// How many of this cell's channel amounts, its enthalpy and its momentum are NaN or infinite.
// Reduced by the `nonfinite_cells` row.
layout(set = 0, binding = 44, std430) restrict writeonly buffer NonFinite { float nonfinite[]; };
layout(set = 0, binding = 92, std430) restrict writeonly buffer MomOrphan { float mom_orphan[]; };
// 1 where the (T, p) solve spent its budget without meeting LA_STATE_TOL; the derive_unconverged_cells row sums it.
layout(set = 0, binding = 99, std430) restrict writeonly buffer Unconverged { float unconverged[]; };

// The enthalpy each mixture entry holds, J/m^3, and the sensible entry's capacity, J/m^3/K.
layout(set = 0, binding = 45, std430) restrict writeonly buffer HH2O { float h_h2o[]; };
layout(set = 0, binding = 46, std430) restrict writeonly buffer HSilicate { float h_silicate[]; };
layout(set = 0, binding = 47, std430) restrict writeonly buffer HSensible { float h_sensible[]; };
layout(set = 0, binding = 48, std430) restrict writeonly buffer CapSensible { float cap_sensible[]; };

// The active list the transport substep walks, sorted by level. LATemporalLevels.SLOTS: 4 offset, 6 suffix.
layout(set = 0, binding = 81, std430) restrict readonly buffer LevelIdx { uint level_idx[]; };
layout(set = 0, binding = 82, std430) restrict readonly buffer LevelArgs { uint level_args[]; };

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
	uint restate;           // 0 = the field step's derive; 1 = the transport substep's restate
	uint args_slot;         // where this substep's level args start, in words
	uint act_base;          // where this row group's sorted list starts, in cells
	uint lithify;           // 1 where the ladder holds the "lithify" derive record
} params;

const float SOLID_IN = 0.6;    // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float ICE_ALPHA = 1.6e-4;        // LAPhysical.ICE_VOLUME_EXPANSION_PER_K
const float ICE_T_REF_C = 0.0;         // LAPhysical.WATER_FREEZE_C
const float WATER_COMPRESS = 4.525e-10;     // LAPhysical.WATER_ISOTHERMAL_COMPRESSIBILITY_PER_PA
const float ICE_BULK = 8.4e9;          // LAPhysical.ICE_BULK_MODULUS_PA
const float SOLID_OUT = 0.4;   // LAPhysical.RHEOLOGICAL_MOBILE_CRYSTAL_FRAC

// One row of `props` per channel, built from LASubstances by StateDerivePass. A channel amount is mol/m^3.
const int PROP_STRIDE = 12;        // StateDerivePass.PROP_STRIDE
// The (T, p) solve's budget: under-relaxed, so a pair on a latent plateau converges onto it.
const int LA_STATE_STEPS = 64;
const float LA_STATE_TOL = 1.0e-6;
const int PROP_M = 0;              // kg/mol
const int PROP_C = 1;              // J/kg/K, sensible-heat entry only
const int PROP_MOL_PER_KG = 2;     // mol/kg, non-condensable gases only
const int PROP_ENTRY = 3;          // which mixture entry the substance belongs to
const int PROP_LAMBDA = 4;         // W/m/K
const int PROP_FULL = 5;           // mol/m^3 at which a cell is full — amount/full is its volume fraction
const int PROP_ALPHA = 6;          // 1/K volumetric expansivity
const int PROP_BULK = 7;           // Pa bulk modulus; 0 = declared incompressible
const int PROP_TREF = 8;           // C the reference density is quoted at
const int PROP_LITHIC = 9;         // 1 = a rock or metal phase; the solid flag reads their summed volume
const int PROP_RAD_GROUP = 10;
const int PROP_CONDENSED = 11;     // fills volume of its own and resists being squeezed

float rad_w_kg(int group) {
	if (group == 1) { return params.rad_w_kg_1; }
	if (group == 2) { return params.rad_w_kg_2; }
	if (group == 3) { return params.rad_w_kg_3; }
	if (group == 4) { return params.rad_w_kg_4; }
	return 0.0;
}

// Mixture entries. Two substances carry a phase ladder; everything else is linear in T, so one entry with
// the summed mass and c = sum(m*c)/sum(m) reproduces sum(m_i*c_i*T) exactly.
const int E_H2O = 0;               // LAMatterChannels.Entry.H2O
const int E_SILICATE = 1;          // LAMatterChannels.Entry.SILICATE
const int E_SENSIBLE = 2;          // LAMatterChannels.Entry.SENSIBLE
const int N_ENTRIES = 3;

// A substance with no phase boundary in this planet's range: enthalpy is c*T and nothing else.
SubstanceTh la_sensible_only(float c_j_kgk) {
	return SubstanceTh(
		c_j_kgk, c_j_kgk, c_j_kgk,
		0.0, 0.0,
		0.0, 0.0,
		0.0, 0.0,
		0.0, 0.0,
		0.0, 0.0,
		0.0, 0.0, 0.0,
		0.0, 0.0, 0.0, 0.0,
		0.0,
		false,
		false,
		false,
		0,
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0)
	);
}

// The enthalpy one mixture entry holds at the state the solve landed on, J.
float la_entry_h(SubstanceTh s, float m_kg, float t_c, float p_pa, float room_m3, bool pinned,
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


void main() {
	uint g = gl_GlobalInvocationID.x;
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
	float mass[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);      // the fluid's entries, kg
	float mass_l[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);    // the lattice's entries, kg
	float mass_loose[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);   // loose lithic grains, kg
	float mass_all[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);
	float mc = 0.0;          // sum of m*c over the fluid's sensible-heat substances, J/K
	float mc_l = 0.0;        // the lattice's
	float mc_loose = 0.0;    // the loose lithic grains', inside mc
	float cap_l = 0.0;       // the lattice's sensible capacity over every entry, J/K
	float cp_gas = 0.0;      // sum of m*cp over the non-condensable gases, J/K: the mixture gamma's cp
	float m_gas = 0.0;       // kg of non-condensable gas
	float n_gas_mol = 0.0;   // moles of non-condensable gas
	float v_lambda = 0.0;    // volume-weighted conductivity of the fluid, W/m/K
	float v_used = 0.0;
	float v_lambda_l = 0.0;  // the lattice's
	float v_lat = 0.0;       // volume fraction of the cemented lattice
	float v_lithic = 0.0;    // volume fraction of rock and metal phases: what the solid flag reads
	float v_sil = 0.0;       // volume fraction of the silicate entry, the one phase here that melts
	float rad_w = 0.0;       // radiogenic power of the cell's matter, W/m^3
	// EOS sums: b* the unstressed condensed volume of everything but h2o, c* its compressibility, the
	// fluid's at its own T and the lattice's (l*) at its.
	float b0 = 0.0; float b1 = 0.0; float b2 = 0.0;
	float l0 = 0.0; float l1 = 0.0; float l2 = 0.0;
	// Loose lithic grains: they take volume in the fluid and are never squeezed, so k_cond leaves them out.
	float g0 = 0.0; float g1 = 0.0; float g2 = 0.0;
	float lith_frac = 0.0; float lith_kg = 0.0;
	float c0 = 0.0; float c1 = 0.0; float c2 = 0.0;
	float mol_h2o_f = 0.0;   // the free water's moles; the pore channel is the lattice's
	float full_h2o = 0.0;
	float cem = clamp(cement[g], 0.0, 1.0);

	for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
		float f = max(channel_at(i, g), 0.0);
		if (f <= 0.0) {
			continue;
		}
		int base = i * PROP_STRIDE;
		float m = f * props[base + PROP_M] * vol;
		int entry = int(props[base + PROP_ENTRY]);
		bool lithic = props[base + PROP_LITHIC] > 0.0;
		bool is_water = entry == E_H2O;
		full_h2o = is_water ? props[base + PROP_FULL] : full_h2o;
		// The lattice's share: the cemented part of a lithic channel. Pore water joins it below.
		float sl = lithic ? cem : 0.0;
		mass_all[entry] += m;
		mass_l[entry] += m * sl;
		mass[entry] += m * (1.0 - sl);
		mass_loose[entry] += lithic ? m * (1.0 - sl) : 0.0;
		if (entry == E_SENSIBLE) {
			mc += m * (1.0 - sl) * props[base + PROP_C];
			mc_l += m * sl * props[base + PROP_C];
			mc_loose += lithic ? m * (1.0 - sl) * props[base + PROP_C] : 0.0;
		}
		cap_l += m * sl * props[base + PROP_C];
		float vf = f / props[base + PROP_FULL];
		v_lambda += vf * (1.0 - sl) * props[base + PROP_LAMBDA];
		v_used += vf * (1.0 - sl);
		v_lambda_l += vf * sl * props[base + PROP_LAMBDA];
		v_lat += vf * sl;
		v_lithic += lithic ? vf : 0.0;
		if (props[base + PROP_CONDENSED] > 0.0 && !is_water) {
			lith_frac += vf;
			lith_kg += m;
		}
		v_sil += entry == E_SILICATE ? vf : 0.0;
		rad_w += f * props[base + PROP_M] * rad_w_kg(int(props[base + PROP_RAD_GROUP]));
		n_gas_mol += m * props[base + PROP_MOL_PER_KG];
		if (props[base + PROP_MOL_PER_KG] > 0.0) {
			cp_gas += m * props[base + PROP_C];
			m_gas += m;
		}
		// v0(T) is linear in T, so its mass sum splits into three T-independent pieces gathered here
		// and combined once each solve has a temperature. h2o is kept apart: its vapour share is gas.
		if (props[base + PROP_CONDENSED] > 0.0 && props[base + PROP_FULL] > 0.0) {
			float tr = props[base + PROP_TREF];
			float kk = props[base + PROP_BULK];
			// The expansivity falls under pressure as alpha * K_T stays constant, K_T = K0 + 4 P (BM2).
			float dp = max(pressure[g], 0.0) - LA_P_STD;
			float al = props[base + PROP_ALPHA] * ((kk > 0.0 && dp > 0.0) ? kk / (kk + 4.0 * dp) : 1.0);
			float w0 = vf * vol;
			float w1 = w0 * al;
			mol_h2o_f += is_water ? f * vol * (1.0 - sl) : 0.0;
			b0 += is_water ? 0.0 : w0 * (1.0 - sl);
			b1 += is_water ? 0.0 : w1 * (1.0 - sl);
			b2 += is_water ? 0.0 : w1 * tr * (1.0 - sl);
			l0 += is_water ? 0.0 : w0 * sl;
			l1 += is_water ? 0.0 : w1 * sl;
			l2 += is_water ? 0.0 : w1 * tr * sl;
			g0 += (lithic && !is_water) ? w0 * (1.0 - sl) : 0.0;
			g1 += (lithic && !is_water) ? w1 * (1.0 - sl) : 0.0;
			g2 += (lithic && !is_water) ? w1 * tr * (1.0 - sl) : 0.0;
			// LOOSE GRAINS PRESS NOTHING: they take volume; the fluid alone is compressed in the rest.
			if (kk > 0.0 && !is_water && !lithic) {
				float q0 = w0 / kk;
				float q1 = w1 / kk;
				c0 += q0;
				c1 += q1;
				c2 += q1 * tr;
			}
		}
	}

	rad_w_m3[g] = rad_w;
	float total = mass_all[E_H2O] + mass_all[E_SILICATE] + mass_all[E_SENSIBLE];
	float total_f = mass[E_H2O] + mass[E_SILICATE] + mass[E_SENSIBLE];
	float total_l = mass_l[E_H2O] + mass_l[E_SILICATE] + mass_l[E_SENSIBLE];
	float inv_vol = (vol > 0.0) ? 1.0 / vol : 0.0;
	// The lattice's own temperature off its own energy: no gas room, the rock's pressure for its melting point.
	SubstanceTh subs_l[LA_MIX_MAX];
	subs_l[E_H2O] = la_h2o();
	subs_l[E_SILICATE] = la_silicate();
	subs_l[E_SENSIBLE] = la_sensible_only(mass_l[E_SENSIBLE] > 0.0 ? mc_l / mass_l[E_SENSIBLE] : 0.0);
	subs_l[3] = la_sensible_only(0.0);
	bool pinned_l = false;
	float progress_l = 0.0;
	float t_l = temp_lith[g];
	// The lattice's pressure: the column in a locked cell; the fluid's plus half its own rock's weight in a cut cell.
	float p_rock = solid[g] != 0.0 ? max(pressure[g], 0.0)
		: max(pressure[g], 0.0) + 0.5 * total_l * inv_vol * length(g_eff) * cell_edge[g];
	if (total_l > 0.0) {
		t_l = la_mix_state(subs_l, mass_l, N_ENTRIES, e_lith_j_m3[g] * vol, p_rock, 0.0, 0.0, pinned_l, progress_l);
	}
	// Parallel mixing rule per reservoir: the fluxes through each constituent add.
	conductivity[g] = (v_used > 0.0) ? v_lambda / v_used : 0.0;
	conductivity_lith[g] = (v_lat > 0.0) ? v_lambda_l / v_lat : 0.0;
	lattice_frac[g] = clamp(v_lat, 0.0, 1.0);
	cap_lith[g] = cap_l * inv_vol;
	float rho = total * inv_vol;     // kg/m^3, gas included: gravity pulls on all of it
	rho_bulk[g] = rho;
	// Pore water is the lattice's, filling the rock's pores at the table's liquid density.
	float pore_kg = mass_l[E_H2O];
	float pore_m3 = subs_l[E_H2O].rho_liq > 0.0 ? pore_kg / subs_l[E_H2O].rho_liq : 0.0;
	lithic_frac[g] = clamp(lith_frac + pore_m3 * inv_vol, 0.0, 1.0);
	lithic_kg[g] = (lith_kg + pore_kg) * inv_vol;
	vec3 v_frame = cross(omega, r_vec);
	pe_j_m3[g] = rho * (params.grav_self * (grav_phi[g] + grav_ref[g]) - 0.5 * dot(v_frame, v_frame));
	ke_j_m3[g] = 0.0;
	float f_melt = 0.0;
	vec3 v = vec3(0.0);
	// No matter: the cell is EMPTY, and its DERIVED bulk state is none. Momentum with no mass to carry it
	// is an orphan the momentum_orphan_cells row counts; it is never zeroed here.
	if (rho <= 0.0) {
		vec3 pm = vec3(mom_x[g], mom_y[g], mom_z[g]);
		mom_orphan[g] = dot(pm, pm) > 0.0 ? 1.0 : 0.0;
		temp[g] = -LA_KELVIN_OFFSET;   // no matter, so no temperature
		temp_lith[g] = -LA_KELVIN_OFFSET;
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
	vel_x[g] = v.x;
	vel_y[g] = v.y;
	vel_z[g] = v.z;
	speed[g] = length(v);
	ke_j_m3[g] = 0.5 * rho_f * dot(v, v);

	SubstanceTh subs[LA_MIX_MAX];
	subs[E_H2O] = la_h2o();
	subs[E_SILICATE] = la_silicate();
	subs[E_SENSIBLE] = la_sensible_only(mass[E_SENSIBLE] > 0.0 ? mc / mass[E_SENSIBLE] : 0.0);
	subs[3] = la_sensible_only(0.0);
	// No channel carries a dissolved solute, so the freezing point is not depressed.
	bool pinned = false;
	float progress = 0.0;
	float m_h2o = mass[E_H2O];
	float mol_sil = subs[E_SILICATE].molar_mass > 0.0 ? mass[E_SILICATE] / subs[E_SILICATE].molar_mass : 0.0;
	float t_c = temp[g];
	float p_pa = max(solid[g] != 0.0 ? p_fluid[g] : pressure[g], 0.0);
	float e_fluid = e_j_m3[g];
	// The fluid's room: the cell less what its condensed lithic matter fills. H = U + pV over it.
	float room_f = 1.0 - clamp(lith_frac + pore_m3 * inv_vol, 0.0, 1.0);
	float f_solid = 0.0;
	float f_liquid = 0.0;
	float f_vapour = 0.0;
	float f_vap_sil = 0.0;
	float b_vol = 0.0;
	float c_comp = 0.0;
	// THE GAS ROOM: the cell less every condensed volume, where the vapour stands at saturation. The
	// lattice's volume is its grains and the water in its pores, liquid or ice by its own melting point.
	float lat_vol = l0 + t_l * l1 - l2 + pore_m3;
	float room_gas = max(vol - (b0 + t_c * b1 - b2) - lat_vol - m_h2o * la_water_liquid_v_m3_kg(t_c), 0.0);
	// ONE STATE: the ladder gives T(h, p) and the EOS p(T) off the same matter, so they solve together.
	float p_lo = 0.0;
	float p_hi = 0.0;
	bool has_lo = false;
	bool has_hi = false;
	float p_prev_it = p_pa;
	float f_prev = 0.0;
	bool converged = false;
	if (total_f > 0.0) {
	for (int it = 0; it < LA_STATE_STEPS; ++it) {
		// T and the room settle together at this p, so the residual below is a function of p alone.
		float vw = 0.0;
		float cw = 0.0;
		// T and the room settle together: the room at T, then T over that room, until neither moves.
		bool settled = false;
		for (int k = 0; k < LA_STATE_STEPS; ++k) {
			pinned = false;
			progress = 0.0;
			t_c = la_mix_state(subs, mass, N_ENTRIES, (e_fluid + p_pa * room_f) * vol, p_pa, room_gas, 0.0,
				pinned, progress);

			// The h2o split: the room's vapour, the rest solid or liquid by the melting point.
			f_solid = 0.0;
			f_liquid = 0.0;
			f_vapour = 0.0;
			if (m_h2o > 0.0) {
				SubstanceTh w = subs[E_H2O];
				f_vapour = la_mix_vapour_fraction(w, t_c, p_pa, m_h2o, room_gas, 0.0);
				float melt_t = la_melt_c_at(w, p_pa, 0.0);
				float molten = pinned ? progress : (t_c < melt_t ? 0.0 : 1.0);
				float condensed = max(1.0 - f_vapour, 0.0);
				f_solid = condensed * (1.0 - molten);
				f_liquid = condensed * molten;
			}
			f_vap_sil = mass[E_SILICATE] > 0.0
				? la_mix_vapour_fraction(subs[E_SILICATE], t_c, p_pa, mass[E_SILICATE], room_gas, 0.0) : 0.0;

			// Liquid and ice volumes, each squeezed on its own bulk modulus.
			vw = 0.0;
			cw = 0.0;
			if (m_h2o > 0.0) {
				float v_liq = la_water_liquid_v_m3_kg(t_c);
				float v_ice = (1.0 + ICE_ALPHA * (t_c - ICE_T_REF_C)) / subs[E_H2O].rho_sol;
				vw = m_h2o * (f_liquid * v_liq + f_solid * v_ice);
				cw = m_h2o * (f_liquid * v_liq * WATER_COMPRESS + f_solid * v_ice / ICE_BULK);
			}
			b_vol = (b0 + t_c * b1 - b2) + lat_vol + vw;
			c_comp = (c0 + t_c * c1 - c2) + cw;
			float room_next = max(vol - b_vol, 0.0);
			// The gas pressure is n R T over this room, so the room settles to the pressure's own
			// tolerance, or to float precision where the room is gone.
			settled = abs(room_next - room_gas) <= max(LA_STATE_TOL * room_gas, 2.0 * LA_FLOAT_EPS * vol);
			room_gas = room_next;
			if (settled) {
				break;
			}
		}
		if (!settled) {
			break;
		}
		float n_gas = n_gas_mol + f_vapour * mol_h2o_f + f_vap_sil * mol_sil;
		float tk = max(t_c + LA_KELVIN_OFFSET, 1.0);
		// A LOCKED CELL'S FREE FLUID KEEPS THE PRESSURE IT WAS SEALED WITH: its room is the rock's volume
		// error, which the pressure split names hypersensitive, so no state function sets it there.
		if (solid[g] != 0.0) {
			converged = true;
			break;
		}
		float p_next = la_eos_p(vol, n_gas * LA_R_J_MOL_K * tk, b_vol, c_comp, LA_P_STD);
		float f = p_next - p_pa;
		if (abs(f) <= LA_STATE_TOL * max(p_pa, 1.0)) {
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
		p_pa = max(p_step, 0.0);
	}
	} else {
		// Bare lattice with no fluid: nothing to solve a fluid state for, and the rock's is the cell's.
		converged = true;
		t_c = t_l;
		b_vol = lat_vol;
	}
	temp[g] = t_c;
	temp_lith[g] = total_l > 0.0 ? t_l : t_c;
	if (solid[g] == 0.0) {
		pressure[g] = p_pa;
	}
	p_fluid[g] = p_pa;

	// THE LATTICE'S ENTHALPY at its temperature: a solid cell's energy is split by it, and lithification
	// moves energy by it.
	float h_lat = 0.0;
	for (int i = 0; i < LA_MIX_MAX; ++i) {
		h_lat += la_entry_h(subs_l[i], mass_l[i], t_l, p_pa, 0.0, pinned_l, progress_l);
	}
	if (total_l <= 0.0) {
		e_lith_j_m3[g] = 0.0;
	}

	// THE HEAT EACH PHASE CARRIES, J/m^3, per entry so transport moves heat with matter: the free water's
	// condensed part and its vapour apart, and a lattice-only entry keeps the lattice's.
	{
		SubstanceTh w = subs[E_H2O];
		float m_free = mass[E_H2O];
		float h_cond = m_free > 0.0 ? (1.0 - f_vapour) * m_free * la_mix_specific_enthalpy(w, t_c, p_pa, m_free, 0.0, 0.0)
			+ (pinned ? progress * la_mix_jump_of(w, m_free, t_c, p_pa, 0.0, 0.0) : 0.0) : 0.0;
		float h_vap = m_free > 0.0 && f_vapour > 0.0
			? f_vapour * m_free * la_mix_specific_enthalpy(w, t_c, p_pa, m_free, 1.0e30, 0.0) : 0.0;
		float h_pore = la_entry_h(subs_l[E_H2O], mass_l[E_H2O], t_l, p_rock, 0.0, pinned_l, progress_l);
		h_h2o[g] = (m_free > 0.0 ? h_cond : h_pore) * inv_vol;
		h_h2o_vap[g] = h_vap * inv_vol;
		for (int i = 1; i < 3; ++i) {
			float hf = la_entry_h(subs[i], mass[i], t_c, p_pa, room_gas, pinned, progress);
			float hl = la_entry_h(subs_l[i], mass_l[i], t_l, p_rock, 0.0, pinned_l, progress_l);
			float per = mass[i] > 0.0 ? hf : hl;
			if (i == E_SILICATE) { h_silicate[g] = per * inv_vol; }
			if (i == E_SENSIBLE) { h_sensible[g] = per * inv_vol; }
		}
	}
	cap_sensible[g] = mc * inv_vol;
	// Shares of the free water channel; the pore channel is the lattice's whole.
	h2o_solid[g] = f_solid;
	h2o_liquid[g] = f_liquid;
	h2o_vapour[g] = f_vapour;
	liquid[g] = max(h2o[g], 0.0) * f_liquid;
	// The condensed FLUID's bulk modulus: its own volume over its own compressibility, the grains out.
	float fluid_vol = b_vol - lat_vol - (g0 + t_c * g1 - g2);
	k_cond[g] = (c_comp > 0.0 && fluid_vol > 0.0) ? fluid_vol / c_comp : 0.0;
	// The gas mixture's own specific gas constant and gamma, vapour included; its sound speed where gas
	// stands, the condensed fluid's own where none does.
	float m_g = m_gas + f_vapour * m_h2o;
	float n_g = n_gas_mol + f_vapour * mol_h2o_f;
	float cp_g = cp_gas + f_vapour * m_h2o * subs[E_H2O].c_gas;
	float nr = n_g * LA_R_J_MOL_K;
	float r_s = m_g > 0.0 ? nr / m_g : 0.0;
	float gam = cp_g > nr ? cp_g / (cp_g - nr) : 0.0;
	gas_r[g] = r_s;
	gas_gamma[g] = gam;
	float k_f = (c_comp > 0.0 && fluid_vol > 0.0) ? fluid_vol / c_comp : 0.0;
	float c_cell = (r_s > 0.0 && gam > 0.0) ? sqrt(gam * r_s * (t_c + LA_KELVIN_OFFSET))
		: ((k_f > 0.0 && rho_f > 0.0) ? sqrt(k_f / rho_f) : 0.0);
	float spd = length(v);
	mach[g] = c_cell > 0.0 ? spd / c_cell : (spd > 0.0 ? 1.0 / 0.0 : 0.0);

	// THE MELT SHARE OF THIS CELL'S SILICATE, off the SAME ladder: the lattice's at its temperature and
	// the loose grains' at the fluid's. Rock has a melting INTERVAL, so the lever rule reads back as a
	// linear share of it, and the latent heat is what put each temperature where it is.
	float f_melt_l = 0.0;
	if (mass_all[E_SILICATE] > 0.0) {
		SubstanceTh r = subs[E_SILICATE];
		float solidus = la_melt_c_at(r, p_pa, 0.0);
		float liquidus = la_liquidus_c_at(r, p_pa, 0.0);
		float width = liquidus - solidus;
		float f_melt_f = width > 0.0 ? clamp((t_c - solidus) / width, 0.0, 1.0) : (t_c < solidus ? 0.0 : 1.0);
		float solidus_l = la_melt_c_at(r, p_rock, 0.0);
		float liquidus_l = la_liquidus_c_at(r, p_rock, 0.0);
		float width_l = liquidus_l - solidus_l;
		f_melt_l = width_l > 0.0 ? clamp((t_l - solidus_l) / width_l, 0.0, 1.0) : (t_l < solidus_l ? 0.0 : 1.0);
		float m_sil_l = mass_l[E_SILICATE];
		f_melt = (m_sil_l * f_melt_l + mass[E_SILICATE] * f_melt_f) / mass_all[E_SILICATE];
	}
	silicate_melt[g] = f_melt;
	// The molten share of the ROCK: the lattice's melt over the lithic volume, so a partial melt of one
	// phase does not unlock a cell whose crystals still touch.
	float melt_share = v_lithic > 0.0 ? clamp(f_melt_l * v_sil * cem / v_lithic, 0.0, 1.0) : f_melt_l;

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
				float h_loose = mc_loose * (t_c + LA_KELVIN_OFFSET)
					+ la_entry_h(subs[E_SILICATE], mass_loose[E_SILICATE], t_c, p_pa, room_gas, pinned, progress);
				moved = h_loose * (cem_now - cem_was) / (1.0 - cem_was);
			}
			e_lith_j_m3[g] += moved * inv_vol;
			e_j_m3[g] -= moved * inv_vol;
		}
	}
	if (params.restate == 0u) {
		// The derived state, which breaks before the momentum does.
		float dv[3] = float[3](pressure[g], k_cond[g], rho);
		for (int i = 0; i < 3; ++i) {
			nf += (isnan(dv[i]) || isinf(dv[i])) ? 1.0 : 0.0;
		}
		nonfinite[g] = nf;
		unconverged[g] = converged ? 0.0 : 1.0;
	}

	// QUASI-STATIC ROCK: the lattice carries its weight (LA_APPROX quasi_static_solid_pressure), so
	// locked matter holds no bulk momentum and a cell that unlocks starts from rest.
	if (solid[g] != 0.0) {
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
