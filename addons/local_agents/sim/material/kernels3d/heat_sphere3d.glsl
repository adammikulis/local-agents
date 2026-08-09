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
// So the geothermal boundary stopped being a temperature and became a CONDUCTION BOND. `params.core_boundary_c`
// is the temperature of the rock immediately below the shell's bottom face — a GHOST CELL — published by
// LAMaterialFieldGeotherm3D from a finite reservoir that cools as it supplies. It enters at slot 0's missing
// neighbour (slot 0 has no neighbour only at r = 0) through the SAME finite-volume expression every real
// neighbour uses, because that is exactly what it is: a seventh neighbour made of rock. Nothing anywhere is
// held at a constant temperature.
//
// WHY A GHOST CELL AND NOT THE 340 m PATH TO THE PLANET'S CENTRE. The unsimulated interior CONVECTS, and a
// convecting body is nearly isothermal in its bulk with its whole temperature drop across a thin boundary
// layer at the top — so its conductive resistance is one cell of rock, not its radius. Earth agrees: its
// measured 0.087 W/m^2 is ~27x what pure conduction through 2890 km of mantle would deliver.
//
// AND WHY PER CELL. The previous version pushed one scalar `core_dt`, the degrees to add to every r == 0
// cell, computed on the CPU from the shell's MEAN temperature. A global mean cannot answer a local question:
// a base cell under a thin ocean-basin crust and one under a mountain root draw different amounts, and with
// a bond they do, for free.
//
// With real alpha, conduction through rock moves heat 1 metre in ~10 days. It is negligible on every
// timescale this simulation runs, which is correct and is the point: a planet's interior heat reaches its
// surface by ADVECTION (magma_buoy_sphere3d, plate tectonics, eruptions), not by conduction. That is also
// why the geotherm is SEEDED as an initial condition rather than established at runtime — see
// LAMaterialFieldGeotherm3D's header. The old kernel's job of carrying core heat to the crust was work the
// world does not do.
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
// What the cell is MADE OF, so it conducts and stores heat as that rather than as air. This is the ocean's
// thermal inertia — the same mix heat3d_solar_sphere3d.glsl uses for its areal capacity — reaching conduction,
// and it is why a coast is milder than an inland plain at the same latitude. *(snow + rock_fill added
// 2026-08-03: the solar kernel counted a surface cell's regolith and snowpack in its heat capacity and this one
// did not, so two kernels in the same pass disagreed about how much heat the same cell holds.)*
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
// CARRIERS THIS KERNEL DOES NOT USE ITSELF, bound because rc_shared.glsli needs every one of them.
// Leaving one out is exactly the divergence that file exists to end.
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	// Temperature (deg C) of the ROCK GHOST CELL one shell below the grid's bottom face — the top of the
	// convecting interior. Owned by LAMaterialFieldGeotherm3D, which seeds it on the crustal geotherm and
	// debits its finite reservoir by exactly what crosses the bond. <= 0 means the interior is DISARMED, and
	// the bond is skipped entirely rather than dragging the base of the crust toward absolute zero.
	float core_boundary_c;
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
const float LAMBDA_SNOW  = 0.15;     // LAPhysical.THERMAL_CONDUCT_SNOW_W_MK

// A cell's conductivity and heat capacity from what it is made of, by VOLUME FRACTION — `water`, `rock_fill`
// and `snow` are all fractions of the cell (SolidDerivePass: solid iff rock_fill >= 0.5) and air fills the
// rest. A solid cell is rock. IDENTICAL text in heat3d_solar_sphere3d.glsl (rc_of_cell) and
// heat3d_buoyancy_sphere3d.glsl (rc_of); change one and change all three, or the same cell will hold a
// different amount of heat depending on which kernel is looking at it — which it did until 2026-08-03.
float lambda_of(uint i) {
	if (solid[i] != 0.0) {
		return LAMBDA_ROCK;
	}
	float f_rock = clamp(rock_fill[i], 0.0, 1.0);
	float f_water = clamp(water[i], 0.0, 1.0);
	float f_snow = clamp(snow[i], 0.0, 1.0);
	float f_air = max(0.0, 1.0 - f_rock - f_water - f_snow);
	return LAMBDA_AIR * f_air + LAMBDA_ROCK * f_rock + LAMBDA_WATER * f_water + LAMBDA_SNOW * f_snow;
}

// A CELL'S VOLUMETRIC HEAT CAPACITY — ONE definition for every kernel that books heat, because five
// copies in four different formulas is how heat gets created and destroyed at every exchange.
// Textual include: it binds all fifteen carriers by NAME, so it must sit
// below the buffer declarations. See rc_shared.glsli for the table of what each old copy left out.
// THE EIGHT CARRIERS rc_shared.glsli GAINED 2026-08-09. This kernel reads none of them itself; they are
// bound because a cell's heat capacity is a property of EVERYTHING in it, and these eight were counted
// nowhere, so every gram that crossed into one deleted its own thermal mass. Indices 30-37 are the same
// in all four heat kernels on purpose. Do not drop one because "this kernel does not need it".
layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "rc_shared.glsli"

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
			// bottom face of the shell. Bond to the interior's ghost cell with the same expression the loop
			// uses below — it is rock, so its half of the interface conductivity is LAMBDA_ROCK.
			if (d == 0 && params.core_boundary_c > 0.0) {
				float lam_core = 2.0 * lam_here * LAMBDA_ROCK / max(lam_here + LAMBDA_ROCK, 1e-12);
				delta += (lam_core * params.dt_over_dx2 / rc_here) * (params.core_boundary_c - here);
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
