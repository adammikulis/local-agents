#[compute]
#version 450

layout(local_size_x = 64) in;

// enthalpy.glsli FIRST: Godot does not expand a nested #include inside a .glsli.
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"
#include "cellvol.glsli"
#include "matter_channels.glsli"
#include "eos.glsli"

layout(set = 0, binding = 21, std430) restrict readonly buffer Enthalpy { float h_j_m3[]; };
layout(set = 0, binding = 22, std430) restrict buffer Pressure { float pressure[]; };
// Read as well as written: this pass is the ONE writer, and reads the temperature it replaces.
layout(set = 0, binding = 23, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Props { float props[]; };

// Cementation state and the solid flag. Read-modify-write: the lockup branch is hysteretic.
layout(set = 0, binding = 14, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict buffer Cement { float cement[]; };
layout(set = 0, binding = 16, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = 17, std430) restrict buffer Grain { float grain[]; };
// Cell centre, flat cell*3, model units. The centrifugal term needs the radius vector.
layout(set = 0, binding = 18, std430) restrict readonly buffer Pos { float pos[]; };
layout(set = 0, binding = 49, std430) restrict readonly buffer Grav { float g_field[]; };  // m/s^2, cell*3
// The body impulse this step deposits per cell (weight + rotating frame), kg/(m^2 s): the ledger's book.
layout(set = 0, binding = 50, std430) restrict writeonly buffer BodyFX { float bodyf_x[]; };
layout(set = 0, binding = 51, std430) restrict writeonly buffer BodyFY { float bodyf_y[]; };
layout(set = 0, binding = 52, std430) restrict writeonly buffer BodyFZ { float bodyf_z[]; };
// The mixture's sound speed, m/s: Wood's one-pressure compressibility sum over the cell's own matter.
layout(set = 0, binding = 53, std430) restrict buffer KCond { float k_cond[]; };
// Radiogenic power of this cell's own matter, W/m^3: sum over channels of amount * M * W/kg(mix, epoch).
// transport.glsl's RADIOGENIC leg deposits it into the enthalpy.
layout(set = 0, binding = 65, std430) restrict writeonly buffer RadW { float rad_w_m3[]; };

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

// The enthalpy each mixture entry holds, J/m^3, and the sensible entry's capacity, J/m^3/K.
layout(set = 0, binding = 45, std430) restrict writeonly buffer HH2O { float h_h2o[]; };
layout(set = 0, binding = 46, std430) restrict writeonly buffer HSilicate { float h_silicate[]; };
layout(set = 0, binding = 47, std430) restrict writeonly buffer HSensible { float h_sensible[]; };
layout(set = 0, binding = 48, std430) restrict writeonly buffer CapSensible { float cap_sensible[]; };

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
	float org_min_pool_mol; // moles of dead organic carbon below which a cell's C:H:O is fp32 noise
	float fresh_h_per_c;    // LASubstances.fresh_litter_per_carbon("H")
	float fresh_o_per_c;    // LASubstances.fresh_litter_per_carbon("O")
	float rho_floor;        // TransportPass.EMPTY_RHO_KG_M3: below this bulk density a cell is EMPTY
	float rad_w_kg_1;       // W/kg of radiogenic trace mix 1 at this epoch (PROP_RAD_GROUP indexes)
	float rad_w_kg_2;
	float rad_w_kg_3;
	float rad_w_kg_4;
	float sea_radius_m;     // the sea shell's radius from the body centre; 0 = the body carries no shell
} params;

const float SOLID_IN = 0.6;    // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float SOLID_OUT = 0.4;   // LAPhysical.RHEOLOGICAL_MOBILE_CRYSTAL_FRAC

// One row of `props` per channel, built from LASubstances by StateDerivePass. A channel amount is mol/m^3.
const int PROP_STRIDE = 11;        // StateDerivePass.PROP_STRIDE
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
const int PROP_RAD_GROUP = 10;     // 1-based index into params.rad_w_kg_*; 0 = no U/Th/K

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
		0,
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0),
		float[LA_MAX_EL](0.0, 0.0, 0.0)
	);
}

// The enthalpy one mixture entry holds at the state the solve landed on, J.
float la_entry_h(SubstanceTh s, float m_kg, float t_c, float p_pa, float n_gas_mol, bool pinned,
		float progress) {
	if (m_kg <= 0.0) {
		return 0.0;
	}
	float h = m_kg * la_mix_specific_enthalpy(s, t_c, p_pa, m_kg, n_gas_mol, 0.0);
	return pinned ? h + progress * la_mix_jump_of(s, m_kg, t_c, p_pa, n_gas_mol, 0.0) : h;
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
	alt[g] = (params.sea_radius_m > 0.0) ? r_len - params.sea_radius_m : uintBitsToFloat(0x7FC00000u);
	lat[g] = (w_len > 0.0 && r_len > 0.0)
		? degrees(asin(clamp(dot(r_vec / r_len, omega / w_len), -1.0, 1.0)))
		: uintBitsToFloat(0x7FC00000u);

	float nf = 0.0;
	for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
		float v = channel_at(i, g);
		nf += (isnan(v) || isinf(v)) ? 1.0 : 0.0;
	}
	float hv = h_j_m3[g];
	nf += (isnan(hv) || isinf(hv)) ? 1.0 : 0.0;
	vec3 pv = vec3(mom_x[g], mom_y[g], mom_z[g]);
	nf += (isnan(pv.x) || isinf(pv.x)) ? 1.0 : 0.0;
	nf += (isnan(pv.y) || isinf(pv.y)) ? 1.0 : 0.0;
	nf += (isnan(pv.z) || isinf(pv.z)) ? 1.0 : 0.0;

	// The dead pool's molar ratios, from the same channels the reduce rows sum.
	float org_pool = max(detritus[g], 0.0) + max(fuel[g], 0.0);
	if (org_pool * vol > params.org_min_pool_mol) {
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

	float mass[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);
	float mc = 0.0;          // sum of m*c over the sensible-heat substances, J/K
	float cp_gas = 0.0;      // sum of m*cp over the non-condensable gases, J/K: the mixture gamma's cp
	float n_gas_mol = 0.0;   // moles of non-condensable gas: the Dalton denominator of the vapour split
	float v_lambda = 0.0;    // volume-weighted conductivity, W/m/K
	float v_used = 0.0;
	float v_lithic = 0.0;    // volume fraction of rock and metal phases: what the solid flag reads
	float rad_w = 0.0;       // radiogenic power of the cell's matter, W/m^3
	// EOS sums: b* the unstressed condensed volume, c* its compressibility, h* the same for h2o alone.
	float b0 = 0.0; float b1 = 0.0; float b2 = 0.0;
	float c0 = 0.0; float c1 = 0.0; float c2 = 0.0;
	float hb0 = 0.0; float hb1 = 0.0; float hb2 = 0.0;
	float hc0 = 0.0; float hc1 = 0.0; float hc2 = 0.0;
	float mol_h2o = 0.0;

	for (int i = 0; i < LA_CHANNEL_SLOTS; ++i) {
		float f = max(channel_at(i, g), 0.0);
		if (f <= 0.0) {
			continue;
		}
		int base = i * PROP_STRIDE;
		float m = f * props[base + PROP_M] * vol;
		int entry = int(props[base + PROP_ENTRY]);
		mass[entry] += m;
		if (entry == E_SENSIBLE) {
			mc += m * props[base + PROP_C];
		}
		float vf = f / props[base + PROP_FULL];
		v_lambda += vf * props[base + PROP_LAMBDA];
		v_used += vf;
		v_lithic += props[base + PROP_LITHIC] > 0.0 ? vf : 0.0;
		rad_w += f * props[base + PROP_M] * rad_w_kg(int(props[base + PROP_RAD_GROUP]));
		n_gas_mol += m * props[base + PROP_MOL_PER_KG];
		if (props[base + PROP_MOL_PER_KG] > 0.0) {
			cp_gas += m * props[base + PROP_C];
		}
		// v0(T) is linear in T, so its mass sum splits into three T-independent pieces gathered here
		// and combined once the solve has a temperature. h2o is kept apart: its vapour share is gas.
		if (props[base + PROP_FULL] > 0.0 && props[base + PROP_MOL_PER_KG] <= 0.0) {
			float al = props[base + PROP_ALPHA];
			float tr = props[base + PROP_TREF];
			float kk = props[base + PROP_BULK];
			// The channel's unstressed condensed volume: its volume fraction of the cell, times the cell.
			float w0 = vf * vol;
			float w1 = w0 * al;
			bool is_water = entry == E_H2O;
			mol_h2o = is_water ? mol_h2o + f * vol : mol_h2o;
			b0 += is_water ? 0.0 : w0;
			b1 += is_water ? 0.0 : w1;
			b2 += is_water ? 0.0 : w1 * tr;
			hb0 += is_water ? w0 : 0.0;
			hb1 += is_water ? w1 : 0.0;
			hb2 += is_water ? w1 * tr : 0.0;
			if (kk > 0.0) {
				float q0 = w0 / kk;
				float q1 = w1 / kk;
				c0 += is_water ? 0.0 : q0;
				c1 += is_water ? 0.0 : q1;
				c2 += is_water ? 0.0 : q1 * tr;
				hc0 += is_water ? q0 : 0.0;
				hc1 += is_water ? q1 : 0.0;
				hc2 += is_water ? q1 * tr : 0.0;
			}
		}
	}

	rad_w_m3[g] = rad_w;
	float total = mass[E_H2O] + mass[E_SILICATE] + mass[E_SENSIBLE];
	float inv_vol = (vol > 0.0) ? 1.0 / vol : 0.0;
	// Parallel mixing rule: the fluxes through each constituent add. An empty cell conducts nothing.
	conductivity[g] = (v_used > 0.0) ? v_lambda / v_used : 0.0;
	float rho = total * inv_vol;     // kg/m^3, gas included: gravity pulls on all of it
	rho_bulk[g] = rho;
	float f_melt = 0.0;
	vec3 v = vec3(0.0);
	// Below the donation floor the cell is EMPTY: its stocks stay, its DERIVED bulk state does not.
	if (rho < params.rho_floor) {
		temp[g] = -LA_KELVIN_OFFSET;   // no matter, so no temperature
		if (solid[g] == 0.0) {
			pressure[g] = 0.0;
		}
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
		h_silicate[g] = 0.0;
		h_sensible[g] = 0.0;
		cap_sensible[g] = 0.0;
		bodyf_x[g] = 0.0;
		bodyf_y[g] = 0.0;
		bodyf_z[g] = 0.0;
		k_cond[g] = 0.0;
		lithify(g, f_melt, v_lithic);
		return;   // no mass, so the frame terms deliver no momentum either
	}
	// v = p/rho, momentum density over mass density. Dividing by the density rather than multiplying by
	// vol/total keeps the intermediate inside float range on a grid whose cells are kilometres wide.
	v = vec3(mom_x[g], mom_y[g], mom_z[g]) / rho;
	vel_x[g] = v.x;
	vel_y[g] = v.y;
	vel_z[g] = v.z;
	speed[g] = length(v);

	SubstanceTh subs[LA_MIX_MAX];
	subs[E_H2O] = la_h2o();
	subs[E_SILICATE] = la_silicate();
	subs[E_SENSIBLE] = la_sensible_only(mass[E_SENSIBLE] > 0.0 ? mc / mass[E_SENSIBLE] : 0.0);
	subs[3] = la_sensible_only(0.0);

	// No channel carries a dissolved solute, so the freezing point is not depressed.
	bool pinned = false;
	float progress = 0.0;
	float p_sat = 0.0;
	if (mol_h2o > 0.0) {
		float ps = la_saturation_p_at(subs[E_H2O], temp[g]);
		float tk_last = max(temp[g] + LA_KELVIN_OFFSET, 1.0);
		if (mol_h2o > ps * vol / (LA_R_J_MOL_K * tk_last)) {
			p_sat = ps;
		}
	}
	// CONDENSED PHASE IS PRESENT when the cell holds more h2o than saturated vapour would fill it with.
	float p_pa = max(max(pressure[g], 0.0), p_sat);
	float t_c = la_mix_state(subs, mass, N_ENTRIES, h_j_m3[g] * vol, p_pa, n_gas_mol, 0.0,
		pinned, progress);
	temp[g] = t_c;

	// The decomposition la_mix_enthalpy_at sums, kept per entry so transport moves heat with matter.
	h_h2o[g] = la_entry_h(subs[E_H2O], mass[E_H2O], t_c, p_pa, n_gas_mol, pinned, progress) * inv_vol;
	h_silicate[g] = la_entry_h(subs[E_SILICATE], mass[E_SILICATE], t_c, p_pa, n_gas_mol, pinned,
		progress) * inv_vol;
	h_sensible[g] = la_entry_h(subs[E_SENSIBLE], mass[E_SENSIBLE], t_c, p_pa, n_gas_mol, pinned,
		progress) * inv_vol;
	cap_sensible[g] = mc * inv_vol;

	// THE PHASE SPLIT OF THIS CELL'S H2O, off the SAME ladder and the SAME saturation curve the solve used.
	// `progress` is where inside a latent plateau the enthalpy landed, so a cell held at the melting point
	// reports a partial solid share instead of flipping.
	float m_h2o = mass[E_H2O];
	float f_solid = 0.0;
	float f_liquid = 0.0;
	float f_vapour = 0.0;
	if (m_h2o > 0.0) {
		SubstanceTh w = subs[E_H2O];
		bool has_vap = false;
		float vap_t = la_mix_vapour_boundary_c(w, p_pa, has_vap);
		float melt_t = la_melt_c_at(w, p_pa, 0.0);
		float molten = 0.0;
		// Which plateau the mixture is pinned on: the boundary the cell temperature is NEARER. Comparing the
		// two distances needs no tolerance, where comparing t_c to a boundary for equality would.
		bool at_vapour = pinned && has_vap && abs(t_c - vap_t) <= abs(t_c - melt_t);
		if (at_vapour) {
			f_vapour = progress;
			// Below the triple point the condensate leaving is SOLID; above it, liquid.
			molten = la_sublimes_at(w, p_pa) ? 0.0 : 1.0;
		} else {
			f_vapour = la_mix_vapour_fraction(w, t_c, p_pa, m_h2o, n_gas_mol, 0.0);
			molten = pinned ? progress : (t_c < melt_t ? 0.0 : 1.0);
		}
		float condensed = max(1.0 - f_vapour, 0.0);
		f_solid = condensed * (1.0 - molten);
		f_liquid = condensed * molten;
	}
	h2o_solid[g] = f_solid;
	h2o_liquid[g] = f_liquid;
	h2o_vapour[g] = f_vapour;
	liquid[g] = max(h2o[g], 0.0) * f_liquid;

	// PRESSURE, off this cell's own matter and energy. The vapour share joins the gas term and what is
	// left of the water is condensed. No column is walked, so there is no staircase to integrate along.
	float f_cond = max(1.0 - f_vapour, 0.0);
	float b_vol = (b0 + t_c * b1 - b2) + f_cond * (hb0 + t_c * hb1 - hb2);
	float c_comp = (c0 + t_c * c1 - c2) + f_cond * (hc0 + t_c * hc1 - hc2);
	float n_gas = n_gas_mol + f_vapour * mol_h2o;
	float tk = max(t_c + LA_KELVIN_OFFSET, 1.0);
	// THE VOID OVER A CONDENSED PHASE IS ITS OWN VAPOUR, at the saturation pressure of the most volatile.
	if (mass[E_SILICATE] > 0.0) {
		p_sat = max(p_sat, la_saturation_p_at(subs[E_SILICATE], t_c));
	}
	// Rock is quasi-static and PressurePass owns it; an open cell's pressure is its own state.
	if (solid[g] == 0.0) {
		pressure[g] = la_eos_p(vol, n_gas * LA_R_J_MOL_K * tk, b_vol, c_comp, LA_P_STD, p_sat);
	}

	k_cond[g] = c_comp > 0.0 ? b_vol / c_comp : 0.0;

	// THE MELT SHARE OF THIS CELL'S SILICATE, off the SAME ladder. Rock has a melting INTERVAL, so the
	// lever rule the enthalpy curve already integrates over reads back as a linear share of the interval —
	// no plateau, no `pinned` branch, and the latent heat is what put t_c where it is.
	if (mass[E_SILICATE] > 0.0) {
		SubstanceTh r = subs[E_SILICATE];
		float solidus = la_melt_c_at(r, p_pa, 0.0);
		float liquidus = la_liquidus_c_at(r, p_pa, 0.0);
		float width = liquidus - solidus;
		f_melt = width > 0.0 ? clamp((t_c - solidus) / width, 0.0, 1.0)
			: (t_c < solidus ? 0.0 : 1.0);
	}
	silicate_melt[g] = f_melt;

	lithify(g, f_melt, v_lithic);

	// The derived state, which breaks before the momentum does.
	float dv[3] = float[3](pressure[g], k_cond[g], rho);
	for (int i = 0; i < 3; ++i) {
		nf += (isnan(dv[i]) || isinf(dv[i])) ? 1.0 : 0.0;
	}
	nonfinite[g] = nf;

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
		bodyf_x[g] = 0.0;
		bodyf_y[g] = 0.0;
		bodyf_z[g] = 0.0;
		return;
	}
	// BODY FORCES per volume: weight rho*g and the rotating-frame pair, computed and booked here;
	// transport deposits them a substep at a time beside the pressure gradient they stand against.
	vec3 acc = vec3(g_field[g * 3u], g_field[g * 3u + 1u], g_field[g * 3u + 2u]);
	if (w_len > 0.0) {
		acc += -2.0 * cross(omega, v) - cross(omega, cross(omega, r_vec));
	}
	vec3 dp = acc * rho * params.dt_s;
	bodyf_x[g] = dp.x;
	bodyf_y[g] = dp.y;
	bodyf_z[g] = dp.z;
}
