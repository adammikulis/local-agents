#[compute]
#version 450

#include "neighbours.glsli"


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PressureIn { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer AirIn { float air[]; };   // pass A's fresh air mass
layout(set = 0, binding = 7, std430) restrict readonly buffer WaterIn { float water[]; };  // surface roughness
layout(set = 0, binding = 3, std430) restrict buffer VelX { float vel_x[]; };   // along the cell's tan_a
layout(set = 0, binding = 4, std430) restrict buffer VelY { float vel_y[]; };   // OUTWARD-RADIAL (up) (slots 0/5)
layout(set = 0, binding = 5, std430) restrict buffer VelZ { float vel_z[]; };   // along the cell's tan_b
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; }; // per-cell outward unit vec, flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot
// LASphereGrid.link_tan, per SURFACE column: ((g/depth)*4 + l)*2 + {0,1} is the unit direction toward the
// lateral slot l neighbour in this cell's own (tan_a, tan_b) axes.
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };
// LASphereGrid.link_arc: (g/depth)*4 + l, radians between the two cell centres.
layout(set = 0, binding = 41, std430) restrict readonly buffer LinkArc { float larc[]; };
// LASphereGrid.link_rot: ((g/depth)*4 + l)*2, the (cos, sin) carrying MY axes into the neighbour's.
layout(set = 0, binding = 43, std430) restrict readonly buffer LinkRot { float lrot[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;         // seconds
	uint buoy;        // 1 = buoyancy enabled (MaterialWind3D._enable_buoyancy)
	float spin_x;     // planet SPIN AXIS (north pole) in the field frame — latitude + banded-flow reference
	float spin_y;
	float spin_z;
	uint depth;       // radial shells per column — gives this cell's shell as (g % depth)
	uint pad0;
} params;

#include "shell.glsli"

const float GRAVITY_M_S2 = 9.80665;        // LAPhysical.STANDARD_GRAVITY_M_S2
const float AIR_DENSITY_KG_M3 = 1.225;     // LAPhysical.AIR_DENSITY_KG_M3
const float METRES_PER_MODEL_UNIT = 168.6; // LAPhysical.METRES_PER_MODEL_UNIT
const float AIR_SPECIFIC_HEAT_J_KGK = 1005.0;   // LAPhysical.AIR_SPECIFIC_HEAT_J_KGK
const float T0_K = 273.15;                 // LAPhysical.KELVIN_OFFSET
// Dry adiabatic lapse rate, K/m: the rate a rising parcel cools on its own, so only a column steeper than
// this is convectively unstable.
const float GAMMA_DRY_K_PER_M = GRAVITY_M_S2 / AIR_SPECIFIC_HEAT_J_KGK;
const float TWO_OMEGA = 1.45842318e-4;   // LAPhysical.CORIOLIS_TWO_OMEGA_RAD_S
const float VON_KARMAN = 0.4;            // LAPhysical.VON_KARMAN_CONSTANT
const float Z0_SEA_M = 2.0e-4;           // LAPhysical.ROUGHNESS_LENGTH_SEA_M
const float Z0_LAND_M = 0.03;            // LAPhysical.ROUGHNESS_LENGTH_LAND_M
const float SMAGORINSKY_C = 0.1651;      // LAPhysical.SMAGORINSKY_COEFF
const float OROG_LIFT = 0.5;        // fraction of horizontal momentum blocked by rising terrain that becomes UPLIFT

// A cell carries wind only where it carries air.
bool moving(int c) {
	return c >= 0 && solid[c] == 0.0 && air[c] > 0.0;
}

// The neighbour's tangential velocity read in MY axes. link_rot carries mine into theirs, so the inverse
// rotation brings theirs back.
vec2 nbr_tan(uint m, uint rb) {
	float cs = lrot[rb];
	float sn = lrot[rb + 1u];
	return vec2(vel_x[m] * cs + vel_z[m] * sn, -vel_x[m] * sn + vel_z[m] * cs);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	// Rock has no wind, and neither has a cell holding no air: the ocean interior and the sub-surface carry
	// their column's surface pressure for the radiation kernels, not an air mass that can be accelerated.
	if (solid[g] != 0.0 || air[g] <= 0.0) {
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		return;
	}

	uint base = g * 6u;
	uint depth = max(params.depth, 1u);
	uint shell = g % depth;
	int s_dn = nbr[base + N_IN];
	int s_up = nbr[base + N_OUT];
	float dz_up = shell_d_out(shell) * METRES_PER_MODEL_UNIT;
	float dz_dn = shell_d_in(shell) * METRES_PER_MODEL_UNIT;

	// The four lateral links: index, direction in THIS cell's tangent frame, the real centre-to-centre run
	// in metres, and the neighbour's velocity brought into this frame.
	uint lb = (g / depth) * 8u;
	uint ab = (g / depth) * 4u;
	int lat[4];
	vec2 ldir[4];
	float lrun[4];
	vec2 lvel[4];
	float lvy[4];
	for (int l = 0; l < 4; ++l) {
		lat[l] = nbr[base + N_LAT0 + uint(l)];
		ldir[l] = vec2(ltan[lb + uint(l) * 2u], ltan[lb + uint(l) * 2u + 1u]);
		lrun[l] = max(larc[ab + uint(l)] * shell_mid(shell) * METRES_PER_MODEL_UNIT, 1.0e-6);
		lvel[l] = moving(lat[l]) ? nbr_tan(uint(lat[l]), lb + uint(l) * 2u) : vec2(0.0);
		lvy[l] = moving(lat[l]) ? vel_y[lat[l]] : 0.0;
	}

	vec2 v0 = vec2(vel_x[g], vel_z[g]);
	float w0 = vel_y[g];
	float p0c = pressure[g];

	// PRESSURE GRADIENT as a real tangent vector, Pa per METRE: 0.5 * sum (p_n - p_c)/run * dir_n over the
	// four lateral links. A link whose far end holds no air carries no air-pressure difference.
	vec2 grad = vec2(0.0);
	for (int l = 0; l < 4; ++l) {
		if (!moving(lat[l])) {
			continue;
		}
		grad += (0.5 * (pressure[lat[l]] - p0c) / lrun[l]) * ldir[l];
	}

	// (1/rho) grad(p), m/s^2. rho is the air the cell actually holds.
	float rho = AIR_DENSITY_KG_M3 * air[g];
	vec2 vh = v0 - grad / rho * params.dt;
	float nvy = w0;

	// BUOYANCY (radial-up wind): a column steeper than the dry adiabat is unstable and overturns. Comparing
	// the two temperatures alone made every normally-stratified cell rise, because a colder cell above is
	// the ordinary state of an atmosphere.
	if (params.buoy == 1u && moving(s_up)) {
		float excess = (temp[g] - temp[s_up]) - GAMMA_DRY_K_PER_M * dz_up;
		if (excess > 0.0) {
			nvy += GRAVITY_M_S2 * (excess / max(temp[g] + T0_K, 1.0)) * params.dt;
		}
	}

	// LATITUDE from geometry: sin(lat) = dot(outward radial, spin axis). Equator → 0, poles → ±1.
	uint rb = g * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 spin_axis = vec3(params.spin_x, params.spin_y, params.spin_z);
	float slen = length(spin_axis);
	spin_axis = slen > 1e-5 ? spin_axis / slen : vec3(0.0, 1.0, 0.0);
	float sinlat = clamp(dot(cell_radial, spin_axis), -1.0, 1.0);
	vh = vec2(vh.x + TWO_OMEGA * sinlat * vh.y * params.dt,
			vh.y - TWO_OMEGA * sinlat * vh.x * params.dt);

	// --- DEFORMATION -> SUBGRID VISCOSITY ------------------------------------------------------------
	// Smagorinsky: nu = (C_s * filter)^2 * |S|, |S| = sqrt(2 S_ij S_ij). The lateral gradient uses the same
	// construction as the pressure gradient, which is exact for a linear field on this stencil.
	mat2 gr = mat2(0.0);
	for (int l = 0; l < 4; ++l) {
		if (!moving(lat[l])) {
			continue;
		}
		vec2 dv = (lvel[l] - v0) * (0.5 / lrun[l]);
		gr[0][0] += dv.x * ldir[l].x;
		gr[1][0] += dv.x * ldir[l].y;
		gr[0][1] += dv.y * ldir[l].x;
		gr[1][1] += dv.y * ldir[l].y;
	}
	vec2 dv_dy = vec2(0.0);
	float dw_dy = 0.0;
	if (moving(s_up) && moving(s_dn)) {
		dv_dy = (vec2(vel_x[s_up], vel_z[s_up]) - vec2(vel_x[s_dn], vel_z[s_dn])) / (dz_up + dz_dn);
		dw_dy = (vel_y[s_up] - vel_y[s_dn]) / (dz_up + dz_dn);
	} else if (moving(s_up)) {
		dv_dy = (vec2(vel_x[s_up], vel_z[s_up]) - v0) / dz_up;
		dw_dy = (vel_y[s_up] - w0) / dz_up;
	} else if (moving(s_dn)) {
		dv_dy = (v0 - vec2(vel_x[s_dn], vel_z[s_dn])) / dz_dn;
		dw_dy = (w0 - vel_y[s_dn]) / dz_dn;
	}
	float s_ab = 0.5 * (gr[1][0] + gr[0][1]);
	float mag = sqrt(2.0 * (gr[0][0] * gr[0][0] + gr[1][1] * gr[1][1] + dw_dy * dw_dy
			+ 2.0 * s_ab * s_ab + 0.5 * dot(dv_dy, dv_dy)));
	float lat_mean = 0.25 * (lrun[0] + lrun[1] + lrun[2] + lrun[3]);
	float filter_m = pow(lat_mean * lat_mean * shell_dr(shell) * METRES_PER_MODEL_UNIT, 1.0 / 3.0);
	float nu = SMAGORINSKY_C * SMAGORINSKY_C * filter_m * filter_m * mag;

	// --- MOMENTUM TRANSPORT: upwind advection and that viscosity, as ONE implicit gather --------------
	// v = (v + sum w_k v_k) / (1 + sum w_k) is backward Euler for both terms at once. It is a convex
	// combination of the cell and its neighbours, so it is bounded at any wind speed and needs no cap.
	float wsum = 0.0;
	vec2 vacc = vec2(0.0);
	float wacc = 0.0;
	for (int l = 0; l < 4; ++l) {
		if (!moving(lat[l])) {
			continue;
		}
		float inflow = max(-dot(vh, ldir[l]), 0.0);
		float wk = (inflow / lrun[l] + nu / (lrun[l] * lrun[l])) * params.dt;
		wsum += wk;
		vacc += wk * lvel[l];
		wacc += wk * lvy[l];
	}
	if (moving(s_dn)) {
		float wk = (max(nvy, 0.0) / dz_dn + nu / (dz_dn * dz_dn)) * params.dt;
		wsum += wk;
		vacc += wk * vec2(vel_x[s_dn], vel_z[s_dn]);
		wacc += wk * vel_y[s_dn];
	}
	if (moving(s_up)) {
		float wk = (max(-nvy, 0.0) / dz_up + nu / (dz_up * dz_up)) * params.dt;
		wsum += wk;
		vacc += wk * vec2(vel_x[s_up], vel_z[s_up]);
		wacc += wk * vel_y[s_up];
	}
	float inv = 1.0 / (1.0 + wsum);
	vh = (vh + vacc) * inv;
	nvy = (nvy + wacc) * inv;

	// --- SURFACE STRESS: bulk drag in the cell that touches the ground, over that cell's thickness ---
	// dv/dt = -C_d |v| v / h, C_d the log law at the cell's mid-height over the surface's roughness
	// length, so it follows from two lengths rather than being chosen.
	if (!moving(s_dn)) {
		float h_m = shell_dr(shell) * METRES_PER_MODEL_UNIT;
		float wet = (s_dn >= 0) ? clamp(water[s_dn], 0.0, 1.0) : 0.0;
		float z0 = mix(Z0_LAND_M, Z0_SEA_M, wet);
		float ln_r = log(max(0.5 * h_m / z0, 1.0001));
		float cd = (VON_KARMAN / ln_r) * (VON_KARMAN / ln_r);
		vh *= 1.0 / (1.0 + cd * length(vh) / h_m * params.dt);
	}

	float blocked = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = lat[l];
		if (m >= 0 && solid[m] == 0.0) {
			continue;                      // open: nothing in the way
		}
		float into = dot(vh, ldir[l]);
		if (into > 0.0) {
			vh -= into * ldir[l];          // remove only the component aimed at the wall
			blocked += into;
		}
	}
	if (blocked > 0.0 && s_up >= 0 && solid[s_up] == 0.0) {
		nvy += blocked * OROG_LIFT;   // windward uplift over the ridge
	}
	if (nvy > 0.0 && (s_up < 0 || solid[s_up] != 0.0)) {
		nvy = 0.0;
	} else if (nvy < 0.0 && (s_dn < 0 || solid[s_dn] != 0.0)) {
		nvy = 0.0;
	}

	vel_x[g] = vh.x;
	vel_y[g] = nvy;
	vel_z[g] = vh.y;
}
