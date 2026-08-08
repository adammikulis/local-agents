#[compute]
#version 450

// CUBED-SPHERE atmosphere RAIN GATHER — sphere port of atmos_rain3d.glsl (box). The race-free cross-cell
// WRITE half of precipitation: atmos_condense_sphere3d already subtracted each raining cell's rain from its
// cloud and stored the rain MASS in the per-cell `rain` scratch. Rain FALLS toward the ground — the box
// routed each cell's rain to the cell BELOW when open, else into itself. This gather inverts that: each
// cell sums the rain aimed AT it — its own rain when it has no open cell DOWN (inward, slot 0), plus the
// rain from the cell directly ABOVE (outward, slot 5) when that cell drains down into this open cell.
//   "down/below/ground" → INWARD radial neighbour = slot 0;  "up/above" → OUTWARD = slot 5.
//   box `iy==0 || solid below → self`  becomes  `slot0 == -1 || solid[slot0] → self`.
// One invocation per cell.
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Rain { float rain[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Boil { float boil[]; };  // dynamic water flashed to steam by atmos_condense_sphere3d — drained here
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };  // calm sea = infinite sink
// THE LATENT-HEAT HALF (added 2026-08-07): the temperature the condensation warms, and what the cell is made
// of so the release can be divided by its heat capacity. `temp` is READ/WRITE now; it was readonly.
layout(set = 0, binding = 5, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// ===== THE LATENT HEAT OF CONDENSATION =====================================================================
// Rain is water changing phase, and a phase change costs energy in BOTH directions. LAPhaseRecords R23/R24/R25
// charge the cell that evaporates (+L, it cools); this is the return leg, and it MUST exist or the substrate
// has a one-way heat sink: evaporation would cool without bound while nothing ever warmed. That asymmetry is
// the most likely explanation for the -131 °C planet an earlier attempt at this produced.
//
// WHERE THE HEAT LANDS: THE CELL THAT CONDENSED IT, not the cell the drop falls into. atmos_precip_sphere3d
// took `rain[c]` out of cell c's own moisture, so c is where the vapour became liquid and c is where the heat
// came out. The mass then falls one cell (the gather below); the energy does not fall with it, because a
// raindrop leaving a cloud does not carry the cloud's latent heat away — it already released it. Warming the
// receiving cell instead would move the heat release out of the atmosphere and into the ground, which is the
// opposite of what latent heat transport does on a real planet. Own-cell write, so it is race-free for free.
//
// WHAT IS BOOKED AND WHAT IS NOT. The convention is that the `moisture` CHANNEL is vapour for enthalpy
// purposes and the charge happens at the channel boundary (water/soil/snow <-> moisture). So condensation into
// SUSPENDED cloud droplets — which stay in `moisture`, since cloud here is derived as the part above sat(T)
// rather than stored — is not charged, and neither is their re-evaporation. Those two omissions are equal and
// opposite over any closed cycle, so no ratchet: only mass that actually crosses the channel boundary is paid
// for, and it is paid for exactly once in each direction.
//
// Vaporisation is quoted at 100 °C; condensation at 0 °C really costs 2.501e6 rather than 2.257e6, ~10% more.
// The authority carries the 100 °C figure and one number is better than a second one that drifts.
const float RHO_WATER = 997.0;        // LAPhysical.WATER_DENSITY_KG_M3
const float LATENT_VAPOR = 2.257e6;   // LAPhysical.LATENT_HEAT_VAPORISATION_J_KG
const float RC_ROCK  = 2.436e6;       // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_AIR   = 1186.0;        // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_WATER = 4.171e6;       // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
const float RC_SNOW  = 6.27e5;        // LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K

// A cell's volumetric heat capacity from what it is made of, by volume fraction — identical text to
// heat_sphere3d.glsl's rc_of, so the same cell holds the same heat here as it does in conduction. (Lava is not
// in this mix, matching those kernels; a raining cell holds no molten rock — at lava temperatures sat(T) is
// larger than a whole cell of water and nothing condenses. Suspended `moisture` is not in it either, which is
// a real omission shared with all three heat kernels and reported rather than fixed unilaterally here.)
float rc_of(uint i) {
	if (solid[i] != 0.0) {
		return RC_ROCK;
	}
	float f_rock = clamp(rock_fill[i], 0.0, 1.0);
	float f_water = clamp(water[i], 0.0, 1.0);
	float f_snow = clamp(snow[i], 0.0, 1.0);
	float f_air = max(0.0, 1.0 - f_rock - f_water - f_snow);
	return RC_AIR * f_air + RC_ROCK * f_rock + RC_WATER * f_water + RC_SNOW * f_snow;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	int base = idx * 6;

	if (solid[g] != 0.0) {
		return;                              // rock holds no water and atmos_precip writes it rain = 0 anyway
	}

	// LATENT HEAT FIRST, and OUTSIDE the static-cell early-out below. The condensation happened in THIS cell
	// (see the header), so the heat is owed wherever the drop ends up — including over a static sea, where the
	// mass is absorbed by the reservoir but the vapour still turned to liquid here and still released its heat.
	float condensed_here = rain[g];
	if (condensed_here > 0.0) {
		temp[g] += condensed_here * RHO_WATER * LATENT_VAPOR / max(rc_of(g), 1.0);
	}

	// STATIC sea cells are the infinite reservoir (both the evap SOURCE and the drainage SINK) — rain over the
	// ocean must VANISH into it, exactly as the water CA makes water flowing into a static cell vanish. Without
	// this the rain gather parked evaporated mass permanently in static-cell water (nothing drains it) → an
	// unbounded source that slowly flooded the world (the h2o climb).
	if (static_cells[g] != 0.0) {
		return;
	}

	float add = 0.0;

	// SELF: this cell rains into itself when there is no open cell DOWN (inward). slot0 == -1 is the world
	// core/bottom (box iy==0); a solid inward neighbour is the box "solid directly below".
	float r_self = condensed_here;
	if (r_self > 0.0) {
		int below = nbr[base + 0];
		bool self_target = (below < 0) || (solid[below] != 0.0);
		if (self_target) {
			add += r_self;
		}
	}

	// FROM ABOVE: the OUTWARD cell (slot 5) rains DOWN into this (open) cell — its target = idx because idx
	// is non-solid. (If idx were solid the above cell would rain into itself; handled by the guard above.)
	int above = nbr[base + 5];
	if (above >= 0) {
		float r_above = rain[above];
		if (r_above > 0.0) {
			add += r_above;
		}
	}

	// BOILING drain: atmos_condense_sphere3d flashed boil[g] of this DYNAMIC cell's water to steam (added the
	// vapor there); remove that same water here (mass-conserving). Static cells write boil=0 (no drain).
	float net = add - boil[g];
	if (net != 0.0) {
		water[g] = water[g] + net;
	}
}
