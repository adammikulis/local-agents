#[compute]
#version 450

// GPU 3D DUST — LOFT pass. A race-free per-cell port of LAMaterialDust3D._loft(): wind scours DRY loose
// sediment off an exposed surface into the airborne dust of the cell directly above. A cell lofts when it
// holds loose sediment (>= SED_MIN), has an OPEN air cell directly above (so wind can carry it away), is DRY
// (little standing water AND no rain), and its HORIZONTAL wind speed exceeds LOFT_WIND. The lofted mass is
// REMOVED from `sediment[g]` (in place) and ADDED into `dust[g + layer]` (the unique cell above) — a scatter
// whose TARGET is unique per source cell, so it is race-free in a single dispatch (only invocation g ever
// writes dust[g+layer], and no invocation reads dust in this pass). Runs on the POST-SLUMP sediment.
//
// Mass is conserved: every gram lofted leaves sediment and enters the airborne dust. The transport pass then
// advects/diffuses/settles that dust and deposits it back. Constants copied EXACTLY from MaterialDust3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Sediment { float sed[]; };            // in place (-= lofted)
layout(set = 0, binding = 1, std430) restrict buffer Dust { float dust[]; };               // scatter (+= into cell above)
layout(set = 0, binding = 2, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	uint raining;   // 1 = precipitation()>RAIN_MAX suppresses ALL lofting (wet-sand rule)
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Lofting tunables — MUST match MaterialDust3D.gd exactly.
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
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	uint iy = g / layer;
	if (iy >= dy - 1u) {
		return;                      // top layer can't loft (no air cell above it)
	}
	float m = sed[g];
	if (m < SED_MIN) {
		return;
	}
	if (water[g] > WET_MAX || params.raining == 1u) {
		return;                      // WET sand / rain never blows
	}
	uint iu = g + layer;
	if (solid[iu] != 0.0) {
		return;                      // buried — no open air above to carry the dust
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
	dust[iu] += amt;                 // unique target per source cell → race-free scatter
}
