#[compute]
#version 450

// Non-inductive charge SEPARATION. Rebounding graupel-ice collisions in the mixed-phase band leave the
// two hydrometeors oppositely charged; they then separate because they fall at different speeds.
// Total charge is unchanged: what one phase gains the other loses.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Charge { float charge[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Cloud { float cloud[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer VelZ { float vel_z[]; };

#include "march.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt_s;
	float rate_c_m3_s;     // LAPhysical.NIC_CHARGE_RATE_C_M3_S
	float zone_warm_c;     // LAPhysical.CHARGE_ZONE_WARM_C
	float zone_cold_c;     // LAPhysical.CHARGE_ZONE_COLD_C
	float updraft_ref;     // LAPhysical.CONVECTIVE_UPDRAFT_M_S
	float lwc_ref;         // LAPhysical.CHARGING_LWC_KG_M3
	uint pad0;
} params;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	// The riming band: outside it the sign reverses or the mechanism stops.
	float t = temp[g];
	float band = clamp((params.zone_warm_c - t) / (params.zone_warm_c - params.zone_cold_c), 0.0, 1.0);
	if (band <= 0.0) {
		return;
	}
	vec3 gv = vec3(g_field[g * 3u], g_field[g * 3u + 1u], g_field[g * 3u + 2u]);
	if (length(gv) <= 0.0) {
		return;
	}
	// The updraft is the component of the wind along -g. It was a buffer nobody filled.
	float up = dot(vec3(vel_x[g], vel_y[g], vel_z[g]), -normalize(gv));
	float wet = clamp(cloud[g] / max(params.lwc_ref, 1e-30), 0.0, 1.0);
	float lift = clamp(up / max(params.updraft_ref, 1e-30), 0.0, 1.0);
	float dq = params.rate_c_m3_s * band * wet * lift * params.dt_s;
	if (dq <= 0.0) {
		return;
	}
	// The heavy phase carries its charge DOWN, the light phase carries the opposite charge UP. The pair
	// is what separation means, so the transfer is between this cell and the one below it and nothing is
	// created. If there is no cell below, no separation happens: a charge with nowhere to go is not one.
	int below = la_step(g, normalize(gv));
	if (below < 0) {
		return;
	}
	charge[g] += dq;
	charge[uint(below)] -= dq;
}
