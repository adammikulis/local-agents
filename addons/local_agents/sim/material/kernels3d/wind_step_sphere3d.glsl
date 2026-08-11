#[compute]
#version 450

// structurally identical. Box idx±offset → INDEX TABLE nbr[idx*6 + d] (slot 0 = inward/radial-DOWN,
//     OUTWARD neighbour (slot 5) as the "cell above" (box used +layer). This keeps buoyancy AND the charge
//   * BUOYANCY guard — box required a cell above (iy < dy-1); here it requires slot 5 >= 0 (an outward neighbour
//     On the sphere a cell is "on edge" iff any of its 4 lateral neighbours is a boundary (slot 1-4 == -1);
//     face interior that is exactly the old "zero vel_x against slot 2/1, vel_z against slot 4/3"; near a
//     against slot 5 (outward) / slot 0 (inward), which are genuinely the radial directions.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PressureIn { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer AirIn { float air[]; };   // pass A's fresh air mass
layout(set = 0, binding = 3, std430) restrict buffer VelX { float vel_x[]; };   // along the cell's tan_a
layout(set = 0, binding = 4, std430) restrict buffer VelY { float vel_y[]; };   // OUTWARD-RADIAL (up) (slots 0/5)
layout(set = 0, binding = 5, std430) restrict buffer VelZ { float vel_z[]; };   // along the cell's tan_b
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; }; // per-cell outward unit vec, flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot
// TANGENT-FRAME table (LASphereGrid.link_tan), per SURFACE column: ((g/depth)*4 + l)*2 + {0,1} is the unit
// direction toward the lateral slot l+1 neighbour, in THIS cell's own (tan_a, tan_b) components.
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt;         // STEP_DT
	uint buoy;        // 1 = buoyancy enabled (MaterialWind3D._enable_buoyancy)
	float spin_x;     // planet SPIN AXIS (north pole) in the field frame — latitude + banded-flow reference
	float spin_y;
	float spin_z;
	uint depth;          // radial shells per column — gives this cell's shell as (g % depth), hence its altitude
	float core_radius;   // inner radius of shell 0
	float cell_size;
	float sea_radius;    // altitude datum for the boundary layer
} params;

const float AIR_FLOOR = 0.02;       // density floor in AIR UNITS: caps the 1/rho gain at 50x (top-of-atmosphere)
// `pressure` is in PASCALS, so the gradient is Pa per model unit and is divided by the metres one cell
// spans; rho is kg/m3, and the acceleration is m/s^2.
const float GRAVITY_M_S2 = 9.80665;        // LAPhysical.STANDARD_GRAVITY_M_S2
const float AIR_DENSITY_KG_M3 = 1.18;      // LAPhysical.AIR_DENSITY_KG_M3
const float KELVIN_0 = 273.15;             // LAPhysical.KELVIN_OFFSET
const float METRES_PER_MODEL_UNIT = 168.6; // LAPhysical.METRES_PER_MODEL_UNIT
const float DAMP_SURFACE = 0.08;    // linear drag fraction removed per step at the ground
const float DAMP_FREE = 0.010;      // residual drag in the free atmosphere
const float BL_HEIGHT = 40.0;       // boundary-layer e-folding height, world units (2.5 cells)
// Coriolis parameter f = 2*omega*sin(lat), rad/s.
const float TWO_OMEGA = 1.45842318e-4;   // LAPhysical.CORIOLIS_TWO_OMEGA_RAD_S
const float OROG_LIFT = 0.5;        // fraction of horizontal momentum blocked by rising terrain that becomes UPLIFT

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
	uint depth = max(params.depth, 1u);
	int s_dn = nbr[base + 0u];   // radial DOWN
	int s_up = nbr[base + 5u];   // radial UP (outward)

	// The four lateral links, each as an index and a direction in THIS cell's tangent frame.
	uint lb = (g / depth) * 8u;
	int lat[4];
	vec2 ldir[4];
	for (int l = 0; l < 4; ++l) {
		lat[l] = nbr[base + uint(l + 1)];
		ldir[l] = vec2(ltan[lb + uint(l) * 2u], ltan[lb + uint(l) * 2u + 1u]);
	}

	float p0c = pressure[g];

	// PRESSURE GRADIENT as a real tangent vector: 0.5 * sum (p_n - p_c) * dir_n over the four lateral links.
	// A solid/boundary neighbour reflects (contributes p0c, hence nothing). In a face interior the four dirs
	vec2 grad = vec2(0.0);
	for (int l = 0; l < 4; ++l) {
		int m = lat[l];
		float pn = (m >= 0 && solid[m] == 0.0) ? pressure[m] : p0c;
		grad += (0.5 * (pn - p0c)) * ldir[l];
	}
	float gx = grad.x;
	float gz = grad.y;

	// ALTITUDE, straight from the cell index: SphereGrid packs a column contiguously as c = s*depth + r, so the
	// radial shell is g % depth and its centre radius follows from the shell geometry. No position buffer needed.
	float shell = float(g % depth);
	float altitude = (params.core_radius + (shell + 0.5) * params.cell_size) - params.sea_radius;
	// Boundary layer: full surface drag at the ground, decaying to DAMP_FREE aloft (see the constants above).
	float bl = exp(-max(altitude, 0.0) / BL_HEIGHT);
	float damp = DAMP_FREE + (DAMP_SURFACE - DAMP_FREE) * bl;

	// (1/rho) grad(p) IN REAL UNITS: grad is Pa per model unit, so per METRE it is grad / cell_m; rho is
	// kg/m3 from this cell's own air mass. The result is m/s^2 and params.dt is REAL SECONDS, so velocity
	// comes out in m/s.
	float cell_m = params.cell_size * METRES_PER_MODEL_UNIT;
	float rho = AIR_DENSITY_KG_M3 * max(air[g], AIR_FLOOR);
	float inv_rho_dx = 1.0 / (rho * cell_m);
	float nvx = vel_x[g] - gx * inv_rho_dx * params.dt;
	float nvz = vel_z[g] - gz * inv_rho_dx * params.dt;
	float nvy = vel_y[g];

	// BUOYANCY (radial-up wind): a hot cell under a cooler open cell rises. Uses the OUTWARD neighbour (slot 5)
	// as the cell above. Subsumes VAPOR_RISE.
	if (params.buoy == 1u && s_up >= 0 && solid[s_up] == 0.0) {
		float inv = temp[g] - temp[s_up];
		if (inv > 0.0) {
			// Boussinesq buoyancy: a = g * dT / T. No cap — a runaway here means the momentum equation is
			// wrong, and hiding it behind a clamp is how it stays wrong.
			float t_here_k = temp[g] + KELVIN_0;
			nvy += GRAVITY_M_S2 * (inv / max(t_here_k, 1.0)) * params.dt;
		}
	}

	// LATITUDE from geometry: sin(lat) = dot(outward radial, spin axis). Equator → 0, poles → ±1.
	uint rb = g * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 spin_axis = vec3(params.spin_x, params.spin_y, params.spin_z);
	float slen = length(spin_axis);
	spin_axis = slen > 1e-5 ? spin_axis / slen : vec3(0.0, 1.0, 0.0);
	float sinlat = clamp(dot(cell_radial, spin_axis), -1.0, 1.0);

	float rvx = nvx + TWO_OMEGA * sinlat * nvz * params.dt;
	float rvz = nvz - TWO_OMEGA * sinlat * nvx * params.dt;
	nvx = rvx;
	nvz = rvz;

	nvx *= (1.0 - damp);
	nvy *= (1.0 - DAMP_SURFACE);
	nvz *= (1.0 - damp);

	float blocked = 0.0;
	vec2 vh = vec2(nvx, nvz);
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
	nvx = vh.x;
	nvz = vh.y;
	if (blocked > 0.0 && s_up >= 0 && solid[s_up] == 0.0) {
		nvy += blocked * OROG_LIFT;   // windward uplift over the ridge
	}
	if (nvy > 0.0 && (s_up < 0 || solid[s_up] != 0.0)) {
		nvy = 0.0;
	} else if (nvy < 0.0 && (s_dn < 0 || solid[s_dn] != 0.0)) {
		nvy = 0.0;
	}

	vel_x[g] = nvx;
	vel_y[g] = nvy;
	vel_z[g] = nvz;
}
