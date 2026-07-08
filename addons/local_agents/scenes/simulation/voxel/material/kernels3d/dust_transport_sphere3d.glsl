#[compute]
#version 450

// CUBED-SPHERE DUST — TRANSPORT pass. The sphere port of dust_transport3d.glsl: IDENTICAL race-free GATHER
// (retained fraction + scaled inflow from the 6 neighbours + symmetric diffusion + leeward DEPOSIT) and
// IDENTICAL constants; only neighbour addressing changes. Neighbours come from the INDEX TABLE
// `nbr[idx*6 + slot]` — slot 0 = inward/DOWN, 1 = -x, 2 = +x, 3 = -z, 4 = +z, 5 = outward/UP. Gravity fall is
// the DOWN direction (slot 0): the cell's own downward flux DEPOSITS into `sediment[g]` when the cell below is
// SOLID or the boundary/floor (slot 0 = -1), else it was already donated to the open cell below as its
// "cell above" inflow. The retained-fraction raw_out_total() + the deposit fall_frac() are recomputed here and
// MUST match dust_outscale_sphere3d.glsl exactly. Constants copied EXACTLY from dust_transport3d.glsl.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DustIn { float dust_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer DustOut { float dust_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Sediment { float sed[]; };            // in place (+= deposit)
layout(set = 0, binding = 3, std430) restrict readonly buffer OutScale { float outscale[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float k;        // STEP_DT / cell_size (Courant factor)
	float pad0;
	float pad1;
} params;

// Transport tunables — MUST match dust_transport3d.glsl / MaterialDust3D.gd exactly.
const float OUT_MAX = 0.55;
const float DIFFUSE_RATE = 0.02;
const float SETTLE_BASE = 0.25;
const float SETTLE_MIN_FRAC = 0.02;
const float SETTLE_WIND_REF = 6.0;

// Downward flux fraction — identical to dust_outscale_sphere3d.glsl / MaterialDust3D._fall_frac.
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
	if (solid[g] != 0.0) {
		dust_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;
	float k = params.k;
	float di = dust_in[g];
	float scale_i = outscale[g];

	int nb_d = nbr[base + 0u];   // DOWN (below)
	int nb_w = nbr[base + 1u];   // -x
	int nb_e = nbr[base + 2u];   // +x
	int nb_n = nbr[base + 3u];   // -z
	int nb_s = nbr[base + 4u];   // +z
	int nb_u = nbr[base + 5u];   // UP (above)

	bool open_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool open_w = (nb_w >= 0) && (solid[nb_w] == 0.0);
	bool open_e = (nb_e >= 0) && (solid[nb_e] == 0.0);
	bool open_n = (nb_n >= 0) && (solid[nb_n] == 0.0);
	bool open_s = (nb_s >= 0) && (solid[nb_s] == 0.0);
	bool open_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	// raw_out_total for THIS cell (must match dust_outscale_sphere3d.glsl): retained fraction is di*(1-out_total).
	float raw = 0.0;
	if (open_e) { raw += max(0.0, vel_x[g]) * k; }
	if (open_w) { raw += max(0.0, -vel_x[g]) * k; }
	if (open_s) { raw += max(0.0, vel_z[g]) * k; }
	if (open_n) { raw += max(0.0, -vel_z[g]) * k; }
	if (open_u) { raw += max(0.0, vel_y[g]) * k; }
	raw += fall_frac(g, k);
	float out_total = raw * scale_i;
	float value = di * (1.0 - out_total);

	// Inflow: each neighbour's scaled flux flowing TOWARD this cell.
	if (open_w) { value += dust_in[nb_w] * max(0.0, vel_x[nb_w]) * k * outscale[nb_w]; }   // -x nbr blows +x (us)
	if (open_e) { value += dust_in[nb_e] * max(0.0, -vel_x[nb_e]) * k * outscale[nb_e]; }  // +x nbr blows -x
	if (open_n) { value += dust_in[nb_n] * max(0.0, vel_z[nb_n]) * k * outscale[nb_n]; }   // -z nbr blows +z
	if (open_s) { value += dust_in[nb_s] * max(0.0, -vel_z[nb_s]) * k * outscale[nb_s]; }  // +z nbr blows -z
	if (open_d) { value += dust_in[nb_d] * max(0.0, vel_y[nb_d]) * k * outscale[nb_d]; }   // below blows UP toward us
	if (open_u) { value += dust_in[nb_u] * fall_frac(uint(nb_u), k) * outscale[nb_u]; }    // above settles DOWN (whole fall flux)

	// Symmetric diffusion (conservative): equalise a little with open neighbours.
	float diff = 0.0;
	if (open_w) { diff += dust_in[nb_w] - di; }
	if (open_e) { diff += dust_in[nb_e] - di; }
	if (open_n) { diff += dust_in[nb_n] - di; }
	if (open_s) { diff += dust_in[nb_s] - di; }
	if (open_d) { diff += dust_in[nb_d] - di; }
	if (open_u) { diff += dust_in[nb_u] - di; }
	value += DIFFUSE_RATE * diff;

	// DEPOSIT: this cell's OWN downward flux that hits SOLID ground (or the floor/boundary) becomes loose
	// sediment here. If the cell below is OPEN the same flux was already donated to that cell's dust as its
	// "cell above" inflow, so it is not double-counted.
	bool below_blocked = (nb_d < 0) || (solid[nb_d] != 0.0);
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
