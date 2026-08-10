#[compute]
#version 450

// `nbr[idx*6 + d]` (slot 0 = inward/down, 1-4 lateral, 5 = outward/up; -1 = boundary). This is the mechanical
// ===== WHAT THIS KERNEL IS, AND WHAT IT USED TO BE =========================================================
//      about 100x (2.5 against 0.026 W/m/K). Temperature spreads with DIFFUSIVITY alpha = lambda/(rho*c),
//      where air beats rock 21x (2.19e-5 against 1.03e-6 m^2/s). The old pair matched neither ordering; it
// 5200 C at 340 m under a 15 C surface demands q = 2.5 * 5185 / 340 = 38 W/m^2 — 440x Earth's 0.087 W/m^2.
// LAMaterialFieldGeotherm3D from a finite reservoir that cools as it supplies. It enters at slot 0's missing
// neighbour (slot 0 has no neighbour only at r = 0) through the SAME finite-volume expression every real
// measured 0.087 W/m^2 is ~27x what pure conduction through 2890 km of mantle would deliver.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// What the cell is MADE OF, so it conducts and stores heat as that rather than as air. This is the ocean's
// thermal inertia — the same mix heat3d_solar_sphere3d.glsl uses for its areal capacity — reaching conduction,
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
	float core_boundary_c;
	float dt_over_dx2;
	uint pad2;
} params;

// Conductivities (W/m/K) and volumetric heat capacities (J/m^3/K). GLSL cannot read GDScript, so these are
// copies; scripts/check_physical_constants.sh holds them equal to the authority.
const float LAMBDA_ROCK  = 2.5;      // LAPhysical.THERMAL_CONDUCT_ROCK_W_MK
const float LAMBDA_AIR   = 0.026;    // LAPhysical.THERMAL_CONDUCT_AIR_W_MK
const float LAMBDA_WATER = 0.60;     // LAPhysical.THERMAL_CONDUCT_WATER_W_MK
const float LAMBDA_SNOW  = 0.15;     // LAPhysical.THERMAL_CONDUCT_SNOW_W_MK

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
