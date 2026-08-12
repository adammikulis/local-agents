#[compute]
#version 450

#include "neighbours.glsli"

layout(local_size_x = 64) in;

// fld is one of the carriers below, so it is bound twice and may not be `restrict`.
layout(set = 0, binding = 0, std430) buffer Field { float fld[]; };
layout(set = 0, binding = 1, std430) restrict buffer Send { float send[]; };              // idx*6 + dir (shared scratch)
layout(set = 0, binding = 2, std430) restrict readonly buffer Radial { float radial[]; }; // outward unit vec, c*3+{0,1,2}
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };       // world position, c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Neigh { int nbr[]; };       // idx*6 + slot
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };
// PLATE TABLE, 8 floats per plate: seed.xyz (unit direction of the plate's Voronoi centre), rate (signed
// angular speed, rad per simulated second), pole.xyz (unit Euler axis), pad.
layout(set = 0, binding = 5, std430) restrict readonly buffer Plates { float plate[]; };
layout(set = 0, binding = 8, std430) restrict buffer SendH { float send_h[]; };           // idx*6 + dir, J per m3 of DONOR volume
layout(set = 0, binding = 9, std430) restrict buffer Temp { float temp[]; };              // in place
// The fluid the arriving rock has to push out of the way (passes 2 and 3), and a carrier for rc_shared.
layout(set = 0, binding = 6, std430) buffer Water { float water[]; };
layout(set = 0, binding = 7, std430) buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 19, std430) readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 20, std430) readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 30, std430) buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) readonly buffer Porosity { float porosity[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = mineral outflow, 1 = mineral gather, 2 = evict buried fluid, 3 = fluid gather
	uint n_plates;     // 0 disables passes 0 and 1
	uint depth;        // radial layers per column
	float dt;
	float lat_size;    // LATERAL spacing, for the Courant number only
	float max_mass;    // a full cell of one phase (LAMaterialField3D.MAX_MASS)
	float pore_scale;  // 1 = fld is a rock-MATRIX saturation whose mineral share is (1 - porosity); 0 = fld is mineral
} params;

#include "shell.glsli"
#include "cellvol.glsli"
#include "rc_shared.glsli"

// Cell heat capacity gained per unit fill, J/m3K: the material's own capacity less the air it displaces,
// since rc_of() fills the unoccupied fraction with air.
const float MINERAL_RC_GAIN = RC_ROCK - RC_AIR;
const float WATER_RC_GAIN = RC_WATER - RC_AIR;

const float MAX_OUT_FRAC = 0.9;      // cap on the share of a cell that leaves in one step
const float MIN_MASS     = 1.0e-6;

vec3 cell_pos(uint i) {
	uint b = i * 3u;
	return vec3(pos[b + 0u], pos[b + 1u], pos[b + 2u]);
}

vec3 cell_radial(uint i) {
	uint b = i * 3u;
	return vec3(radial[b + 0u], radial[b + 1u], radial[b + 2u]);
}

// Mineral share of one unit of `fld` in cell c.
float solidity(uint c) {
	return 1.0 - params.pore_scale * clamp(porosity[c], 0.0, 1.0);
}

// Sphere Voronoi: the plate whose seed direction is closest in angle. Identical rule to LAPlateModel._plate_of.
int plate_of(vec3 dir) {
	int best = 0;
	float best_dot = -2.0;
	for (uint k = 0u; k < params.n_plates; k++) {
		vec3 seed = vec3(plate[k * 8u + 0u], plate[k * 8u + 1u], plate[k * 8u + 2u]);
		float d = dot(dir, seed);
		if (d > best_dot) {
			best_dot = d;
			best = int(k);
		}
	}
	return best;
}

float evicted(uint i) {
	return (rock_fill[i] >= 0.5) ? water[i] : 0.0;
}

bool supported(int c) {
	if (c < 0) {
		return false;
	}
	if (rock_fill[uint(c)] >= 0.5) {
		return true;
	}
	int dn = nbr[uint(c) * N_SLOTS + N_IN];
	return dn >= 0 && rock_fill[uint(dn)] >= 0.5;
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 2u) {
		// ---- PASS 2: THE ROCK PUSHES THE WATER OUT OF THE WAY -------------------
		// The cell went solid, the water CA skips solid cells, and the mass sat there unreachable.
		for (uint z = 0u; z < N_SLOTS; ++z) { send[base + z] = 0.0; send_h[base + z] = 0.0; }
		if (nbr[base + N_OUT] < 0) {
			return;                // nowhere outward to put it — evicting here would destroy the water
		}
		float out_w = evicted(gidx);
		if (out_w <= 0.0) {
			return;
		}
		send[base + N_OUT] = out_w;
		send_h[base + N_OUT] = out_w * WATER_RC_GAIN * temp[gidx];
		return;
	}

	if (params.pass_id == 3u) {
		// ---- PASS 3: THE EVICTED FLUID LANDS ------------------------------------
		float rc_here = rc_of(gidx);
		float own_out = 0.0;
		for (uint z = 0u; z < N_SLOTS; ++z) { own_out += send[base + z]; }
		float inflow = 0.0;
		float gain_h = 0.0;
		for (uint d = 0u; d < N_SLOTS; ++d) {
			int pi = partner[base + d];
			int nb = nbr[base + d];
			if (pi < 0 || nb < 0) { continue; }
			float vr = vol_ratio(uint(nb), gidx);
			inflow += send[uint(pi)] * vr;
			gain_h += send_h[uint(pi)] * vr;
		}
		water[gidx] = water[gidx] - own_out + inflow;
		float kept_cw = rc_here - own_out * WATER_RC_GAIN;
		float gain_cw = inflow * WATER_RC_GAIN;
		float denom_w = kept_cw + gain_cw;
		if (gain_cw > 0.0 && denom_w > 0.0) {
			temp[gidx] = (kept_cw * temp[gidx] + gain_h) / denom_w;
		}
		return;
	}

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		for (uint z = 0u; z < N_SLOTS; ++z) { send[base + z] = 0.0; send_h[base + z] = 0.0; }
		if (params.n_plates == 0u) {
			return;
		}
		float load = fld[gidx];
		if (load < MIN_MASS) {
			return;
		}
		if (!supported(int(gidx))) {
			return;    // not part of the ground — a plate carries the slab, not whatever floats over it
		}

		// This cell's plate velocity: v = omega x r, with r from the cell's own radial layer.
		vec3 rad = cell_radial(gidx);
		float R = shell_mid(gidx % params.depth);
		int k = plate_of(rad);
		vec3 omega = vec3(plate[uint(k) * 8u + 4u], plate[uint(k) * 8u + 5u], plate[uint(k) * 8u + 6u])
			* plate[uint(k) * 8u + 3u];
		vec3 v = cross(omega, rad * R);

		//   face = q_i + 0.5*(1 - C)*psi(r)*(q_down - q_i),   r = (q_i - q_up)/(q_down - q_i)
		vec3 p0 = cell_pos(gidx);
		float raw[4];
		float lateral = 0.0;
		for (int d = 0; d < 4; d++) {
			raw[d] = 0.0;
			int inb = nbr[base + N_LAT0 + uint(d)];
			if (inb < 0 || !supported(inb)) {
				continue;    // nothing to land on that way — the slab is buttressed, the flux is blocked
			}
			vec3 step_v = cell_pos(uint(inb)) - p0;
			float len = length(step_v);
			if (len < 1.0e-6) {
				continue;
			}
			float u = dot(v, step_v / len);
			if (u <= 0.0) {
				continue;
			}
			float courant = u * params.dt / max(params.lat_size, 1.0e-6);
			float face = load;
			float down = fld[uint(inb)] - load;                 // gradient ahead of the front
			if (abs(down) > 1.0e-9) {
				int iup = nbr[base + opposite_slot(N_LAT0 + uint(d))];
				float behind = (iup >= 0) ? (load - fld[uint(iup)]) : 0.0;
				float r = behind / down;
				float psi = clamp(r, 0.0, 1.0);                 // minmod
				face = load + 0.5 * (1.0 - courant) * psi * down;
			}
			raw[d] = courant * max(face, 0.0) / max(load, 1.0e-9);
			lateral += raw[d];
		}

		float up_out = 0.0;
		float excess = max(0.0, load - params.max_mass);
		if (excess > MIN_MASS) {
			int up = nbr[base + N_OUT];
			if (up >= 0) {
				// The neighbour's headroom is in ITS fill units; convert to mine before capping.
				up_out = min(excess,
					max(0.0, params.max_mass - fld[uint(up)]) * vol_ratio(uint(up), gidx));
			}
		}

		// Total outflow may never exceed MAX_OUT_FRAC of what the cell holds. Scale both legs together so
		// the split between them is preserved and the gather stays exactly conserving.
		float total = lateral * load + up_out;
		float cap = MAX_OUT_FRAC * load;
		float scale = (total > cap && total > 0.0) ? (cap / total) : 1.0;
		// `send` carries MINERAL, not matrix saturation, so a donor and a receiver of different porosity
		// exchange the same amount of rock. Each send_h is written beside its own send.
		float sd = solidity(gidx);
		for (uint l = 0u; l < N_LATERAL_COUNT; ++l) {
			float f = load * raw[l] * scale * sd;
			send[base + N_LAT0 + l] = f;
			send_h[base + N_LAT0 + l] = f * MINERAL_RC_GAIN * temp[gidx];
		}
		float uf = up_out * scale * sd;
		send[base + N_OUT] = uf;
		send_h[base + N_OUT] = uf * MINERAL_RC_GAIN * temp[gidx];
		return;
	}

	// ---- PASS 1: GATHER / APPLY IN PLACE ----------------------------------------
	float rc_here = rc_of(gidx);
	float own_out = 0.0;
	for (uint z = 0u; z < N_SLOTS; ++z) { own_out += send[base + z]; }

	float inflow = 0.0;
	float gain_h = 0.0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int pi = partner[base + d];
		int nb = nbr[base + d];
		if (pi < 0 || nb < 0) { continue; }
		float vr = vol_ratio(uint(nb), gidx);
		inflow += send[uint(pi)] * vr;
		gain_h += send_h[uint(pi)] * vr;
	}

	fld[gidx] = fld[gidx] + (inflow - own_out) / max(solidity(gidx), 1.0e-6);

	float kept_c = rc_here - own_out * MINERAL_RC_GAIN;
	float gain_c = inflow * MINERAL_RC_GAIN;
	float denom = kept_c + gain_c;
	if (gain_c > 0.0 && denom > 0.0) {
		temp[gidx] = (kept_c * temp[gidx] + gain_h) / denom;
	}
}
