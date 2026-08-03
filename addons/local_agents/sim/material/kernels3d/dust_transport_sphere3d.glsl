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
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };  // per-column link dirs

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float k;             // STEP_DT / cell_size (Courant factor)
	uint pad0;
	uint depth;          // radial shells per column — turns a cell index into its column for the ltan lookup
} params;

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
// MUST match dust_outscale_sphere3d.glsl exactly. See wind_step_sphere3d for why the frame is its own table.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

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
		// ROCK GREW OVER AIRBORNE DUST: BURY IT, DO NOT DELETE IT. This used to be a bare `dust_out[g] = 0.0`,
		// which was an unaccounted MINERAL SINK — `solid` is re-derived from rock_fill every step, so any cell
		// that crossed the threshold with dust in the air simply had that mass annihilated, and no ledger
		// could see it. In the world, dust caught by growing rock settles into it; it does not cease to exist.
		// Handing it to `sed` (the loose phase, already `+=`-edited by the deposit leg below) makes it a
		// CONSERVING transfer between two counted legs of mineral_total. Costs one add on a branch that was
		// already taken. `dust_in` is the LIVE half and `sed` the BACK half, so the mass moves exactly once:
		// the parity flip promotes this cell's zeroed dust next step.
		//
		// THIS IS NOT A HYPOTHETICAL LEAK. `dust_total` had been printing 0.00 in every SIM_REPORT because its
		// CPU mirror was never read back (see LAMaterialFieldQueries3D.avg_atmos_dust), and the first run that
		// requested the channel measured 221.62 units of airborne dust on a --planet-only world. Every cell
		// that crossed rock_fill 0.5 was deleting its share of that, unseen.
		sed[g] += dust_in[g];
		dust_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;
	float k = params.k;
	float di = dust_in[g];
	float scale_i = outscale[g];

	int nb_d = nbr[base + 0u];   // DOWN (below)
	int nb_u = nbr[base + 5u];   // UP (above)

	bool open_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool open_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	// raw_out_total for THIS cell (must match dust_outscale_sphere3d.glsl): retained fraction is di*(1-out_total).
	// Lateral: one term per OPEN link, the wind Courant number along that link's own direction.
	float raw = 0.0;
	float lat_in = 0.0;
	float lat_diff = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[base + uint(l + 1)];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		raw += max(0.0, toward_link(g, l)) * k;
		// Inflow: that neighbour's scaled flux aimed back at me, read from ITS reverse link (l ^ 1).
		lat_in += dust_in[m] * max(0.0, toward_link(uint(m), l ^ 1)) * k * outscale[m];
		lat_diff += dust_in[m] - di;
	}
	if (open_u) { raw += max(0.0, vel_y[g]) * k; }
	raw += fall_frac(g, k);
	float out_total = raw * scale_i;
	float value = di * (1.0 - out_total) + lat_in;

	// Vertical inflow.
	if (open_d) { value += dust_in[nb_d] * max(0.0, vel_y[nb_d]) * k * outscale[nb_d]; }   // below blows UP toward us
	if (open_u) { value += dust_in[nb_u] * fall_frac(uint(nb_u), k) * outscale[nb_u]; }    // above settles DOWN (whole fall flux)

	// Symmetric diffusion (conservative): equalise a little with open neighbours.
	float diff = lat_diff;
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
