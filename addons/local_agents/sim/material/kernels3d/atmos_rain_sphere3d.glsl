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
// NO LATENT-HEAT TERM HERE, DELIBERATELY, AND THIS IS WHY — recorded 2026-08-03, when the other three
// phase-change kernels got one. Falling rain is ALREADY LIQUID. Its condensation enthalpy was released
// where the condensation happened, in atmos_precip_sphere3d, at the cell that shed it; charging it again
// when it lands would create that heat a second time out of nothing. This kernel performs no phase change
// at all — it moves liquid water down a column — so it has no phase enthalpy to pay, and it correctly
// binds no `Temp`.
//
// WHAT IS GENUINELY MISSING IS A DIFFERENT THING, AND IT IS NOT A PHASE CHANGE: rain lands with no memory
// of its own temperature. This substrate stores temperature as an intensive per-cell scalar and derives
// heat capacity from channel contents, so mass arriving in a cell raises that cell's capacity while
// leaving its temperature alone — the cell's heat content (cap * T) goes UP with no source, and goes DOWN
// when water leaves. Cold rain therefore does not chill the ground it falls on, and the general defect is
// that EVERY inter-cell mass transfer in this substrate creates or destroys sensible heat: the water CA,
// this gather, groundwater flow, sediment transport, all of it. Fixing that means advecting enthalpy with
// mass (mix temperatures on transfer) across the substrate, not adding a term here, so it is reported
// rather than patched. Left live and named on purpose — do NOT read its absence as "checked and fine".
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down … 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Rain { float rain[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Boil { float boil[]; };  // dynamic water flashed to steam by atmos_condense_sphere3d — drained here
layout(set = 0, binding = 4, std430) restrict readonly buffer Static { float static_cells[]; };  // calm sea = infinite sink
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	int base = idx * 6;

	// Solid cells hold no water. STATIC sea cells are the infinite reservoir (both the evap SOURCE and the
	// drainage SINK) — rain over the ocean must VANISH into it, exactly as the water CA makes water flowing into
	// a static cell vanish. Without this the rain gather parked evaporated mass permanently in static-cell water
	// (nothing drains it) → an unbounded source that slowly flooded the world (the h2o climb). Skip both.
	if (solid[g] != 0.0 || static_cells[g] != 0.0) {
		return;
	}

	float add = 0.0;

	// SELF: this cell rains into itself when there is no open cell DOWN (inward). slot0 == -1 is the world
	// core/bottom (box iy==0); a solid inward neighbour is the box "solid directly below".
	float r_self = rain[g];
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
