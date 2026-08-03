#[compute]
#version 450

// CUBED-SPHERE heat conduction. Every cell gathers its 6 neighbours from the precomputed INDEX TABLE
// `nbr[idx*6 + d]` (slot 0 = inward/down, 1-4 lateral, 5 = outward/up; -1 = boundary). This is the mechanical
// transformation every field kernel follows for the sphere: `int nb = nbr[idx*6+d]; if (nb >= 0) …`.
//
// ===== WHAT THIS KERNEL IS, AND WHAT IT USED TO BE =========================================================
//
// It is a conservative finite-volume conduction step: heat crosses each bond driven by the INTERFACE
// conductivity, and the temperature change it causes in a cell is divided by THAT CELL'S OWN volumetric heat
// capacity. Both halves matter and the old kernel had neither.
//
// The old kernel exchanged a fixed FRACTION of the temperature difference per bond, chosen by phase:
//     const float VOID_CONDUCT = 0.0015;   // "air/water mixes briskly"
//     const float ROCK_CONDUCT = 0.0002;   // "so the crust actually INSULATES"
// with a comment saying outright: "Tuned so a 1300 C core coexists with a temperate (~15-30 C) surface."
// That is a fitted physical constant, and it was fitted to hide a broken premise. Two things were wrong.
//
//   1. IT CONSERVED TEMPERATURE, NOT ENERGY. A symmetric per-bond fraction moves the same number of degrees
//      out of one cell as it moves into the other, whatever those cells are made of. In the world, a cubic
//      metre of rock holds 2050x the heat of a cubic metre of air per degree, so ground warming the air above
//      it barely cools itself. Nothing in the old expression could produce that asymmetry, so the atmosphere
//      and the crust dragged each other around as equals.
//
//   2. THE TWO NUMBERS WERE THE WRONG QUANTITY. Heat flows with CONDUCTIVITY lambda, where rock beats air
//      about 100x (2.5 against 0.026 W/m/K). Temperature spreads with DIFFUSIVITY alpha = lambda/(rho*c),
//      where air beats rock 21x (2.19e-5 against 1.03e-6 m^2/s). The old pair matched neither ordering; it
//      was picked to make a number come out.
//
// ===== WHY THE FITTED NUMBERS WERE NEEDED, AND WHAT REPLACED THE NEED =====================================
//
// The premise they were defending is that a hot core can sit a short distance under a temperate surface. It
// cannot, and no conductivity fixes that. In steady state a conductive path carries q = lambda * dT / L, so
// 5200 C at 340 m under a 15 C surface demands q = 2.5 * 5185 / 340 = 38 W/m^2 — 440x Earth's 0.087 W/m^2.
// Earth gets away with a 5200 C core because L is 6371 KILOMETRES, not because rock insulates.
//
// So the geothermal boundary stopped being a temperature and became a FLUX. `params.core_dt` is the degrees
// that flux adds to one innermost-shell cell this step, computed by LAMaterialFieldGeotherm3D from a FINITE
// reservoir that cools as it supplies. It enters here, at the inward boundary (slot 0 has no neighbour only
// at r = 0), because that is exactly what it is: the conduction the unsimulated interior delivers to the
// bottom face of the simulated shell. There is no cell held at a constant temperature anywhere any more.
//
// With real alpha, conduction through rock moves heat 1 metre in ~10 days. It is negligible on every
// timescale this simulation runs, which is correct and is the point: a planet's interior heat reaches its
// surface by ADVECTION (magma_buoy_sphere3d, plate tectonics, eruptions), not by conduction. The old
// kernel's job of carrying core heat to the crust was work the world does not do.
//
// ===== STABILITY ==========================================================================================
// Explicit FTCS is stable while the sum of the per-bond coefficients over <= 6 bonds stays below 0.5. The
// worst case here is an air cell (smallest rho*c) bonded to rock on all six faces: lambda_interface 0.0515,
// so k = 0.0515 * dt_over_dx2 / 1186 = 7.3e-6 at this world's step and cell, and 6 of those is 4.4e-5. The
// real values are four orders of magnitude INSIDE the limit — the timestep problem this kernel could have had
// runs the other way, and no sub-stepping is needed. Double-buffered (read temp_in, write temp_out).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// Water fraction, so an ocean cell conducts and stores heat as WATER rather than as air. This is the ocean's
// thermal inertia (the same term heat3d_solar_sphere3d already carries as HEAT_CAP_WATER) finally reaching
// conduction, and it is why a coast is milder than an inland plain at the same latitude.
layout(set = 0, binding = 4, std430) restrict readonly buffer Water { float water[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	// Degrees this step's geothermal flux adds to ONE innermost-shell cell. Owned by
	// LAMaterialFieldGeotherm3D, which computes it from a finite reservoir and debits the reservoir by
	// exactly what it hands over here. Zero when the core is disarmed.
	float core_dt;
	// dt / dx^2 in SECONDS PER SQUARE METRE — this world's step length and cell size, NOT a property of
	// matter, so it is pushed rather than hardcoded (LASphereThermalPass derives it from the grid's own
	// cell_size and the sim clock's day length). Multiplying a diffusivity by it gives the dimensionless
	// per-step diffusion number.
	float dt_over_dx2;
	uint pad2;
} params;

// ===== MEASURED PROPERTIES OF MATTER ======================================================================
// Conductivities (W/m/K) and volumetric heat capacities (J/m^3/K). GLSL cannot read GDScript, so these are
// copies; scripts/check_physical_constants.sh holds them equal to the authority.
const float LAMBDA_ROCK  = 2.5;      // LAPhysical.THERMAL_CONDUCT_ROCK_W_MK
const float LAMBDA_AIR   = 0.026;    // LAPhysical.THERMAL_CONDUCT_AIR_W_MK
const float LAMBDA_WATER = 0.60;     // LAPhysical.THERMAL_CONDUCT_WATER_W_MK
const float RC_ROCK  = 2.436e6;      // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_AIR   = 1186.0;       // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_WATER = 4.171e6;      // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K

// A cell's conductivity and heat capacity from what it is made of. An open cell is air with a water
// fraction mixed in; a solid cell is rock. (Snow rides the solar kernel's capacity term, not this one —
// it is a surface skin, and conduction through it is not what sets its temperature.)
float lambda_of(uint i) {
	if (solid[i] != 0.0) {
		return LAMBDA_ROCK;
	}
	return mix(LAMBDA_AIR, LAMBDA_WATER, clamp(water[i], 0.0, 1.0));
}

float rc_of(uint i) {
	if (solid[i] != 0.0) {
		return RC_ROCK;
	}
	return mix(RC_AIR, RC_WATER, clamp(water[i], 0.0, 1.0));
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	float here = temp_in[idx];
	float rc_here = rc_of(idx);
	float lam_here = lambda_of(idx);
	float delta = 0.0;
	for (int d = 0; d < 6; d++) {
		int nb = nbr[idx * 6u + uint(d)];
		if (nb < 0) {
			// The one boundary that is not empty space: slot 0 has no inward neighbour only at r = 0, the
			// bottom face of the shell, where the unsimulated interior delivers its conductive flux.
			if (d == 0) {
				delta += params.core_dt;
			}
			continue;
		}
		// Two half-cells in SERIES across the bond, so the interface conductivity is their harmonic mean —
		// a rock/air face is throttled by the air side, which is what makes soil under snow stay warm.
		float lam_nb = lambda_of(uint(nb));
		float lam_i = 2.0 * lam_here * lam_nb / max(lam_here + lam_nb, 1e-12);
		// dT_here = lambda_i * (T_nb - T_here) * dt / (rho*c_here * dx^2). The receiving cell's OWN capacity
		// divides, which is the asymmetry that lets hot rock warm the air above it without cooling much.
		delta += (lam_i * params.dt_over_dx2 / rc_here) * (temp_in[nb] - here);
	}
	temp_out[idx] = here + delta;
}
