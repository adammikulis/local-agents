#[compute]
#version 450

// CUBED-SPHERE WIND — PASS B: velocity update. Sphere port of wind_step3d.glsl (box). Each non-solid cell
// accelerates its own velocity DOWN the pressure gradient (PASS A's field), adds buoyant lift, curls
// sideways (Coriolis), relaxes toward the prevailing base flow, damps, deflects off rock faces, and
// magnitude-clamps. Reads pressure + temp + solid + its OWN velocity and writes its OWN velocity → per-cell,
// no neighbour-VELOCITY reads, so it updates the velocity buffers IN PLACE exactly like the CPU oracle.
//
// The ONLY change vs the box is neighbour ADDRESSING — the pressure/buoyancy/Coriolis/drag/clamp MATH is kept
// structurally identical. Box idx±offset → INDEX TABLE nbr[idx*6 + d] (slot 0 = inward/radial-DOWN,
// 1-4 = LATERAL, 5 = outward/radial-UP; -1 = boundary; a solid/boundary neighbour REFLECTS = reads p0c):
//
//   * PRESSURE GRADIENT — the box took central differences over the two lateral world axes (±1 = x,
//     ±dim_x = z). On the sphere those two axes become the two LATERAL SLOT PAIRS: slot pair (1,2) is one
//     tangent axis (the "x-analog": slot 2 = +x/high, slot 1 = -x/low → gx = 0.5·(p[2]-p[1])), slot pair
//     (3,4) the other tangent axis (the "z-analog": slot 4 = +z/high, slot 3 = -z/low → gz = 0.5·(p[4]-p[3])).
//     This matches the (1<->2),(3<->4) lateral pairing used by the water/slump/lava sphere ports. The two
//     tangent components stay named vel_x / vel_z. The RADIAL pair (0,5) carries the vertical component.
//   * VEL_Y ↔ RADIAL-UP — the box vel_y is the world +Y vertical wind; on the sphere it is REDEFINED to be the
//     OUTWARD-RADIAL (up) component. Buoyant lift is therefore added to vel_y as the radial-up accel, using the
//     OUTWARD neighbour (slot 5) as the "cell above" (box used +layer). This keeps buoyancy AND the charge
//     kernel's updraft (which reads vel_y) consistent: vel_y > 0 = rising/outward air everywhere on the shell.
//   * BUOYANCY guard — box required a cell above (iy < dy-1); here it requires slot 5 >= 0 (an outward neighbour
//     exists) and that it is non-solid.
//   * PREVAILING inflow — the box strengthened the base-flow relax on domain-boundary cells (ix/iz on an edge).
//     On the sphere a cell is "on edge" iff any of its 4 lateral neighbours is a boundary (slot 1-4 == -1);
//     interior cells (all lateral neighbours present) get the gentle BODY_FORCE. (pvx/pvz remain the prevailing
//     wind projected onto the two tangent axes by the dispatch side, exactly as the box supplied them.)
//   * TERRAIN DEFLECTION — cannot blow INTO a solid/boundary neighbour: zero vel_x against slot 2/1, vel_z
//     against slot 4/3, vel_y against slot 5 (outward) / slot 0 (inward), same sign logic as the box.
// Constants copied EXACTLY from MaterialWind3D.gd — do not diverge.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PressureIn { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict buffer VelX { float vel_x[]; };   // tangent axis A (slots 1/2)
layout(set = 0, binding = 4, std430) restrict buffer VelY { float vel_y[]; };   // OUTWARD-RADIAL (up) (slots 0/5)
layout(set = 0, binding = 5, std430) restrict buffer VelZ { float vel_z[]; };   // tangent axis B (slots 3/4)
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float pvx;        // prevailing wind on tangent axis A
	float pvz;        // prevailing wind on tangent axis B
	float dt;         // STEP_DT
	uint buoy;        // 1 = buoyancy enabled (MaterialWind3D._enable_buoyancy)
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Wind dynamics — MUST match MaterialWind3D.gd exactly.
const float ACCEL = 0.5;            // pressure-gradient -> velocity acceleration gain (× dt)
const float DAMP = 0.08;            // linear drag fraction removed from velocity each step
const float MAX_WIND = 24.0;        // velocity magnitude clamp (stability)
const float BUOY_ACCEL = 0.5;       // upward accel per °C of (this cell − cell above) temperature inversion
const float BUOY_ACCEL_MAX = 6.0;   // cap the buoyant accel before the dt scale (stability)
const float CORIOLIS = 0.6;         // sideways deflection of horizontal wind → pressure lows SPIN
const float EDGE_FORCE = 0.30;      // boundary cells relax this fraction toward the prevailing wind (inflow)
const float BODY_FORCE = 0.02;      // interior cells relax this gentle fraction toward the prevailing wind

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		return;
	}

	uint base = g * 6u;
	int s_dn = nbr[base + 0u];   // radial DOWN
	int s_xlo = nbr[base + 1u];  // tangent A -x
	int s_xhi = nbr[base + 2u];  // tangent A +x
	int s_zlo = nbr[base + 3u];  // tangent B -z
	int s_zhi = nbr[base + 4u];  // tangent B +z
	int s_up = nbr[base + 5u];   // radial UP (outward)

	float p0c = pressure[g];

	// Central-difference pressure gradient over each tangent slot pair; a solid/boundary neighbour reflects (p0c).
	float px_hi = (s_xhi >= 0 && solid[s_xhi] == 0.0) ? pressure[s_xhi] : p0c;
	float px_lo = (s_xlo >= 0 && solid[s_xlo] == 0.0) ? pressure[s_xlo] : p0c;
	float pz_hi = (s_zhi >= 0 && solid[s_zhi] == 0.0) ? pressure[s_zhi] : p0c;
	float pz_lo = (s_zlo >= 0 && solid[s_zlo] == 0.0) ? pressure[s_zlo] : p0c;
	float gx = 0.5 * (px_hi - px_lo);
	float gz = 0.5 * (pz_hi - pz_lo);

	float nvx = vel_x[g] - gx * ACCEL * params.dt;
	float nvz = vel_z[g] - gz * ACCEL * params.dt;
	float nvy = vel_y[g];

	// BUOYANCY (radial-up wind): a hot cell under a cooler open cell rises. Uses the OUTWARD neighbour (slot 5)
	// as the cell above. Subsumes VAPOR_RISE.
	if (params.buoy == 1u && s_up >= 0 && solid[s_up] == 0.0) {
		float inv = temp[g] - temp[s_up];
		if (inv > 0.0) {
			nvy += min(inv * BUOY_ACCEL, BUOY_ACCEL_MAX) * params.dt;
		}
	}

	// CORIOLIS-like deflection: air rushing into a pressure low is curled sideways → a rotating low (vortex)
	// EMERGES. Semi-implicit rotation by the pre-rotation tangent components. Must match MaterialWind3D.gd.
	float rvx = nvx - CORIOLIS * nvz * params.dt;
	float rvz = nvz + CORIOLIS * nvx * params.dt;
	nvx = rvx;
	nvz = rvz;

	// PREVAILING base flow: stronger on a domain-boundary cell (any lateral neighbour missing = inflow edge),
	// gentle in the interior.
	bool on_edge = (s_xlo < 0 || s_xhi < 0 || s_zlo < 0 || s_zhi < 0);
	float force = on_edge ? EDGE_FORCE : BODY_FORCE;
	nvx += (params.pvx - nvx) * force;
	nvz += (params.pvz - nvz) * force;

	// DRAG.
	nvx *= (1.0 - DAMP);
	nvy *= (1.0 - DAMP);
	nvz *= (1.0 - DAMP);

	// TERRAIN DEFLECTION: cannot blow INTO a solid/boundary neighbour — zero that component.
	if (nvx > 0.0 && (s_xhi < 0 || solid[s_xhi] != 0.0)) {
		nvx = 0.0;
	} else if (nvx < 0.0 && (s_xlo < 0 || solid[s_xlo] != 0.0)) {
		nvx = 0.0;
	}
	if (nvz > 0.0 && (s_zhi < 0 || solid[s_zhi] != 0.0)) {
		nvz = 0.0;
	} else if (nvz < 0.0 && (s_zlo < 0 || solid[s_zlo] != 0.0)) {
		nvz = 0.0;
	}
	if (nvy > 0.0 && (s_up < 0 || solid[s_up] != 0.0)) {
		nvy = 0.0;
	} else if (nvy < 0.0 && (s_dn < 0 || solid[s_dn] != 0.0)) {
		nvy = 0.0;
	}

	// Magnitude clamp (stability).
	float sp2 = nvx * nvx + nvy * nvy + nvz * nvz;
	if (sp2 > MAX_WIND * MAX_WIND) {
		float s = MAX_WIND / sqrt(sp2);
		nvx *= s;
		nvy *= s;
		nvz *= s;
	}

	vel_x[g] = nvx;
	vel_y[g] = nvy;
	vel_z[g] = nvz;
}
