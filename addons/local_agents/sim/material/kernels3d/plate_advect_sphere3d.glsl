#[compute]
#version 450

#include "neighbours.glsli"

// r = c % depth and R = shell_mid(r), with no per-cell lookup. Advection is DONOR-CELL

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) buffer Field { float fld[]; };
layout(set = 0, binding = 1, std430) restrict buffer Send { float send[]; };              // idx*6 + dir (shared scratch)
layout(set = 0, binding = 2, std430) restrict readonly buffer Radial { float radial[]; }; // per-cell outward unit vec, flat c*3+{0,1,2}
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };       // per-cell world position, flat c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Neigh { int nbr[]; };       // idx*6 + slot
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };
// PLATE TABLE, 8 floats per plate: seed.xyz (unit direction of the plate's Voronoi centre), rate (signed
// angular speed, rad per simulated second), pole.xyz (unit Euler axis), pad. Uploaded by the driver each step
layout(set = 0, binding = 5, std430) restrict readonly buffer Plates { float plate[]; };
// The fluid the arriving rock has to push out of the way (see PASS 2). Bound for every dispatch but only
// touched by pass 2, which runs once per step after both mineral channels have been carried.
layout(set = 0, binding = 6, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 7, std430) readonly buffer RockFill { float rock_fill[]; };   // see binding 0

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = outflow into `send`, 1 = gather + apply in place, 2 = displace the buried fluid
	uint n_plates;     // 0 disables the whole pass (pass 0 sends nothing, pass 1 is then an exact no-op)
	uint depth;        // radial layers per column — gives a cell its radius from its own index
	float dt;
	float lat_size;    // LATERAL spacing, for the Courant number only
	float max_mass;    // a full cell of one phase (LAMaterialField3D.MAX_MASS); the surplus above it is uplifted
} params;

#include "shell.glsli"

const float MAX_OUT_FRAC = 0.9;      // never empty a cell in one step (the gather stays exact either way)
const float MIN_MASS     = 1.0e-6;   // don't bother moving a numerically empty cell

vec3 cell_pos(uint i) {
	uint b = i * 3u;
	return vec3(pos[b + 0u], pos[b + 1u], pos[b + 2u]);
}

vec3 cell_radial(uint i) {
	uint b = i * 3u;
	return vec3(radial[b + 0u], radial[b + 1u], radial[b + 2u]);
}

// Sphere Voronoi: the plate whose seed direction is closest in angle. Identical rule to LAPlateModel._plate_of,
// so the crust that moves and the boundary that erupts are partitioned by ONE definition.
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
		// ENTOMBED: the cell went solid, the water CA skips solid cells, and the mass sat there unreachable.
		float out_w = evicted(gidx);
		int dn = nbr[base + N_IN];
		float in_w = (dn >= 0) ? evicted(uint(dn)) : 0.0;
		water[gidx] = max(0.0, water[gidx] - out_w + in_w);
		return;
	}

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		// Self-zero all six slots before any early return, exactly like the other CAs, so the shared `send`
		for (uint z = 0u; z < N_SLOTS; ++z) { send[base + z] = 0.0; }
		if (params.n_plates == 0u) {
			return;
		}
		float load = fld[gidx];
		if (load < MIN_MASS) {
			return;
		}
		if (!supported(int(gidx))) {
			return;    // not part of the ground — a plate carries the slab, not whatever is floating over it
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
				// The opposite lateral slot is this axis's other direction: 1<->2, 3<->4.
				int opp = int(1u + (uint(d) ^ 1u));
				int iup = nbr[base + uint(opp)];
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
				up_out = min(excess, max(0.0, params.max_mass - fld[uint(up)]));
			}
		}

		// Total outflow may never exceed what the cell holds (nor MAX_OUT_FRAC of it). Scale both legs together
		// so the split between them is preserved and the gather stays exactly conserving.
		float total = lateral * load + up_out;
		float cap = MAX_OUT_FRAC * load;
		float scale = (total > cap && total > 0.0) ? (cap / total) : 1.0;
		for (uint l = 0u; l < N_LATERAL_COUNT; ++l) {
			send[base + N_LAT0 + l] = load * raw[l] * scale;
		}
		send[base + N_OUT] = up_out * scale;
		return;
	}

	// ---- PASS 1: GATHER / APPLY IN PLACE ----------------------------------------
	// Reads only `send` (written in pass 0, untouched here) and writes only its own cell.
	float own_out = 0.0;
	for (uint z = 0u; z < N_SLOTS; ++z) { own_out += send[base + z]; }

	float inflow = 0.0;
	int nb;
	// Credit the OPPOSITE slot, `d ^ 1`. Was six unrolled lines pairing 0<->5, 1<->2, 3<->4 — not this
	// table's pairing, so advected crust was debited into slots nobody read and read twice out of others.
	for (uint d = 0u; d < N_SLOTS; ++d) {
		int pi = partner[base + d];
		if (pi >= 0) { inflow += send[uint(pi)]; }
	}

	fld[gidx] = max(0.0, fld[gidx] - own_out + inflow);
}
