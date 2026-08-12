#[compute]
#version 450

// Radiative cooling of molten cells, as a CROSS-CELL EXCHANGE. Two dispatches of this one shader:
//   mode 0 — over the compacted lava list. Cools each molten cell and writes the joules it shed into

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };
// J/m^2 landing on cell*6 + slot this step. Written by mode 0, consumed and zeroed by mode 1.
layout(set = 0, binding = 3, std430) restrict buffer RadDep { float rad_dep[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot
// The answering slot on the far side of each link, resolved by LASphereGrid. idx*6 + slot -> nb*6 + reverse.
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };
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
	uint cell_count;   // mode 1 bound; in mode 0 only a defensive bound on the id read out of active_idx
	float dt_s;
	float cell_size;   // metres
	uint mode;         // 0 = emit, 1 = deposit
	float lava_min;    // CellListPass.LAVA_MIN_MASS — the same threshold that built the active list
} params;

layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "rc_shared.glsli"
#include "neighbours.glsli"

// --- MODEL PARAMETERS -------------------------------------------------------------------------------------
const float SOLIDIFY_TEMP = 1000.0;    // LAPhysical.BASALT_SOLIDUS_C
const float MAX_DT_PER_STEP = 5.0;
const int   MAX_SUBSTEPS = 8;

const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN
const float BASALT_EMIS = 0.95;        // LAPhysical.BASALT_EMISSIVITY — fresh basalt is near-black in the IR
const float KELVIN = 273.15;           // LAPhysical.KELVIN_OFFSET — T^4 is in kelvin

// Volumetric heat capacity of cell i times the cell depth: J/m^2/K.
float cap_of(uint i) {
	return max(rc_of(i) * params.cell_size, 1.0);
}

// mode 0. One invocation per ACTIVE cell. `active_args[3]` is the compacted list length; the trailing
// invocations of the last workgroup (and the single idle group dispatched when the list is empty) fall
// out here.
void emit() {
	uint t = gl_GlobalInvocationID.x;
	if (t >= active_args[3]) {
		return;
	}
	uint g = active_idx[t];
	if (g >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	// The list's own predicate already applied lava >= lava_min and solid == 0 when it appended this
	// cell, so a listed cell has already passed them.
	if (temp[g] < SOLIDIFY_TEMP) {
		return;
	}

	float f_lava = clamp(lava[g], 0.0, 1.0);
	float cap = cap_of(g);

	// The neighbour table is `cell*6 + slot` with slot 0 = INWARD (radial down), 1-4 lateral, 5 = OUTWARD.
	//   * slot 5 with nbr < 0 — the top of the atmosphere, i.e. space. Nothing comes back (the 2.7 K
	uint base = g * 6u;
	float tn_c[6];     // the neighbour across emitting face k, deg C; carried forward across the sub-steps
	float cap_n[6];    // that neighbour's J/m^2/K (0 for a face onto space)
	int   dst[6];      // rad_dep slot to credit, or -1 for a face onto space
	int   nf = 0;
	float lw_in = 0.0; // W/m^2 returning across the emitting faces at the start of the step
	for (uint i = 0u; i < 6u; i++) {
		int nb = nbr[base + i];
		if (nb < 0) {
			if (i == N_IN) {
				continue;   // the core, not space
			}
			tn_c[nf] = 0.0;
			cap_n[nf] = 0.0;
			dst[nf] = -1;
			nf++;
			continue;
		}
		if (solid[nb] != 0.0) {
			continue;
		}
		if (lava[nb] > params.lava_min) {
			continue;
		}
		float tn = max(temp[nb] + KELVIN, 1.0);
		lw_in += BASALT_EMIS * STEFAN * tn * tn * tn * tn;
		tn_c[nf] = temp[nb];
		cap_n[nf] = cap_of(uint(nb));
		dst[nf] = partner[base + i];
		nf++;
	}
	if (nf == 0) {
		return;             // sealed in rock: nothing to radiate into, and conduction already owns it
	}

	// SUB-STEPPED T^4 SINK, the integrator from heat3d_solar_sphere3d.glsl. Size the slicing from the change
	// the first evaluation implies, then re-evaluate both sides of every face as they converge, so the result
	// lands on the same energy instead of being truncated at the clamp.
	float t_c = temp[g];
	float tk0 = max(t_c + KELVIN, 1.0);
	float dt0 = f_lava * (float(nf) * BASALT_EMIS * STEFAN * tk0 * tk0 * tk0 * tk0 - lw_in) * params.dt_s / cap;
	int slices = int(clamp(ceil(abs(dt0) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
	float sub_dt = params.dt_s / float(slices);

	float dep[6];
	for (int k = 0; k < 6; k++) {
		dep[k] = 0.0;
	}
	for (int s = 0; s < slices; ++s) {
		float tk = max(t_c + KELVIN, 1.0);
		float e4 = BASALT_EMIS * STEFAN * tk * tk * tk * tk;
		float e[6];
		float moved = 0.0;
		for (int k = 0; k < nf; k++) {
			float lw = 0.0;
			if (dst[k] >= 0) {
				float tn = max(tn_c[k] + KELVIN, 1.0);
				lw = BASALT_EMIS * STEFAN * tn * tn * tn * tn;
			}
			// Net radiant energy out of this cell across face k, J/m^2 over the slice.
			float ek = f_lava * (e4 - lw) * sub_dt;
			if (dst[k] >= 0) {
				// A radiative exchange cannot carry the pair past equal temperature. Beyond that the flux
				// reverses, so this is the physical bound, not a rate cap; what it holds back stays in the
				// donor and is offered again next slice.
				float lim = (t_c - tn_c[k]) / (1.0 / cap + 1.0 / cap_n[k]);
				ek = (ek > 0.0) ? min(ek, max(lim, 0.0)) : max(ek, min(lim, 0.0));
			}
			e[k] = ek;
			moved += ek;
		}
		// Slice rate clamp, applied to every face in proportion so the sum still equals the cell's own drop.
		float budget = MAX_DT_PER_STEP * cap;
		if (abs(moved) > budget) {
			float scale = budget / abs(moved);
			for (int k = 0; k < nf; k++) {
				e[k] *= scale;
			}
			moved *= scale;
		}
		t_c -= moved / cap;
		for (int k = 0; k < nf; k++) {
			dep[k] += e[k];
			if (dst[k] >= 0) {
				tn_c[k] += e[k] / cap_n[k];
			}
		}
	}
	temp[g] = t_c;
	// Every (receiver, slot) pair has exactly one donor, so this is a plain store, not a read-modify-write.
	// A face onto space carries its share out of the planet and is booked nowhere yet.
	for (int k = 0; k < nf; k++) {
		if (dst[k] >= 0) {
			rad_dep[dst[k]] = dep[k];
		}
	}
}

// mode 1. One invocation per cell: take the joules mode 0 aimed here and clear the slots for next step.
void deposit() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;
	float j = 0.0;
	for (uint d = 0u; d < 6u; d++) {
		j += rad_dep[base + d];
		rad_dep[base + d] = 0.0;
	}
	if (j != 0.0) {
		temp[g] += j / cap_of(g);
	}
}

void main() {
	if (params.mode == 0u) {
		emit();
	} else {
		deposit();
	}
}
