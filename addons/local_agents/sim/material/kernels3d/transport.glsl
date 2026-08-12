#[compute]
#version 450

// The one gather: every substance that moves between cells moves through it.
// Two passes over the same dispatch. Pass 0 writes what leaves each face into send/send_h; pass 1 gathers.
// Opposite of slot d is d ^ 1.

#include "neighbours.glsli"
#include "generated.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Amount   { float amount[]; };
layout(set = 0, binding = 1, std430) restrict buffer Enthalpy { float h[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity per cell, flat cell*3, m/s^2.
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };

layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer VelZ { float vel_z[]; };
// Per-face scratch, cell*6 + slot.
layout(set = 0, binding = 8, std430) restrict buffer Send   { float send[]; };
layout(set = 0, binding = 9, std430) restrict buffer SendH  { float send_h[]; };
// Flow resistance 0..1 per cell.
layout(set = 0, binding = 10, std430) restrict readonly buffer Resist { float resist[]; };
// What the flux runs down. Bound to `amount` when a record has no separate potential.
layout(set = 0, binding = 11, std430) restrict readonly buffer Drive { float drive[]; };
// Per-cell mobility field: conductivity for MODE_CONDUCT, 1.0 otherwise.
layout(set = 0, binding = 12, std430) restrict readonly buffer Cond { float cond[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // 0 = outflow, 1 = gather
	uint mode;            // MODE_* below
	float cell_m;         // cell edge, metres. One number: the grid is uniform.
	float dt_s;
	float mobility;       // fraction of the driving imbalance that moves in one step
	float repose_tan;     // 0 = a fluid, which levels freely
	float min_amount;     // below this a cell is empty and does not donate
	float density;        // kg/m^3 of the substance this record carries
	float max_fill;       // the amount at which a cell is full
	float lapse_k_per_m;  // MODE_CONVECT: the adiabat this pair must exceed before it overturns
} params;


vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

vec3 vel_at(uint c) {
	return vec3(vel_x[c], vel_y[c], vel_z[c]);
}

// Outward unit normal of face d. Slot order -X,+X,-Y,+Y,-Z,+Z.
vec3 face_normal(uint d) {
	float s = (d & 1u) == 1u ? 1.0 : -1.0;
	uint axis = d >> 1u;
	return vec3(axis == 0u ? s : 0.0, axis == 1u ? s : 0.0, axis == 2u ? s : 0.0);
}

// Driving potential across face d, metres of head. MODE_DIFFUSE drops the gravity term: a diffusing
// quantity runs down its own gradient and does not fall.
float potential(uint c, uint d, float amt) {
	if (params.mode == MODE_DIFFUSE || params.mode == MODE_CONDUCT || params.mode == MODE_RADIATE) {
		return drive[c] * params.cell_m;
	}
	vec3 gv = g_at(c);
	float gmag = length(gv);
	if (gmag <= 0.0) {
		return amt * params.cell_m;
	}
	return amt * params.cell_m + params.cell_m * dot(-gv / gmag, face_normal(d));
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 0u) {
		for (uint d = 0u; d < 6u; ++d) {
			send[base + d] = 0.0;
			send_h[base + d] = 0.0;
		}
		if (solid[gidx] != 0.0) {
			return;
		}
		float remaining = amount[gidx];
		if (remaining < params.min_amount) {
			return;
		}
		// Enthalpy per unit, J: mass carries its heat.
		float h_per_unit = (amount[gidx] > 0.0) ? h[gidx] / amount[gidx] : 0.0;
		float open = 1.0 - clamp(resist[gidx], 0.0, 1.0);
		if (open <= 0.0) {
			return;
		}

		for (uint d = 0u; d < 6u && remaining >= params.min_amount; ++d) {
			int inb = nbr[base + d];
			if (inb < 0 || solid[inb] != 0.0) {
				continue;
			}
			uint nb = uint(inb);
			float theirs = potential(nb, d ^ 1u, amount[nb]);
			float drop = potential(gidx, d, remaining) - theirs;
			if (drop <= 0.0) {
				continue;
			}
			// A THRESHOLD GRADIENT. Granular material holds a slope up to its angle of repose; a column of
			// gas holds a temperature gradient up to its adiabat. Same construct, one cell of run either way.
			if (params.repose_tan > 0.0) {
				drop -= params.repose_tan * params.cell_m;
				if (drop <= 0.0) {
					continue;
				}
			}
			if (params.mode == MODE_CONVECT) {
				vec3 gv = g_at(gidx);
				float up = dot(-normalize(gv + vec3(1.0e-30)), face_normal(d));
				if (up >= 0.0) {
					continue;   // convection lifts; the sinking half is the neighbour's own pass
				}
				drop -= params.lapse_k_per_m * params.cell_m * (-up);
				if (drop <= 0.0) {
					continue;
				}
			}
			float flow = drop * params.mobility * open / params.cell_m;
			if (params.mode == MODE_RADIATE) {
				// Stefan-Boltzmann across the face. `cond` carries emissivity, `drive` the temperature.
				float tk = drive[gidx] + 273.15;
				float tn = drive[nb] + 273.15;
				float e = 0.5 * (cond[gidx] + cond[nb]);
				flow = e * 5.670374419e-8 * (tk * tk * tk * tk - tn * tn * tn * tn) * params.dt_s
					/ params.cell_m;
				if (flow <= 0.0) {
					continue;
				}
			}
			if (params.mode == MODE_CONDUCT) {
				// Two half-cells in series across the bond, so the interface conductivity is the harmonic
				// mean. dh = lambda_i * (T_nb - T_here) * dt / dx^2, with no capacity: h IS the state.
				float a = cond[gidx];
				float b = cond[nb];
				float lam = 2.0 * a * b / max(a + b, 1.0e-12);
				flow = drop * lam * params.dt_s / (params.cell_m * params.cell_m);
			}

			if (params.mode == MODE_ADVECT || params.mode == MODE_BOTH) {
				// Outgoing advective flux; the neighbour's pass handles the other direction.
				float vn = dot(vel_at(gidx), face_normal(d));
				if (vn > 0.0) {
					flow += remaining * vn * params.dt_s / params.cell_m;
				} else if (params.mode == MODE_ADVECT) {
					continue;
				}
			}
			float room = max(params.max_fill - amount[nb], 0.0);
			flow = clamp(flow, 0.0, min(remaining, room));
			if (flow <= 0.0) {
				continue;
			}
			send[base + d] = flow;
			send_h[base + d] = flow * h_per_unit;
			remaining -= flow;
		}
		return;
	}

	// Pass 1: gather.
	float gained = 0.0;
	float gained_h = 0.0;
	float lost = 0.0;
	float lost_h = 0.0;
	for (uint d = 0u; d < 6u; ++d) {
		lost += send[base + d];
		lost_h += send_h[base + d];
		int inb = nbr[base + d];
		if (inb < 0) {
			continue;
		}
		uint nb = uint(inb);
		gained += send[nb * 6u + (d ^ 1u)];
		gained_h += send_h[nb * 6u + (d ^ 1u)];
	}
	amount[gidx] = max(amount[gidx] - lost + gained, 0.0);
	h[gidx] = h[gidx] - lost_h + gained_h;
}
