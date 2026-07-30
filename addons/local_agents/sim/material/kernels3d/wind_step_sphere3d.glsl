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
//     ±dim_x = z). On the sphere those two axes are the cell's own TANGENT FRAME (LASphereGrid.tan_a/tan_b),
//     which is a SEPARATE TABLE from the neighbour slots — see below. The gradient is assembled as a real
//     tangent VECTOR, 0.5 * sum over the four lateral neighbours of (p_n - p_c) * dir_n, where dir_n is the
//     unit direction toward that neighbour in this cell's own (a, b) components (`ltan`). In a clean face
//     interior dir is exactly (-1,0),(+1,0),(0,-1),(0,+1) and the sum collapses to the old
//     0.5*(p[2]-p[1]), 0.5*(p[4]-p[3]) — identical arithmetic, now without the assumption that made it so.
//     The two tangent components stay named vel_x / vel_z. The RADIAL pair (0,5) carries the vertical one.
//
//   * WHY THE SLOTS CANNOT BE THE FRAME (2026-07-30). This kernel used to declare vel_x as "tangent axis A
//     (slots 1/2)" and rotate that pair for Coriolis. The four lateral slots were doing two incompatible
//     jobs: the gather kernels need them slot-opposite RECIPROCAL, Coriolis needs them consistently HANDED,
//     and on a sphere no single table can be both (the handedness sign at a crossing is the transverse
//     intersection sign of two closed curves, and every closed curve on a sphere bounds, so the signed count
//     is exactly zero — measured 1732 right / 1724 left at res 24). Worse than a sign flip: 17.13% of links
//     had their two ends disagreeing about which way "tangent A" points, an interior defect scaling O(res^2).
//     The frame now comes from LASphereGrid.tan_a/tan_b — face-local geometric axes, right-handed on all six
//     faces by construction, discontinuous only at the seams, which is all Coriolis ever needed. `ltan`
//     carries that discontinuity so this kernel does not have to know about it.
//   * VEL_Y ↔ RADIAL-UP — the box vel_y is the world +Y vertical wind; on the sphere it is REDEFINED to be the
//     OUTWARD-RADIAL (up) component. Buoyant lift is therefore added to vel_y as the radial-up accel, using the
//     OUTWARD neighbour (slot 5) as the "cell above" (box used +layer). This keeps buoyancy AND the charge
//     kernel's updraft (which reads vel_y) consistent: vel_y > 0 = rising/outward air everywhere on the shell.
//   * BUOYANCY guard — box required a cell above (iy < dy-1); here it requires slot 5 >= 0 (an outward neighbour
//     exists) and that it is non-solid.
//   * PREVAILING inflow — the box strengthened the base-flow relax on domain-boundary cells (ix/iz on an edge).
//     On the sphere a cell is "on edge" iff any of its 4 lateral neighbours is a boundary (slot 1-4 == -1);
//     interior cells (all lateral neighbours present) get the gentle BODY_FORCE. A closed sphere has no
//     lateral boundary, so in practice every cell takes BODY_FORCE. (pvx/pvz remain the prevailing wind
//     projected onto the two tangent axes by the dispatch side, exactly as the box supplied them.)
//
//   * TERRAIN DEFLECTION — cannot blow INTO a solid/boundary neighbour. Instead of zeroing a whole named
//     component, the horizontal velocity has its projection onto each BLOCKED link direction removed. In a
//     face interior that is exactly the old "zero vel_x against slot 2/1, vel_z against slot 4/3"; near a
//     seam it is the same statement without needing the link to be axis-aligned. vel_y is still zeroed
//     against slot 5 (outward) / slot 0 (inward), which are genuinely the radial directions.
//
// DELETED HERE (2026-07-30): the latitude-banded base flow `u(lat) = -BASE_WIND*cos(3*lat)`, BASE_WIND = 6.0.
// It drew the trades and the mid-latitude westerlies in by hand — the same species of fake as the ATMOS_RELAX
// temperature anchor. It existed because the old pass A had no altitude term at all, so the atmosphere had no
// vertical structure and a thermal wind was not representable; with nothing to make a jet, a jet was asserted.
// Pass A now integrates real hydrostatic pressure over a conserved air mass, so the equator-to-pole gradient
// aloft is a consequence of the temperature field and the zonal bands emerge from it through Coriolis. The
// world position buffer (binding 13) went with the cosine — it was read only to rebuild the local tangent
// basis the band vector had to be projected onto. `radial` (binding 14) stays: Coriolis still needs latitude.
// Measured cost of the deletion, in the bench: mean zonal wind aloft falls from 0.92 (cosine-driven) to 0.078
// (thermal-wind-driven). The structure is now real and the magnitude is honest; it is not the same number.

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
	float pvx;        // legacy global prevailing wind on tangent axis A (still relaxed toward, now near-zero)
	float pvz;        // legacy global prevailing wind on tangent axis B
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

// Wind dynamics.
// PRESSURE-GRADIENT FORCE. The acceleration a parcel feels is (1/rho)*grad(p), NOT a constant times grad(p) —
// the same pressure difference throws thin air much harder than dense air. That distinction was not
// expressible before: there was no air mass in the substrate, so the gain had to be the constant ACCEL = 0.5.
// Pass A now carries a real air mass, and the hydrostatic relation it integrates (dp/dz = -rho*g with g =
// G_ACC) fixes the density exactly: rho = air/dz. With the lateral spacing equal to the radial one, the whole
// (1/rho)*grad(p) reduces to gx/air. So the gain is per-cell 1/air, and it rises by more than an order of
// magnitude from the surface to the top of the atmosphere. That is the second half of the jet: the thermal
// gradient aloft is what pushes, and thin air aloft is why the same push moves that air so much faster than
// it moves the dense air at the surface. AIR_FLOOR caps the gain where a column is nearly empty.
const float AIR_FLOOR = 0.02;       // density floor: caps the 1/rho gain at 50x (top-of-atmosphere guard)
// DRAG IS A SURFACE PROPERTY. Wind slows because it rubs on the ground; there is nothing aloft for it to rub
// on. A single height-independent DAMP therefore says "the whole atmosphere is dragging on the planet", and
// that one assumption is what forbids a jet: it makes friction (0.10/step, DAMP plus the prevailing relax)
// beat Coriolis (CORIOLIS*sin(lat)*dt = 0.048 at mid-latitudes) at EVERY height, so the flow can never turn
// geostrophic and has no reason to be faster aloft than at the surface. Measured with a uniform DAMP: the
// meridional overturning came out correct (equatorward at the surface, poleward aloft) but the zonal wind was
// barotropic — 0.082 at the surface against 0.083 aloft, a ratio of 1.01, which is not a jet.
// So drag decays with altitude on the BL_HEIGHT scale, from DAMP_SURFACE at the ground to DAMP_FREE in the
// free atmosphere. The surface value is unchanged, so surface wind (what creatures and fire actually feel)
// keeps its old behaviour; only the free atmosphere is released.
const float DAMP_SURFACE = 0.08;    // linear drag fraction removed per step at the ground (the old DAMP)
const float DAMP_FREE = 0.010;      // residual drag in the free atmosphere
const float BL_HEIGHT = 40.0;       // boundary-layer e-folding height, world units (2.5 cells)
const float MAX_WIND = 24.0;        // velocity magnitude clamp (stability)
const float BUOY_ACCEL = 0.5;       // upward accel per °C of (this cell − cell above) temperature inversion
const float BUOY_ACCEL_MAX = 6.0;   // cap the buoyant accel before the dt scale (stability)
const float CORIOLIS = 0.6;         // sideways deflection of horizontal wind → pressure lows SPIN
const float EDGE_FORCE = 0.30;      // boundary cells relax this fraction toward the base flow (inflow)
const float BODY_FORCE = 0.02;      // interior cells relax this gentle fraction toward the base flow
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
	// are (-1,0),(+1,0),(0,-1),(0,+1) and this is bit-for-bit the old 0.5*(p_hi - p_lo) on each axis.
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

	// (1/rho)*grad(p), with rho taken from this cell's own air mass — see AIR_FLOOR above.
	float accel = 1.0 / max(air[g], AIR_FLOOR);
	float nvx = vel_x[g] - gx * accel * params.dt;
	float nvz = vel_z[g] - gz * accel * params.dt;
	float nvy = vel_y[g];

	// BUOYANCY (radial-up wind): a hot cell under a cooler open cell rises. Uses the OUTWARD neighbour (slot 5)
	// as the cell above. Subsumes VAPOR_RISE.
	if (params.buoy == 1u && s_up >= 0 && solid[s_up] == 0.0) {
		float inv = temp[g] - temp[s_up];
		if (inv > 0.0) {
			nvy += min(inv * BUOY_ACCEL, BUOY_ACCEL_MAX) * params.dt;
		}
	}

	// LATITUDE from geometry: sin(lat) = dot(outward radial, spin axis). Equator → 0, poles → ±1.
	uint rb = g * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 spin_axis = vec3(params.spin_x, params.spin_y, params.spin_z);
	float slen = length(spin_axis);
	spin_axis = slen > 1e-5 ? spin_axis / slen : vec3(0.0, 1.0, 0.0);
	float sinlat = clamp(dot(cell_radial, spin_axis), -1.0, 1.0);

	// CORIOLIS scaled by sin(lat): ZERO at the equator (winds flow straight down the pressure gradient), full
	// at the poles, and OPPOSITE-signed between hemispheres (sinlat flips) → correct cyclonic/anticyclonic
	// handedness N vs S. A rotating low (vortex) still EMERGES; now it emerges with real latitude structure.
	//
	// SIGN CORRECTED 2026-07-30 — it used to deflect the wrong way, and until the tangent frame got its own
	// table nothing could tell. The Coriolis acceleration is a = -2*omega x v. With omega = Omega*spin_axis
	// (spin_axis IS the north pole, by the right-hand rule of the planet's own rotation) its horizontal part
	// is -f*(radial x v), f = 2*Omega*sin(lat). The frame is right-handed — tan_a x tan_b = radial — so
	// radial x v is the +90 degree rotation (a -> b), i.e. components (-v_b, v_a). Therefore
	//     v' = v - f*dt*(-v_b, v_a) = (v_a + f*dt*v_b,  v_b - f*dt*v_a),
	// which deflects eastward motion toward the equator in the northern hemisphere: to the RIGHT, as it must.
	// The old form was (v_a - k*v_b, v_b + k*v_a) — the exact negative, a deflection to the LEFT.
	// This was invisible while the frame came from the neighbour slots, because that frame was 50/50 handed
	// (1732 right / 1724 left at res 24), so "the sign of the deflection" was not a defined quantity.
	// Measured consequence, bench_atmosphere_column at res 24 / 400 steps: the thermal-wind maximum aloft is
	// the same size and sits in the same place either way, but it blew EAST-to-WEST at -1.95 (shell 17,
	// 15-30 deg) before and WEST-to-EAST after. The overturning was right all along and is untouched:
	// poleward aloft, equatorward at the surface.
	float rvx = nvx + CORIOLIS * sinlat * nvz * params.dt;
	float rvz = nvz - CORIOLIS * sinlat * nvx * params.dt;
	nvx = rvx;
	nvz = rvz;

	// LEGACY PREVAILING relax, all that is left of the base-flow term now the latitude-band cosine is gone. The
	// dispatch side supplies pvx/pvz (the global prevailing wind projected onto the tangent axes); on a closed
	// sphere no cell is on a lateral boundary, so this is a uniform gentle pull toward that one vector. It is
	// NOT a banded pattern and it does not know about latitude — nothing here prescribes where wind should be.
	// It rides the same boundary-layer profile as the drag, because it IS a drag: a pull toward a wind fixed
	// somewhere else. Left height-independent it would be the single largest friction aloft (0.02 against
	// DAMP_FREE's 0.006) and would hold the free atmosphere back on its own.
	bool on_edge = (lat[0] < 0 || lat[1] < 0 || lat[2] < 0 || lat[3] < 0);
	float force = (on_edge ? EDGE_FORCE : BODY_FORCE) * bl;
	nvx += (params.pvx - nvx) * force;
	nvz += (params.pvz - nvz) * force;

	// DRAG. HORIZONTAL drag tapers through the boundary layer (see DAMP_SURFACE / DAMP_FREE / BL_HEIGHT).
	// VERTICAL drag deliberately does NOT: it keeps the full surface value at every height. The buoyancy term
	// above compares RAW temperature against the cell overhead, so any lapse rate at all reads as unstable —
	// a real atmosphere is stable until the lapse exceeds the adiabatic one, which needs potential temperature
	// this substrate does not carry. The vertical drag is what stands in for that missing stability, and it is
	// the only thing bounding the updraft. Measured with it tapered: the mean radial wind reached 10.5 and
	// saturated the MAX_WIND clamp, drowning the horizontal circulation this pass exists to produce.
	nvx *= (1.0 - damp);
	nvy *= (1.0 - DAMP_SURFACE);
	nvz *= (1.0 - damp);

	// TERRAIN DEFLECTION + OROGRAPHIC UPLIFT: air cannot blow INTO a solid/boundary neighbour. Instead of simply
	// discarding that horizontal momentum, the component blocked by RISING TERRAIN is banked and converted to
	// radial-UP wind (vel_y) if there is open sky above — the air is forced up and over the mountain. That uplift
	// feeds the buoyancy/condensation chain, so the windward slope gets the rising-air rain and the lee stays dry
	// (a rain shadow) — orographic precipitation falls out, no special-case code.
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
