#[compute]
#version 450

//      cool_k = LAVA_COOL_RATE * clamp(EMPLACE_DEPTH / d, 0.25, 3.0) * (1.0 + EXPOSURE_GAIN * exposed);

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot
// 4.17e6 J/m3K of the ocean. Its own comment sent the reader upstream for the submerged case, to
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;   // only a defensive bound on the id read out of active_idx
	// speak of, because a relax rate needs neither. A FLUX does: it is W/m^2, and turning it into a
	float dt_s;
	float cell_size;
	uint pad2;
} params;

layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "rc_shared.glsli"

// --- MODEL PARAMETERS -------------------------------------------------------------------------------------
const float LAVA_MIN_MASS = 0.0001;
const float SOLIDIFY_TEMP = 800.0;
const float MAX_DT_PER_STEP = 5.0;
const int   MAX_SUBSTEPS = 8;

// at emissivity 0.95 radiates sigma*eps*T^4 = 5.670374419e-8 * 0.95 * 1423.15^4 = 2.21e5 W/m^2, i.e. 221
const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN
const float BASALT_EMIS = 0.95;        // LAPhysical.BASALT_EMISSIVITY — fresh basalt is near-black in the IR
const float KELVIN = 273.15;           // LAPhysical.KELVIN_OFFSET — T^4 is in KELVIN, and this is the whole
                                       // difference between 221 kW/m^2 and 8 kW/m^2 at an erupting temperature

void main() {
	// One invocation per ACTIVE cell. `active_args[3]` is the compacted list length; the trailing invocations
	uint t = gl_GlobalInvocationID.x;
	if (t >= active_args[3]) {
		return;
	}
	uint g = active_idx[t];
	if (g >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	// lava >= LAVA_MIN_MASS and solid == 0 were both applied by cell_list_lava_sphere3d.glsl when it appended
	if (temp[g] < SOLIDIFY_TEMP) {
		return;
	}

	float f_lava = clamp(lava[g], 0.0, 1.0);
	// upstream: heat3d_cool_sphere3d.glsl charges the latent heat of vaporisation against the seawater such a
	float cap = max(rc_of(g) * params.cell_size, 1.0);

	// The neighbour table is `cell*6 + slot`; the slot names are in neighbours.glsli.
	uint base = g * 6u;
	float faces = 0.0;      // how many faces emit, in units of a whole cell face
	float lw_in = 0.0;      // W/m^2 returning across those faces, held constant across the sub-steps
	for (int i = 0; i < 6; i++) {
		int nb = nbr[base + uint(i)];
		if (nb < 0) {
			if (i == 0) {
				continue;   // the core, not space
			}
			faces += 1.0;
			continue;
		}
		if (solid[nb] != 0.0) {
			continue;
		}
		if (lava[nb] > LAVA_MIN_MASS) {
			continue;       // interior molten face — conduction owns it
		}
		faces += 1.0;
		float tn = max(temp[nb] + KELVIN, 1.0);
		lw_in += BASALT_EMIS * STEFAN * tn * tn * tn * tn;
	}
	if (faces == 0.0) {
		return;             // sealed in rock: nothing to radiate into, and conduction already owns it
	}

	// SUB-STEPPED T^4 SINK, the integrator from heat3d_solar_sphere3d.glsl. Size the slicing from the change
	float t_c = temp[g];
	float tk0 = max(t_c + KELVIN, 1.0);
	float dt0 = f_lava * (faces * BASALT_EMIS * STEFAN * tk0 * tk0 * tk0 * tk0 - lw_in) * params.dt_s / cap;
	int slices = int(clamp(ceil(abs(dt0) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
	float sub_dt = params.dt_s / float(slices);
	for (int s = 0; s < slices; ++s) {
		float tk = max(t_c + KELVIN, 1.0);
		float em = f_lava * (faces * BASALT_EMIS * STEFAN * tk * tk * tk * tk - lw_in);
		t_c -= clamp(max(em, 0.0) * sub_dt / cap, 0.0, MAX_DT_PER_STEP);
	}
	temp[g] = t_c;
}
