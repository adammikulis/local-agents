#[compute]
#version 450

// CUBED-SPHERE MAGMA buoyant overpressure up-flow — the sphere port of magma_buoy3d.glsl. IDENTICAL two-pass
// GATHER logic and IDENTICAL constants/math; only neighbour addressing changes. The box read the cell ABOVE
// via `+layer` (guarded by iy<dim_y-1) and the cell BELOW via `-layer` (iy>0); here both come from the
// precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 5 = outward/UP (above), slot 0 = inward/DOWN (below);
// -1 = boundary → no flow. Only OVERPRESSURE (mass beyond MAX_MASS) is buoyed.
//
// WHERE THE CONSTANTS BELOW COME FROM. *(Corrected 2026-08-09. This line used to end "Constants copied EXACTLY
// from magma_buoy3d.glsl / MaterialMagma3D.gd, EXCEPT the two temperature constants, which are deleted", and the
// const block said "MUST match magma_buoy3d.glsl / MaterialMagma3D.gd exactly". BOTH named files are gone —
// MaterialMagma3D.gd went with the CPU oracle and magma_buoy3d.glsl went with the box kernels, and no `*3d.glsl`
// box original survives anywhere in kernels3d/. So the entire stated authority for this kernel's constants was
// two files that cannot be opened.)*
//
// CARRY-HEAT IS NO LONGER "VERBATIM" (2026-08-03). That word used to end the line above, and what it preserved
// was a rule that FLOORED a receiving cell at 950 C and never cooled the donor — heat appearing from nothing at
// every buoyant magma cell, every step. It is now a mass-weighted mix; see the note at the bottom of pass 1.
//   PASS 0 (copy):   scratch[i] = lava[i]  (stable snapshot for the gather).
//   PASS 1 (gather): lava[i] = scratch[i] - buoy_up(scratch[i], above open) + buoy_up(scratch[below], we open).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };       // lava[back] (rw)
layout(set = 0, binding = 1, std430) restrict buffer Scratch { float scratch[]; }; // stable snapshot
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };       // temp[back] (carry-heat)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = copy snapshot, 1 = gather/apply
	uint pad0;
	uint pad1;
} params;

// The substrate's cell-fill unit — authority LAMaterialField3D (MaterialField3D.gd:26). That file exists.
const float MAX_MASS = 1.0;

// --- MODEL PARAMETERS. Properties of THIS kernel's overpressure rule; this file is their only declaration.
// BUOY_FRAC is the linear share of a cell's overpressure that rises per step, K_P the pressure-dependent term
// that makes a larger surplus rise faster, MAX_UP_FLOW the per-step stability cap, MIN_OP the numerical floor.
//
// WHAT THEY STAND IN FOR, named so the model is not mistaken for the mechanism: magma rises because it is LESS
// DENSE than the rock around it, and that density contrast is measurable — basaltic melt is 2600-2800 kg/m^3
// against LAPhysical.ROCK_DENSITY_KG_M3 = 2900 for the crust it ascends through, a deficit of a few per cent
// which drives buoyancy against the melt's viscosity. Neither density nor viscosity appears here: the ascent
// rate is a fixed fraction of a mass surplus, so melt of any composition and any temperature rises identically.
// A rate derived from the real density contrast would be the honest form and is a physics change, not a comment.
const float BUOY_FRAC = 0.55;
const float K_P = 0.6;
const float MAX_UP_FLOW = 0.4;
const float MIN_OP = 0.0001;
// MOLTEN_FLOOR = 950.0 and LAVA_EMPLACE_TEMP = 1150.0 used to live here and are gone: this kernel no longer
// prescribes or caps a temperature, it mixes the arriving enthalpy with the destination's own.

// Buoyant up-transfer a cell contributes given its lava mass — mirrors _buoy_up exactly.
float buoy_up(float mass) {
	float op = mass - MAX_MASS;
	if (op < MIN_OP) {
		return 0.0;
	}
	float flow = op * (BUOY_FRAC + K_P * op);
	return clamp(flow, 0.0, min(MAX_UP_FLOW, op));
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;

	if (params.pass_id == 0u) {
		scratch[g] = lava[g];
		return;
	}

	// PASS 1: gather. Solid cells hold no lava — pass the snapshot through unchanged.
	if (solid[g] != 0.0) {
		lava[g] = scratch[g];
		return;
	}
	float base_mass = scratch[g];
	float out_up = 0.0;
	float in_below = 0.0;

	// UP (radially outward = slot 5): overpressure we shed into the open cell above.
	int iu = nbr[base + 5u];
	if (iu >= 0 && solid[iu] == 0.0) {
		out_up = buoy_up(scratch[g]);
	}
	// DOWN (radially inward = slot 0): overpressure the open cell below buoys up into us.
	int ib = nbr[base + 0u];
	if (ib >= 0 && solid[ib] == 0.0) {
		in_below = buoy_up(scratch[uint(ib)]);
	}
	lava[g] = base_mass - out_up + in_below;

	// MOLTEN HEAT RIDES UP WITH THE RECEIVED LAVA — a real mixing rule, not a floor.
	//
	// WHAT THIS REPLACES: the arriving heat used to be `min(temp[below], LAVA_EMPLACE_TEMP)` raised to at least
	// MOLTEN_FLOOR = 950 C, then written into this cell if it was cooler — so a cell receiving buoyed magma was
	// ASSIGNED 950 C even when the magma below it was colder than that, and the donor was never cooled for what
	// it gave away. THAT MADE HEAT APPEAR FROM NOTHING, at every buoyant magma cell, every step. The
	// LAVA_EMPLACE_TEMP cap is gone with it: the donor's real temperature is what arrives, so there is nothing
	// left to clamp.
	//
	// Now: T = (m_here*T_here + m_in*T_below) / (m_here + m_in), donor left at its own temperature. `m_here` is
	// MAX_MASS, one cell's worth of matter, because temp[] describes the whole cell and not just its magma —
	// see the matching note in lava_flow_sphere3d.glsl for why the cell's own lava mass is the wrong weight.
	if (in_below > 0.0 && ib >= 0) {
		temp[g] = (MAX_MASS * temp[g] + in_below * temp[uint(ib)]) / (MAX_MASS + in_below);
	}
}
