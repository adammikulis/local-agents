#[compute]
#version 450

//   * TOP OF ATMOSPHERE — the outermost open cell (slot 5 is -1, real space). It absorbs the share of the beam
//   * EXPOSED BEDROCK — a SOLID cell whose slot 5 is space. Bare rock facing the sky radiates; nothing else in

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };          // per-cell world position, packed flat c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };        // frozen H2O -> ice albedo
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };      // liquid -> ocean albedo + heat capacity
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; }; // bedrock fraction -> heat capacity
layout(set = 0, binding = 7, std430) restrict readonly buffer Pressure { float pressure[]; }; // weight of the air ABOVE this cell -> greenhouse strength
layout(set = 0, binding = 8, std430) restrict readonly buffer TempPrev { float temp_prev[]; };
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, packed flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };         // idx*6 + slot
// LIVING PLANT MATTER -> canopy cover -> surface albedo (see the VEGETATION block below). Bound at 27 rather
// than at BIOMASS's slot number 11, because bindings up to 26 shadow the reaction engine's slot enum and a
// binding that half-matches it is worse than one that plainly does not.
layout(set = 0, binding = 27, std430) restrict readonly buffer Biomass { float biomass[]; };
// CARRIERS THIS KERNEL DOES NOT USE ITSELF, bound because rc_shared.glsli needs every one of them.
// Leaving one out is exactly the divergence that file exists to end.
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	// clock: `const float STEP_DT = 0.1`, the SIMULATED step, while heat_sphere3d.glsl in the same pass ran on
	float dt_s;
	float cell_size;
	uint pad2;
	float sun_x;        // world-space unit vector pointing TOWARD the sun (magnitude carries insolation)
	float sun_y;
	float sun_z;
	float sea_radius;   // world radius of the sea shell — altitude datum for the lapse term
} params;

const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN — the measured constant, in full
const float SOLAR_CONSTANT = 1361.0;   // LAPhysical.SOLAR_CONSTANT_W_M2 — irradiance at 1 AU
const float KELVIN = 273.15;           // LAPhysical.KELVIN_OFFSET
const float MAX_DT_PER_STEP = 5.0;     // last-resort stability limit (see SUB-STEPPING below)
const int   MAX_SUBSTEPS = 8;          // slices per step when |dT| is large
const float ALBEDO_GROUND = 0.15;      // LAPhysical.ALBEDO_BARE_GROUND
const float ALBEDO_WATER = 0.06;       // LAPhysical.ALBEDO_OCEAN
const float ALBEDO_ICE = 0.65;         // LAPhysical.ALBEDO_SNOW_ICE
const float ICE_ALBEDO_GAIN = 40.0;    // snow mass -> reflectivity; a thin dusting already whitens a cell
// ===== VEGETATION — THE BIOLOGICAL HALF OF THE ICE-ALBEDO FEEDBACK ================================
// THE COVER FRACTION IS NOT A RAMP WITH A CLAMP. It is Beer-Lambert extinction through the leaf area the
//   LAI             = leaf mass / LEAF_MASS_PER_AREA
const float RHO_CELLULOSE = 500.0;        // LAPhysical.DRY_WOOD_DENSITY_KG_M3 — LASubstances cellulose.density
const float ALBEDO_VEG = 0.12;            // LAPhysical.ALBEDO_VEGETATION — LASubstances cellulose.albedo
const float FOLIAGE_FRACTION = 0.03;      // LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
const float LEAF_MASS_PER_AREA = 0.080;   // LAPhysical.LEAF_MASS_PER_AREA_KG_M2
const float CANOPY_EXTINCTION = 0.5;      // LAPhysical.CANOPY_EXTINCTION_COEFF
// ===== HEAT CAPACITY — DERIVED FROM WHAT THE CELL IS MADE OF ======================================
// thermal inertia — 6.67e7 J/m^2/K. A real wind-stirred mixed layer is 20-100 m, so this grid is at the
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
// ===== GREENHOUSE — emissivity from the overlying air mass ========================================
//   eps_a = 1 - 1/(1 + 0.75*tau*p/P_REF) is how much of the surface's infrared the air column INTERCEPTS,
const float P_REF = 101325.0;        // LAPhysical.STANDARD_PRESSURE_PA — pass A writes real pascals now
const float TAU_SEA = 0.835;         // LAPhysical.ATMOS_OPTICAL_DEPTH — LONGWAVE depth of a sea-level column
const float TAU_TWO_STREAM = 0.75;   // LAPhysical.TWO_STREAM_COEFF — the coefficient in T_s^4 = T_e^4 (1 + 0.75 tau)
// ===== COLUMN SHORTWAVE BUDGET — THE BEAM IS SPENT ONCE ===========================================
// WHAT REPLACES IT. Beer-Lambert down the column, with the air's own mass as the optical path:
//     trans   = exp(-TAU_SW * (p_surface / P_REF) / mu)      fraction of the beam that reaches the ground
// 341 W/m^2 absorbed in the atmosphere, tau = -ln(1 - 0.2287).
const float TAU_SW = 0.2597;         // LAPhysical.ATMOS_SW_OPTICAL_DEPTH — SHORTWAVE depth of a sea-level column
// The slant path is 1/cos(zenith), which diverges at the terminator. The real relative air mass saturates
// near 38 there because the atmosphere is a curved shell rather than a slab, so THAT is what bounds it — a
// measured limit, not an epsilon chosen to stop a division.
const float AIR_MASS_HORIZON = 38.0; // LAPhysical.AIR_MASS_HORIZON
// Water fraction at which a cell counts as the sea/lake SURFACE rather than as air holding some spray. Matches
// atmos_evap_sphere3d.glsl's own `water[above] < MAX_MASS * 0.5` interface test, so the cell this kernel
// lights is the same cell that one evaporates from.
const float WATER_SURFACE_MIN = 0.5;
// Hard bound on a radial column walk. The shell is `depth` cells (20 on the shipped grid); 64 is a loop
// guard, not a physical quantity, and a walk that hits it has found a malformed neighbour table.
const int MAX_COLUMN_WALK = 64;

int find_column_top(uint start) {
	int c = int(start);
	for (int s = 0; s < MAX_COLUMN_WALK; ++s) {
		int u = nbr[uint(c) * 6u + 5u];
		if (u < 0) {
			return c;                                      // reached space: c is the top
		}
		if (solid[u] != 0.0) {
			return -1;                                     // rock overhead
		}
		c = u;
	}
	return -1;
}

int find_column_surface(uint start) {
	int c = int(start);
	for (int s = 0; s < MAX_COLUMN_WALK; ++s) {
		if (solid[c] != 0.0) {
			return -1;
		}
		if (water[c] >= WATER_SURFACE_MIN) {
			return c;                                      // topmost water cell: the sea/lake surface
		}
		int d = nbr[uint(c) * 6u + 0u];
		if (d < 0) {
			return -1;                                     // open to the bottom of the shell
		}
		if (solid[d] != 0.0) {
			return c;                                      // c rests on rock: the ground
		}
		c = d;
	}
	return -1;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	int up = nbr[idx * 6u + 5u];
	int down = nbr[idx * 6u + 0u];
	bool solid_here = solid[idx] != 0.0;
	bool faces_space = up < 0;

	bool toa = faces_space && !solid_here;
	// EXPOSED BEDROCK: solid rock whose slot 5 is space. Bare rock absorbs sunlight and radiates to the sky —
	// the old `if (solid) return` gave the crust a conductive sink only, so any column capped by rock traded no
	// radiation at all. It is the same energy balance; the cell is simply made of rock.
	bool bedrock_top = faces_space && solid_here;
	bool submerged = (up >= 0) && (solid[up] == 0.0) && (water[up] >= WATER_SURFACE_MIN);
	bool mat_surface = false;
	int top_c = -1;
	if (!solid_here && !submerged) {
		bool on_rock = (down >= 0) && (solid[down] != 0.0);
		bool water_top = clamp(water[idx], 0.0, 1.0) >= WATER_SURFACE_MIN;
		if (on_rock || water_top) {
			top_c = find_column_top(idx);                  // -1 when roofed by rock
			mat_surface = top_c >= 0;
		}
	}
	bool surface = toa || bedrock_top || mat_surface;

	// Per-cell insolation from this cell's outward radial vs the sun direction (the terminator).
	uint rb = idx * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 sun_dir = vec3(params.sun_x, params.sun_y, params.sun_z);
	float insolation = max(0.0, dot(cell_radial, sun_dir));

	// NOTE: altitude is deliberately not read here any more. It fed the LAPSE term, which was part of the
	// prescribed model and went with it; see the constants block for why re-prescribing it is the wrong fix
	// and what has to exist first. `params.sea_radius` is still the altitude datum for other passes.

	if (surface) {
		// ===== REAL ENERGY BALANCE =====================================================================
		// dT = (absorbed shortwave - emitted longwave) * dt / heat capacity.
		float wet = clamp(water[idx], 0.0, 1.0);
		float icy = clamp(snow[idx] * ICE_ALBEDO_GAIN, 0.0, 1.0);
		// CANOPY COVER, from the leaf area this cell's standing biomass carries. See the VEGETATION block.
		// exp() of a large negative underflows to 0, which IS a closed canopy — no clamp is needed and none is
		// written, because inventing one would put a chosen saturation point back in.
		float leaf_kg_m2 = max(biomass[idx], 0.0) * RHO_CELLULOSE * params.cell_size * FOLIAGE_FRACTION;
		float lai = leaf_kg_m2 / LEAF_MASS_PER_AREA;
		float veg = 1.0 - exp(-CANOPY_EXTINCTION * lai);
		float land = mix(ALBEDO_GROUND, ALBEDO_VEG, veg);
		float albedo = mix(mix(land, ALBEDO_WATER, wet), ALBEDO_ICE, icy);

		// HEAT CAPACITY per cell: the volumetric heat capacity of what the cell holds, times the cell's own
		// depth. Derived, not declared — see the block above for the four literals this replaced and by how
		// much each was wrong.
		float cap = max(rc_of(idx) * params.cell_size, 1.0);

		// ===== THE COLUMN'S TWO CELLS, AND THE ONE AIR MASS BETWEEN THEM ===============================
		float p_col = pressure[idx];
		if (p_col <= 0.0) {
			p_col = P_REF;
		}
		int surf_c = -1;
		float p_beam = 0.0;                 // exposed bedrock faces space with no air above it at all
		if (mat_surface) {
			surf_c = int(idx);
			p_beam = p_col;
		} else if (toa) {
			surf_c = find_column_surface(idx);
			p_beam = (surf_c >= 0) ? pressure[surf_c] : p_col;
			if (p_beam <= 0.0) {
				p_beam = P_REF;
			}
		}
		// SHORTWAVE — see the COLUMN SHORTWAVE BUDGET block for why the beam is split this way and why
		// TAU_SW is not TAU_SEA. Slant path bounded by the real horizon air mass rather than by an epsilon.
		float mu = max(insolation, 1.0 / AIR_MASS_HORIZON);
		float trans = exp(-TAU_SW * (p_beam / P_REF) / mu);
		float absorbed = 0.0;
		if (toa) {
			absorbed += SOLAR_CONSTANT * insolation * (1.0 - trans);            // the air column's share
		}
		if (mat_surface || bedrock_top) {
			absorbed += SOLAR_CONSTANT * insolation * trans * (1.0 - albedo);   // what the surface keeps
		}

		// ===== LONGWAVE — THE COLUMN SHEDS ITS HEAT ONCE ===============================================
		// eps_a = 1 - eps used in BOTH directions, which is what makes a greenhouse a greenhouse:
		float eps_a = 1.0 - 1.0 / (1.0 + TAU_TWO_STREAM * TAU_SEA * (p_beam / P_REF));
		float lw_in = 0.0;                                     // longwave RECEIVED, constant across slices
		if (toa && surf_c >= 0) {
			float ts = max(temp_prev[surf_c] + KELVIN, 1.0);
			lw_in += eps_a * STEFAN * ts * ts * ts * ts;        // the surface flux the air intercepts
		}
		if (mat_surface && top_c >= 0) {
			float ta = max(temp_prev[top_c] + KELVIN, 1.0);
			lw_in += eps_a * STEFAN * ta * ta * ta * ta;        // the air's downward half — the greenhouse
		}
		// How many blackbody faces this cell radiates from: the air layer emits eps_a upward AND downward, a
		// material surface or bare rock emits as a full blackbody upward.
		float lw_self = 0.0;
		if (toa) {
			lw_self += 2.0 * eps_a;
		}
		if (mat_surface || bedrock_top) {
			lw_self += 1.0;
		}

		float t_k = max(temp[idx] + KELVIN, 1.0);              // clamp keeps T^4 finite if a cell goes wild
		float emitted = lw_self * STEFAN * t_k * t_k * t_k * t_k - lw_in;
		float dT = (absorbed - emitted) * params.dt_s / cap;
		int slices = int(clamp(ceil(abs(dT) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
		float sub_dt = params.dt_s / float(slices);
		float t_c = temp[idx];
		for (int s = 0; s < slices; ++s) {
			float tk = max(t_c + KELVIN, 1.0);
			float em = lw_self * STEFAN * tk * tk * tk * tk - lw_in;
			// Still clamp each SLICE, so a pathological cell cannot run away — but with 8 slices this is a
			// genuine last resort rather than the every-step truncation it had become.
			t_c += clamp((absorbed - em) * sub_dt / cap, -MAX_DT_PER_STEP, MAX_DT_PER_STEP);
		}
		temp[idx] = t_c;
	}
}
