#[compute]
#version 450

// CUBED-SPHERE DUST — LOFT pass. The sphere port of dust_loft3d.glsl: IDENTICAL loft rule and constants;
// only the "cell directly above" addressing changes. The box lofted into `g + layer` (guarded by iy<dim_y-1);
// here the cell ABOVE is the outward radial neighbour, slot 5 of the INDEX TABLE `nbr[idx*6 + slot]` — if it
// is -1 (boundary, i.e. the outer shell surface) there is no air above and the cell can't loft. The lofted
// mass is REMOVED from `sediment[g]` and ADDED into the airborne dust of that unique cell above (slot 5) — a
// scatter whose TARGET is unique per source cell, so it stays race-free in a single dispatch. Constants
// copied EXACTLY from dust_loft3d.glsl / MaterialDust3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Sediment { float sed[]; };            // in place (-= lofted)
layout(set = 0, binding = 1, std430) restrict buffer Dust { float dust[]; };               // scatter (+= into cell above)
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint raining;   // 1 = precipitation()>RAIN_MAX suppresses ALL lofting (wet-sand rule)
	uint pad0;
	uint pad1;
} params;

// Lofting tunables — MUST match dust_loft3d.glsl / MaterialDust3D.gd exactly.
const float LOFT_WIND = 6.0;       // horizontal wind speed a surface must exceed to loft sand
const float LOFT_RATE = 0.003;     // sediment mass lofted per step per unit of wind OVER the threshold
const float LOFT_MAX = 0.05;       // cap on sediment lofted from one cell per step (stability)
const float SED_MIN = 0.0005;      // below this a cell holds no meaningful loose sediment to loft
const float WET_MAX = 0.05;        // water mass above which a cell is WET and can't loft

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		return;
	}
	uint base = g * 6u;
	int iu = nbr[base + 5u];         // cell directly ABOVE (radially outward)
	if (iu < 0) {
		return;                      // outer shell surface — no air cell above to carry the dust
	}
	float m = sed[g];
	if (m < SED_MIN) {
		return;
	}
	if (water[g] > WET_MAX || params.raining == 1u) {
		return;                      // WET sand / rain never blows
	}
	if (solid[iu] != 0.0) {
		return;                      // buried — no open air above
	}
	float vx = vel_x[g];
	float vz = vel_z[g];
	float hspeed = sqrt(vx * vx + vz * vz);
	if (hspeed <= LOFT_WIND) {
		return;
	}
	float amt = LOFT_RATE * (hspeed - LOFT_WIND);
	amt = min(amt, LOFT_MAX);
	amt = min(amt, m);
	if (amt <= 0.0) {
		return;
	}
	sed[g] = m - amt;
	dust[uint(iu)] += amt;           // unique target per source cell → race-free scatter
}
