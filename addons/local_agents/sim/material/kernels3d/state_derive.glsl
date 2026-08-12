#[compute]
#version 450

layout(local_size_x = 64) in;

// enthalpy.glsli FIRST: Godot does not expand a nested #include inside a .glsli.
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"
#include "cellvol.glsli"

// Substance amounts, in the order StateDerivePass.CHANNELS declares. `channel_at` is that order.
layout(set = 0, binding = 0,  std430) restrict readonly buffer H2O { float h2o[]; };
layout(set = 0, binding = 1,  std430) restrict readonly buffer Silicate { float silicate[]; };
layout(set = 0, binding = 2,  std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 3,  std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 4,  std430) restrict readonly buffer O2 { float o2[]; };
layout(set = 0, binding = 5,  std430) restrict readonly buffer Co2 { float co2[]; };
layout(set = 0, binding = 6,  std430) restrict readonly buffer N2 { float n2[]; };
layout(set = 0, binding = 7,  std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 8,  std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 9,  std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 10, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 11, std430) restrict readonly buffer OrgH { float org_h[]; };
layout(set = 0, binding = 12, std430) restrict readonly buffer OrgO { float org_o[]; };
layout(set = 0, binding = 13, std430) restrict readonly buffer Fert { float fert[]; };

layout(set = 0, binding = 21, std430) restrict readonly buffer Enthalpy { float h_j_m3[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 23, std430) restrict writeonly buffer Temp { float temp[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Props { float props[]; };

// MOMENTUM is the state, kg m/s per m^3. Velocity is what you read off it once you know the mass.
layout(set = 0, binding = 25, std430) restrict readonly buffer MomX { float mom_x[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer MomY { float mom_y[]; };
layout(set = 0, binding = 27, std430) restrict readonly buffer MomZ { float mom_z[]; };
layout(set = 0, binding = 28, std430) restrict writeonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 29, std430) restrict writeonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 30, std430) restrict writeonly buffer VelZ { float vel_z[]; };

// What the pressure kernel needs and this pass already computes: the cell's gas in mol/m^3 and the
// density of its CONDENSED matter alone, kg/m^3.
layout(set = 0, binding = 31, std430) restrict writeonly buffer GasMol { float n_gas_m3[]; };
layout(set = 0, binding = 32, std430) restrict writeonly buffer RhoCond { float rho_cond[]; };
layout(set = 0, binding = 33, std430) restrict writeonly buffer Cond { float conductivity[]; };

// THE PHASE OF THE CELL'S H2O, as three shares of h2o[] summing to 1. Derived, never stored.
layout(set = 0, binding = 34, std430) restrict writeonly buffer H2OSolid { float h2o_solid[]; };
layout(set = 0, binding = 35, std430) restrict writeonly buffer H2OLiquid { float h2o_liquid[]; };
layout(set = 0, binding = 36, std430) restrict writeonly buffer H2OVapour { float h2o_vapour[]; };

// THE MELT SHARE OF THE CELL'S SILICATE: the lever rule across the solidus-liquidus interval. Derived from
// the same enthalpy ladder the temperature came off, never stored.
layout(set = 0, binding = 37, std430) restrict writeonly buffer SilicateMelt { float silicate_melt[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const int CHANNEL_SLOTS = 14;      // StateDerivePass.KERNEL_CHANNEL_SLOTS

// One row of `props` per channel, built from LASubstances by StateDerivePass.
const int PROP_STRIDE = 5;         // StateDerivePass.PROP_STRIDE
const int PROP_RHO = 0;            // kg/m^3 that one unit of fill carries
const int PROP_C = 1;              // J/kg/K, sensible-heat entry only
const int PROP_MOL_PER_KG = 2;     // mol/kg, non-condensable gases only
const int PROP_ENTRY = 3;          // which mixture entry the substance belongs to
const int PROP_LAMBDA = 4;         // W/m/K

// Mixture entries. Two substances carry a phase ladder; everything else is linear in T, so one entry with
// the summed mass and c = sum(m*c)/sum(m) reproduces sum(m_i*c_i*T) exactly.
const int E_H2O = 0;               // StateDerivePass.E_H2O
const int E_SILICATE = 1;          // StateDerivePass.E_SILICATE
const int E_SENSIBLE = 2;          // StateDerivePass.E_SENSIBLE
const int N_ENTRIES = 3;

float channel_at(int i, uint c) {
	switch (i) {
		case 0:  return h2o[c];
		case 1:  return silicate[c];
		case 2:  return carbonate[c];
		case 3:  return silica[c];
		case 4:  return o2[c];
		case 5:  return co2[c];
		case 6:  return n2[c];
		case 7:  return biomass[c];
		case 8:  return fungus[c];
		case 9:  return detritus[c];
		case 10: return fuel[c];
		case 11: return org_h[c];
		case 12: return org_o[c];
		case 13: return fert[c];
	}
	return 0.0;
}

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

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}

	float vol = cell_volume(g);

	float mass[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);
	float mc = 0.0;          // sum of m*c over the sensible-heat substances, J/K
	float n_gas_mol = 0.0;   // moles of non-condensable gas: the Dalton denominator of the vapour split
	float m_gas = 0.0;       // kg of that same gas, so the condensed density needs no mean molar mass
	float v_lambda = 0.0;    // volume-weighted conductivity, W/m/K
	float v_used = 0.0;

	for (int i = 0; i < CHANNEL_SLOTS; ++i) {
		float f = max(channel_at(i, g), 0.0);
		if (f <= 0.0) {
			continue;
		}
		int base = i * PROP_STRIDE;
		float m = f * props[base + PROP_RHO] * vol;
		int entry = int(props[base + PROP_ENTRY]);
		mass[entry] += m;
		if (entry == E_SENSIBLE) {
			mc += m * props[base + PROP_C];
		}
		v_lambda += f * props[base + PROP_LAMBDA];
		v_used += f;
		float mol_per_kg = props[base + PROP_MOL_PER_KG];
		n_gas_mol += m * mol_per_kg;
		if (mol_per_kg > 0.0) {
			m_gas += m;
		}
	}

	float total = mass[E_H2O] + mass[E_SILICATE] + mass[E_SENSIBLE];
	float inv_vol = (vol > 0.0) ? 1.0 / vol : 0.0;
	// Parallel mixing rule: the fluxes through each constituent add. An empty cell conducts nothing.
	conductivity[g] = (v_used > 0.0) ? v_lambda / v_used : 0.0;
	n_gas_m3[g] = n_gas_mol * inv_vol;
	rho_cond[g] = max(total - m_gas, 0.0) * inv_vol;
	if (total <= 0.0) {
		temp[g] = -LA_KELVIN_OFFSET;   // no matter, so no temperature
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		h2o_solid[g] = 0.0;
		h2o_liquid[g] = 0.0;
		h2o_vapour[g] = 0.0;
		silicate_melt[g] = 0.0;
		return;
	}
	// v = p/m. Nothing with no mass moves, and a light cell is pushed further by the same momentum.
	float inv_m = vol / total;
	vel_x[g] = mom_x[g] * inv_m;
	vel_y[g] = mom_y[g] * inv_m;
	vel_z[g] = mom_z[g] * inv_m;

	SubstanceTh subs[LA_MIX_MAX];
	subs[E_H2O] = la_h2o();
	subs[E_SILICATE] = la_silicate();
	subs[E_SENSIBLE] = la_sensible_only(mass[E_SENSIBLE] > 0.0 ? mc / mass[E_SENSIBLE] : 0.0);
	subs[3] = la_sensible_only(0.0);

	// No channel carries a dissolved solute, so the freezing point is not depressed.
	bool pinned = false;
	float progress = 0.0;
	float p_pa = max(pressure[g], 0.0);
	float t_c = la_mix_state(subs, mass, N_ENTRIES, h_j_m3[g] * vol, p_pa, n_gas_mol, 0.0,
		pinned, progress);
	temp[g] = t_c;

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

	// THE MELT SHARE OF THIS CELL'S SILICATE, off the SAME ladder. Rock has a melting INTERVAL, so the
	// lever rule the enthalpy curve already integrates over reads back as a linear share of the interval —
	// no plateau, no `pinned` branch, and the latent heat is what put t_c where it is.
	float f_melt = 0.0;
	if (mass[E_SILICATE] > 0.0) {
		SubstanceTh r = subs[E_SILICATE];
		float solidus = la_melt_c_at(r, p_pa, 0.0);
		float liquidus = la_liquidus_c_at(r, p_pa, 0.0);
		float width = liquidus - solidus;
		f_melt = width > 0.0 ? clamp((t_c - solidus) / width, 0.0, 1.0)
			: (t_c < solidus ? 0.0 : 1.0);
	}
	silicate_melt[g] = f_melt;
}
