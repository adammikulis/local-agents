#[compute]
#version 450

// GPU 3D DUST — TRANSPORT pass. A race-free GATHER port of LAMaterialDust3D._transport(): each non-solid cell
// keeps its un-emitted fraction, then sums the scaled dust donations flowing in from its six neighbours (each
// neighbour's wind/settling flux toward this cell), plus a small symmetric diffusion. The cell's OWN downward
// settling flux, when the cell below is SOLID (or it is the floor), is DEPOSITED into `sediment[g]` (in place)
// instead of donating to a dust cell — the leeward accretion that makes dunes migrate downwind. Reads only the
// OLD dust snapshot (dust_in) + the precomputed outscale + velocity + solid, writes dust_out[g] and its OWN
// sediment[g], so it is order-independent and mass-conserving. Runs on the POST-LOFT dust.
//
// The retained-fraction raw_out_total() + the deposit fall_frac() are recomputed here and MUST match
// dust_outscale3d.glsl / MaterialDust3D.gd exactly (they feed the same CFL scale). Index layout:
// idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DustIn { float dust_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer DustOut { float dust_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Sediment { float sed[]; };            // in place (+= deposit)
layout(set = 0, binding = 3, std430) restrict readonly buffer OutScale { float outscale[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float k;        // STEP_DT / cell_size (Courant factor)
	float pad0;
	float pad1;
	float pad2;
} params;

// Transport tunables — MUST match MaterialDust3D.gd exactly.
const float OUT_MAX = 0.55;
const float DIFFUSE_RATE = 0.02;
const float SETTLE_BASE = 0.25;
const float SETTLE_MIN_FRAC = 0.02;
const float SETTLE_WIND_REF = 6.0;

// Downward flux fraction — identical to dust_outscale3d.glsl / MaterialDust3D._fall_frac.
float fall_frac(uint i, float k) {
	float vxi = vel_x[i];
	float vyi = vel_y[i];
	float vzi = vel_z[i];
	float speed = sqrt(vxi * vxi + vyi * vyi + vzi * vzi);
	float calm = clamp(1.0 - speed / SETTLE_WIND_REF, 0.0, 1.0);
	float settle = SETTLE_MIN_FRAC + (SETTLE_BASE - SETTLE_MIN_FRAC) * calm;
	return max(0.0, -vyi) * k + settle;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	if (solid[g] != 0.0) {
		dust_out[g] = 0.0;
		return;
	}
	uint iy = g / layer;
	uint rem = g - iy * layer;
	uint iz = rem / dx;
	uint ix = rem - iz * dx;
	float k = params.k;

	float di = dust_in[g];
	float scale_i = outscale[g];

	// raw_out_total for THIS cell (must match dust_outscale3d.glsl): the retained fraction is di*(1-out_total).
	float raw = 0.0;
	if (ix < dx - 1u && solid[g + 1u] == 0.0)    { raw += max(0.0, vel_x[g]) * k; }
	if (ix > 0u && solid[g - 1u] == 0.0)         { raw += max(0.0, -vel_x[g]) * k; }
	if (iz < dz - 1u && solid[g + dx] == 0.0)    { raw += max(0.0, vel_z[g]) * k; }
	if (iz > 0u && solid[g - dx] == 0.0)         { raw += max(0.0, -vel_z[g]) * k; }
	if (iy < dy - 1u && solid[g + layer] == 0.0) { raw += max(0.0, vel_y[g]) * k; }
	raw += fall_frac(g, k);
	float out_total = raw * scale_i;
	float value = di * (1.0 - out_total);

	// Inflow: each neighbour's scaled flux flowing TOWARD this cell.
	if (ix > 0u && solid[g - 1u] == 0.0) {
		uint n = g - 1u;                         // -X neighbour blows toward +X (us)
		value += dust_in[n] * max(0.0, vel_x[n]) * k * outscale[n];
	}
	if (ix < dx - 1u && solid[g + 1u] == 0.0) {
		uint n = g + 1u;                         // +X neighbour blows toward -X
		value += dust_in[n] * max(0.0, -vel_x[n]) * k * outscale[n];
	}
	if (iz > 0u && solid[g - dx] == 0.0) {
		uint n = g - dx;                         // -Z neighbour blows toward +Z
		value += dust_in[n] * max(0.0, vel_z[n]) * k * outscale[n];
	}
	if (iz < dz - 1u && solid[g + dx] == 0.0) {
		uint n = g + dx;                         // +Z neighbour blows toward -Z
		value += dust_in[n] * max(0.0, -vel_z[n]) * k * outscale[n];
	}
	if (iy > 0u && solid[g - layer] == 0.0) {
		uint nd = g - layer;                     // cell BELOW blows UP toward us
		value += dust_in[nd] * max(0.0, vel_y[nd]) * k * outscale[nd];
	}
	if (iy < dy - 1u && solid[g + layer] == 0.0) {
		uint nu = g + layer;                     // cell ABOVE settles/blows DOWN toward us (whole fall flux)
		value += dust_in[nu] * fall_frac(nu, k) * outscale[nu];
	}

	// Symmetric diffusion (conservative): equalise a little with open neighbours.
	float diff = 0.0;
	if (ix > 0u && solid[g - 1u] == 0.0)         { diff += dust_in[g - 1u] - di; }
	if (ix < dx - 1u && solid[g + 1u] == 0.0)    { diff += dust_in[g + 1u] - di; }
	if (iz > 0u && solid[g - dx] == 0.0)         { diff += dust_in[g - dx] - di; }
	if (iz < dz - 1u && solid[g + dx] == 0.0)    { diff += dust_in[g + dx] - di; }
	if (iy > 0u && solid[g - layer] == 0.0)      { diff += dust_in[g - layer] - di; }
	if (iy < dy - 1u && solid[g + layer] == 0.0) { diff += dust_in[g + layer] - di; }
	value += DIFFUSE_RATE * diff;

	// DEPOSIT: this cell's OWN downward flux that hits SOLID ground (or the floor) becomes loose sediment here
	// (dust falling back to earth). If the cell below is OPEN the same flux was already donated to that cell's
	// dust as its "cell above" inflow, so it is not double-counted.
	bool below_blocked = (iy == 0u);
	if (iy > 0u && solid[g - layer] != 0.0) {
		below_blocked = true;
	}
	if (di > 0.0 && below_blocked) {
		float deposit = di * fall_frac(g, k) * scale_i;
		if (deposit > 0.0) {
			sed[g] += deposit;
		}
	}

	if (value < 0.0) {
		value = 0.0;
	}
	dust_out[g] = value;
}
