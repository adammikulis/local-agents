#[compute]
#version 450

// CUBED-SPHERE heat EVAPORATIVE-COOLING pass — now the LATENT-HEAT sink, which is what evaporative cooling
// actually is. Runs LAST in the heat chain before the lava passes, IN PLACE on the temp buffer, reading the
// POST-FLOW water. Purely per-cell independent: no neighbour reads at all.
//
// ===== WHAT THIS FILE USED TO BE, AND WHY NONE OF IT IS LEFT ==============================================
// *(Rewritten 2026-08-03. Three separate things were wrong and they had grown into each other.)*
//
// 1. AN EIGHT-LINE WARNING IN THE PRESENT TENSE THAT WAS FALSE. It said "SST_SURFACE / WATER_TEMP_DEEP make
//    the ocean a THERMOSTAT ... every wet cell is dragged toward this fixed profile, so sea-surface
//    temperature is 26 C by fiat", and "there is no radiative sink (nothing here computes T^4 emission to
//    space; heat3d_solar relaxes toward a target instead)". Both statements had stopped being true: the
//    thermostat was deleted and heat3d_solar_sphere3d.glsl computes a real sigma*eps*T^4 balance. The warning
//    was left standing, and LASphereThermalPass's own kernel list repeated it ("marine cooling of wet cells
//    toward the sea thermocline"). Both are corrected.
//
// 2. THREE CONSTANTS THAT NOTHING READ. WATER_COOL_RATE 0.12, HOT_SPRING_MARGIN 15.0 and
//    HOT_SPRING_COOL_FRAC 0.06 were declared, documented at length, and referenced by no expression anywhere
//    — the leftovers of the deleted thermostat and of the hot-spring gate that existed only to escape it.
//    Deleted. A constant that still reads as live is worse than no constant.
//
// 3. THE LAVA QUENCH WAS HEAT DELETED INTO NOWHERE, AIMED AT A PRESCRIBED TEMPERATURE. `sea_water_target()`
//    was still evaluated for EVERY wet cell, and its one consumer drove a 950 C cell to ~296 C in a single
//    step by relaxing 70% of the way toward a hardcoded 26 C-at-the-surface / 10 C-in-the-deep thermocline
//    curve. Nothing received that energy, no steam was produced, and the destination was an asserted number
//    rather than anything the field computed. The physical event it stood in for is real — seawater flashes
//    molten rock to pillow basalt — so it is now modelled by the mechanism that actually does it.
//
// ===== WHAT IT IS NOW: THE LATENT HEAT OF VAPORISATION ====================================================
// Boiling water off a cell costs 2.257e6 J per kilogram, and that energy comes out of the cell's sensible
// heat. Against water's specific heat that ratio is L/c = 539 K, so flashing one percent of a full water cell
// to steam costs the same heat as cooling that water by 5.4 K. It is an enormous sink and this substrate was
// not paying it at all.
//
// This is a UNIVERSAL rule with no lava branch in it, and the named phenomena fall out:
//   * a submerged lava cell boils the seawater around it hard and quenches under the basalt solidus in a few
//     steps — pillow basalt, seamounts, the island a seabed vent builds;
//   * a geothermal spring pins itself near 100 C instead of running away, which is what a boiling spring does
//     and what the deleted HOT_SPRING gate was faking;
//   * any wet cell a fire or an impact heats past boiling cools itself by steaming.
// None of those is coded for. `LAVA_QUENCH_MIN` / `LAVA_QUENCH_FRAC` are gone with the rest.
//
// THE ENERGY LIMIT IS THE PHYSICS, NOT A CLAMP. A cell can only boil what its heat ABOVE the boiling point
// can pay for; once it reaches 100 C, further boiling needs heat from somewhere else and stops. So the mass
// flashed here is the lesser of atmos_evap_sphere3d.glsl's rate and what the cell can afford, and the
// temperature lands exactly at the boiling point when the limit binds. It can never undershoot.
//
// WHAT IS STILL WRONG AND IS NOT IN THIS FILE: atmos_evap_sphere3d.glsl owns the MASS side of the same phase
// change (`water -> moisture`) and debits `water * bfrac` with no energy limit and no latent-heat charge of
// its own. So when its rate exceeds what this kernel can pay for, the excess water vaporises for free — heat
// appearing from nothing at the phase change. The same is true of its EVAPORATION leg, which charges no
// latent heat at all. Both belong in that kernel and it is owned by another lane; reported, not fixed here.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Lava { float lava[]; };      // molten mineral per cell
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
// CARRIERS THIS KERNEL DOES NOT USE ITSELF, bound because rc_shared.glsli needs every one of them.
// Leaving one out is exactly the divergence that file exists to end.
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer Snow { float snow[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	// Grid cell edge in METRES (LASphereGrid.cell_size). Turns the volumetric heat capacity below into the
	// areal one, and the cell's water FRACTION into a depth of water in metres — which is what the latent
	// heat is charged per kilogram of. *(Took the `sea_radius` slot: that was the altitude datum for
	// sea_water_target(), which is deleted.)*
	float cell_size;
	float pad0;
	float pad1;
} params;

// Measured properties of matter. GLSL cannot read GDScript, so these are copies;
// scripts/check_physical_constants.sh holds them equal to the authority.
const float BOIL_TEMP = 100.0;        // LAPhysical.WATER_BOIL_C — the phase boundary, not a tunable
const float RHO_WATER = 997.0;        // LAPhysical.WATER_DENSITY_KG_M3
const float LATENT_VAPOR = 2.257e6;   // LAPhysical.LATENT_HEAT_VAPORISATION_J_KG

// MODEL parameters of the boiling rate, and they MUST match atmos_evap_sphere3d.glsl, which does the matching
// mass transfer later in the same step (PASS_SCRIPTS: Thermal runs before Atmosphere). They are how fast the
// phase change proceeds, not where it happens — BOIL_TEMP above is the physical part.
const float BOIL_RATE = 0.02;
const float BOIL_MAX_FRAC = 0.5;
const float WATER_MIN = 0.05;         // matches atmos_evap_sphere3d.glsl's own wet-cell floor

// A cell's heat capacity from what it is made of, by volume fraction. Molten rock (lava) carries rock's
// rho*c — basalt's specific heat barely moves across its melting range. Snow is not in this mix and does not
// need to be: a cell above the boiling point of water is not holding snow.
// A CELL'S VOLUMETRIC HEAT CAPACITY — ONE definition for every kernel that books heat, because five
// copies in four different formulas is how heat gets created and destroyed at every exchange.
// Textual include: it binds rock_fill/lava/water/snow/fuel/biomass/detritus by NAME, so it must sit
// below the buffer declarations. See rc_shared.glsli for the table of what each old copy left out.
#include "rc_shared.glsli"

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;
	}
	float t = temp[idx];
	float w = water[idx];
	if (t <= BOIL_TEMP || w <= WATER_MIN) {
		return;
	}
	// Volume fraction of the cell atmos_evap will flash to steam this step, at its rate.
	float bfrac = clamp((t - BOIL_TEMP) * BOIL_RATE, 0.0, BOIL_MAX_FRAC);
	float boiled = w * bfrac;
	// Areal heat capacity (J/m^2/K) and the heat cost per unit boiled fraction (J/m^2): a fraction f of the
	// cell is f*cell_size metres of water, which is f*cell_size*RHO_WATER kilograms per square metre.
	float cap = max(rc_of(idx) * params.cell_size, 1.0);
	float cost_per_frac = params.cell_size * RHO_WATER * LATENT_VAPOR;
	// What the cell's heat above the boiling point can actually pay for. Beyond that the water stops boiling,
	// so this is the phase boundary doing the limiting, not a guard.
	float affordable = (t - BOIL_TEMP) * cap / cost_per_frac;
	boiled = min(boiled, affordable);
	temp[idx] = t - boiled * cost_per_frac / cap;
}
