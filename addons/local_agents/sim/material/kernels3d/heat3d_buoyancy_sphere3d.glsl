#[compute]
#version 450

#include "neighbours.glsli"

// Dry convective adjustment (Manabe & Strickler 1964), one thread per radial column.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
// Bound for rc_shared.glsli, not read here.
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };

layout(push_constant, std430) uniform Params {
	uint column_count;
	uint depth;
	uint pad0;
	uint pad1;
} params;

const float GRAVITY_M_S2 = 9.80665;        // LAPhysical.STANDARD_GRAVITY_M_S2
const float AIR_DENSITY_KG_M3 = 1.225;     // LAPhysical.AIR_DENSITY_KG_M3
const float METRES_PER_MODEL_UNIT = 168.6; // LAPhysical.METRES_PER_MODEL_UNIT

layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "shell.glsli"
#include "cellvol.glsli"
#include "rc_shared.glsli"

// Adiabatic lapse rate of cell i, K/m. Only the gas does pdV work, so pure air gives g/c_p.
float lapse_of(uint i) {
	return f_air_of(i) * AIR_DENSITY_KG_M3 * GRAVITY_M_S2 / max(rc_of(i), 1.0);
}

void main() {
	uint s = gl_GlobalInvocationID.x;
	if (s >= params.column_count) {
		return;
	}
	uint depth = params.depth;
	uint base = s * depth;
	for (uint r = 0u; r < depth; ++r) {
		temp_out[base + r] = temp_in[base + r];
	}
	for (uint r = 0u; r + 1u < depth; ++r) {
		uint lo = base + r;
		uint hi = lo + 1u;
		if (solid[lo] != 0.0 || solid[hi] != 0.0) {
			continue;
		}
		float dz = shell_d_out(r) * METRES_PER_MODEL_UNIT;
		float excess = (temp_out[lo] - temp_out[hi]) - lapse_of(lo) * dz;
		if (excess <= 0.0) {
			continue;
		}
		float m3 = METRES_PER_MODEL_UNIT * METRES_PER_MODEL_UNIT * METRES_PER_MODEL_UNIT;
		float vol_lo = cell_volume(lo) * m3;
		float vol_hi = cell_volume(hi) * m3;
		float c_lo = max(rc_of(lo) * vol_lo, 1e-30);
		float c_hi = max(rc_of(hi) * vol_hi, 1e-30);
		temp_out[lo] -= excess / (1.0 + c_lo / c_hi);
		temp_out[hi] += excess / (1.0 + c_hi / c_lo);
	}
}
