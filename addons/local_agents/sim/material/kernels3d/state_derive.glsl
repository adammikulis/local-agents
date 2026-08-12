#[compute]
#version 450

layout(local_size_x = 64) in;

// enthalpy.glsli FIRST: Godot does not expand a nested #include inside a .glsli.
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"
#include "cellvol.glsli"

// Substance amounts, in the order StateDerivePass.CHANNELS declares. `channel_at` is that order.
layout(set = 0, binding = 0,  std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 1,  std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 2,  std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 3,  std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 4,  std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 5,  std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 6,  std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 7,  std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 8,  std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 9,  std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 10, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 11, std430) restrict readonly buffer O2 { float o2[]; };
layout(set = 0, binding = 12, std430) restrict readonly buffer Co2 { float co2[]; };
layout(set = 0, binding = 13, std430) restrict readonly buffer N2 { float n2[]; };
layout(set = 0, binding = 14, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 16, std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 18, std430) restrict readonly buffer OrgH { float org_h[]; };
layout(set = 0, binding = 19, std430) restrict readonly buffer OrgO { float org_o[]; };
layout(set = 0, binding = 20, std430) restrict readonly buffer Fert { float fert[]; };

layout(set = 0, binding = 21, std430) restrict readonly buffer Enthalpy { float h_j_m3[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 23, std430) restrict writeonly buffer Temp { float temp[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Props { float props[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const int CHANNEL_SLOTS = 21;      // StateDerivePass.KERNEL_CHANNEL_SLOTS

// One row of `props` per channel, built from LASubstances by StateDerivePass.
const int PROP_STRIDE = 5;         // StateDerivePass.PROP_STRIDE
const int PROP_RHO = 0;            // kg/m^3 that one unit of fill carries
const int PROP_C = 1;              // J/kg/K, sensible-heat entry only
const int PROP_MOL_PER_KG = 2;     // mol/kg, non-condensable gases only
const int PROP_ENTRY = 3;          // which mixture entry the substance belongs to
const int PROP_SAT = 4;            // 1 = saturation of the pore-free share, not a cell volume fraction

// Mixture entries. Two substances carry a phase ladder; everything else is linear in T, so one entry with
// the summed mass and c = sum(m*c)/sum(m) reproduces sum(m_i*c_i*T) exactly.
const int E_H2O = 0;               // StateDerivePass.E_H2O
const int E_SILICATE = 1;          // StateDerivePass.E_SILICATE
const int E_SENSIBLE = 2;          // StateDerivePass.E_SENSIBLE
const int N_ENTRIES = 3;

float channel_at(int i, uint c) {
	switch (i) {
		case 0:  return water[c];
		case 1:  return moisture[c];
		case 2:  return snow[c];
		case 3:  return soil[c];
		case 4:  return lava[c];
		case 5:  return rock_fill[c];
		case 6:  return sediment[c];
		case 7:  return susp[c];
		case 8:  return dust[c];
		case 9:  return carbonate[c];
		case 10: return silica[c];
		case 11: return o2[c];
		case 12: return co2[c];
		case 13: return n2[c];
		case 14: return biomass[c];
		case 15: return fungus[c];
		case 16: return detritus[c];
		case 17: return fuel[c];
		case 18: return org_h[c];
		case 19: return org_o[c];
		case 20: return fert[c];
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
	float phi = clamp(porosity[g], 0.0, 1.0);

	float mass[LA_MIX_MAX] = float[LA_MIX_MAX](0.0, 0.0, 0.0, 0.0);
	float mc = 0.0;          // sum of m*c over the sensible-heat substances, J/K
	float n_gas_mol = 0.0;   // moles of non-condensable gas: the Dalton denominator of the vapour split

	for (int i = 0; i < CHANNEL_SLOTS; ++i) {
		float f = max(channel_at(i, g), 0.0);
		if (f <= 0.0) {
			continue;
		}
		int base = i * PROP_STRIDE;
		if (props[base + PROP_SAT] != 0.0) {
			f *= 1.0 - phi;
		}
		float m = f * props[base + PROP_RHO] * vol;
		int entry = int(props[base + PROP_ENTRY]);
		mass[entry] += m;
		if (entry == E_SENSIBLE) {
			mc += m * props[base + PROP_C];
		}
		n_gas_mol += m * props[base + PROP_MOL_PER_KG];
	}

	float total = mass[E_H2O] + mass[E_SILICATE] + mass[E_SENSIBLE];
	if (total <= 0.0) {
		temp[g] = -LA_KELVIN_OFFSET;   // no matter, so no temperature
		return;
	}

	SubstanceTh subs[LA_MIX_MAX];
	subs[E_H2O] = la_h2o();
	subs[E_SILICATE] = la_silicate();
	subs[E_SENSIBLE] = la_sensible_only(mass[E_SENSIBLE] > 0.0 ? mc / mass[E_SENSIBLE] : 0.0);
	subs[3] = la_sensible_only(0.0);

	// No channel carries a dissolved solute, so the freezing point is not depressed.
	bool pinned = false;
	float progress = 0.0;
	temp[g] = la_mix_state(subs, mass, N_ENTRIES, h_j_m3[g] * vol, max(pressure[g], 0.0),
		n_gas_mol, 0.0, pinned, progress);
}
