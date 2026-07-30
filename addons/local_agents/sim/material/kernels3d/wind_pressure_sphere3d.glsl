#[compute]
#version 450

// CUBED-SPHERE WIND — PASS A: AIR MASS + HYDROSTATIC PRESSURE. One thread per SURFACE COLUMN.
//
// WHAT THIS REPLACED, AND WHY. The old pass A was `pressure[g] = P0 - K_T*(temp[g] - T_REF)` — purely
// per-cell, no neighbours, no air, no altitude term. Pressure therefore did NOT fall with height at all, so
// the atmosphere had no vertical structure and a thermal wind was not representable. The jet had to be drawn
// in by hand instead (`u(lat) = -BASE_WIND*cos(3*lat)` in pass B, now deleted).
//
// WHAT IT IS NOW. `air` is a conserved substance (a PAIR channel like water/lava/moisture) and pressure is
// the WEIGHT OF THE AIR ABOVE — nothing else. Three real mechanisms, no prescribed answer:
//
//   1. COLUMN MASS is transported horizontally. Each column's air mass changes by the vertically-integrated
//      upwind mass flux through its four lateral faces. A face's flux is computed from the SAME upwind
//      expression on both sides (the send/gather symmetry co2_transport_sphere3d uses), so mass is conserved
//      to the face. This is the primitive-equation surface-pressure tendency dM/dt = -div(integral of rho*v dz).
//   2. VERTICAL DISTRIBUTION is hydrostatic, not advected. Within a column the mass settles onto the
//      exponential profile set by the LOCAL temperature: w[r] = w[r-1]*exp(-dz/H), H = H_PER_KELVIN * T.
//      This is the standard hydrostatic closure (real atmosphere models do not prognose vertical momentum
//      either), and it is what makes the column's THICKNESS temperature-dependent.
//   3. PRESSURE is integrated inward from space: p[r] = G_ACC * (mass above + half this cell's own mass).
//      Monotone decreasing outward by construction, because mass is non-negative.
//
// WHY A JET FALLS OUT OF THAT. Two columns holding the SAME mass but at different temperatures do not hold
// it at the same heights: the warm column has the larger scale height, so more of its mass is still above any
// given altitude aloft. Warm column => higher pressure aloft at equal height. The equator is warm and the
// poles are cold, so aloft there is a real equator-to-pole pressure gradient that GROWS with height; pass B
// accelerates air poleward down it and Coriolis turns that into a mid-latitude westerly maximum aloft. That
// is the thermal wind, du/dz ~ -(g/fT)*dT/dy, arriving as a consequence rather than as a cosine. The return
// half is just as free: poleward flow aloft drains the equatorial column, so its surface pressure FALLS (the
// equatorial low) and the polar column's rises, driving the low-level flow back equatorward into easterly
// trades. Hadley circulation and the trade winds are then things the substrate does, not things it is told.
//
// GEOMETRY. Cell index is c = s*depth + r (SphereGrid.cell_of), so a radial column is CONTIGUOUS in memory
// and a column walk is a stride-1 loop. Threads = surf_count = cell_count/depth. Each thread makes a fixed
// number of O(depth) walks (and reads 4 neighbour columns once, in the flux walk), so total work is O(cells)
// — the same asymptotic class as any per-cell pass, at 1/depth the thread count. No arrays are held in
// registers: the hydrostatic weight w is a running product, recomputed by recurrence in each walk.
//
// WHAT COUNTS AS ATMOSPHERE. Scanning inward from the top, the atmosphere is the contiguous run of non-solid
// cells whose centre radius is at or above the sea shell. That stops it at the ground on land and at the sea
// surface over ocean. Without the sea cut the ocean interior (water is not `solid`) would read as ~10 extra
// cells of air per ocean column and manufacture a permanent land-sea pressure step. Open cells BELOW the
// atmosphere (ocean interior, caves) carry the column's surface pressure, so sub-surface flow still sees the
// real horizontal pressure field without inventing a vertical one.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float air_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer AirOut { float air_out[]; };  // written then re-read by the SAME thread
layout(set = 0, binding = 2, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer PressureOut { float pressure[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };   // along the cell's tan_a
layout(set = 0, binding = 6, std430) restrict readonly buffer VelZ { float vel_z[]; };   // along the cell's tan_b
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };     // idx*6 + slot
// Per-column tangent-frame table (LASphereGrid.link_tan): ((cell/depth)*4 + l)*2 is the unit direction toward
// the lateral slot l+1 neighbour, in that cell's OWN (tan_a, tan_b) axes. See wind_step_sphere3d for why the
// frame is a separate table from the neighbour slots.
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };

layout(push_constant, std430) uniform Params {
	uint surf_count;     // number of COLUMNS = cell_count / depth (this kernel's thread count)
	uint depth;          // radial shells per column
	float core_radius;   // inner radius of shell 0
	float cell_size;     // radial cell height, and the lateral spacing used for the CFL number
	float sea_radius;    // sea shell radius — the atmosphere's floor over ocean
	float dt;            // STEP_DT
	uint step_index;     // 0 => seed the standard atmosphere (the channel starts at all-zero)
	uint pad0;
} params;

// --- air/pressure model -------------------------------------------------------------------------------
// H_PER_KELVIN is the scale height per kelvin, i.e. the gas constant over gravity in this world's units.
// 0.1736 puts H = 50 world units (3.1 cells) at 288 K, so the ~160-unit atmosphere above the sea shell spans
// about 3.2 scale heights — the same span-to-scale-height ratio Earth's troposphere-plus-stratosphere has.
const float H_PER_KELVIN = 0.1736;
const float T0_K = 273.15;         // celsius -> kelvin (the field stores celsius)
const float T_MIN_K = 180.0;       // scale-height guard: keeps H positive and finite next to lava/ice
const float T_MAX_K = 400.0;
const float H_REF = H_PER_KELVIN * 288.15;   // seed profile scale height (~50)
const float AIR_DENS_REF = 1.0;    // air mass in a sea-level cell of the seeded standard atmosphere
// Pressure per unit column mass. 33.5 puts a sea-level column (mass ~2.99 in the units above) at ~100, which
// is where the old P0 sat — so pass B's ACCEL/DAMP tuning still sees gradients of a familiar size.
const float G_ACC = 33.5;
// Fraction of a level's air crossing one face per step: the plain CFL number v*dt/dx, capped for stability.
// At MAX_WIND=24, dt=0.1, cell_size=16 this is 0.15, so the cap never binds in normal running; it exists so a
// transient cannot move more than a level holds. Both sides of a face evaluate the same expression, so the
// cap does not break conservation.
const float MAX_FACE_SHARE = 0.2;
// Turbulent mixing of air between neighbouring columns — the diffusive half of the transport operator, which
// every other transport kernel here carries (co2_transport's share() is DIFFUSE + ADVECT*..., DIFFUSE = 0.12).
// Advection alone leaves the grid-scale mass mode undamped: velocity and mass live on the SAME cell centres,
// and the centred pressure gradient 0.5*(p[+1]-p[-1]) is blind to a 2-cell checkerboard, so that mode feels no
// restoring force and grows until the MAX_WIND clamp stops it. Measured without this term: mean horizontal
// wind climbed 0.10 -> 11.0 and pinned max wind against the clamp, and a 5x change in free-atmosphere drag
// barely moved it (11.0 -> 8.9) precisely because the clamp, not the drag, was setting the level.
// Symmetric, so it conserves to the face exactly like the advective half.
const float DIFFUSE_FACE = 0.01;

// Fraction of a level's air crossing one face toward a neighbour it is moving at `toward` (>=0).
float face_share(float toward, float cfl) {
	return DIFFUSE_FACE + min(max(toward, 0.0) * cfl, MAX_FACE_SHARE);
}

// Component of cell `c`'s horizontal velocity pointing along its lateral link `l` (0..3 == neighbour slots
// 1..4), read in that cell's own tangent frame. This is what makes the exchange conservative WITHOUT assuming
// the slots are axes: cell A's outflow through a face uses toward(A, l), and the neighbour B computes its
// inflow from A as toward(A, l) too, because B sees A in the reverse slot and (l^1)^1 == l.
float toward(uint c, int l, uint depth) {
	uint b = ((c / depth) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// Is shell r of this column part of the free atmosphere? Caller walks inward and stops at the first false.
bool is_air(uint c, float radius) {
	return solid[c] == 0.0 && radius >= params.sea_radius;
}

void main() {
	uint s = gl_GlobalInvocationID.x;
	if (s >= params.surf_count) {
		return;
	}
	uint depth = params.depth;
	uint base = s * depth;

	// --- WALK 1: find the atmosphere — the contiguous non-solid, at-or-above-sea run down from the top. ---
	int r_top = int(depth) - 1;
	int r_bot = int(depth);          // depth => empty atmosphere
	for (int r = r_top; r >= 0; --r) {
		float radius = params.core_radius + (float(r) + 0.5) * params.cell_size;
		if (!is_air(base + uint(r), radius)) {
			break;
		}
		r_bot = r;
	}
	if (r_bot > r_top) {
		// No atmosphere over this column (fully buried). Zero the air and leave a neutral pressure so any
		// stray reader sees a flat field rather than garbage. Pass B never reads solid cells' pressure.
		for (uint r = 0u; r < depth; ++r) {
			air_out[base + r] = 0.0;
			pressure[base + r] = 0.0;
		}
		return;
	}

	// --- WALK 2: hydrostatic weights. w is a running product; sum it now, recompute it identically later. ---
	float w = 1.0;
	float sum_w = 1.0;
	for (int r = r_bot + 1; r <= r_top; ++r) {
		float t_mid = 0.5 * (temp[base + uint(r)] + temp[base + uint(r - 1)]) + T0_K;
		float h_scale = H_PER_KELVIN * clamp(t_mid, T_MIN_K, T_MAX_K);
		w *= exp(-params.cell_size / h_scale);
		sum_w += w;
	}

	// --- WALK 3: current column mass, and the vertically-integrated upwind mass flux through the 4 faces. ---
	// Face flux uses the SAME expression from both sides (this column's outflow toward a neighbour equals that
	// neighbour's inflow from us), so the exchange is conservative to the face. Shares are bounded by
	// MAX_FACE_SHARE and there are 4 faces, so a level can never lose more than 80% of its air in a step.
	float cfl = params.dt / params.cell_size;
	float m_col = 0.0;
	float flux_out = 0.0;
	float flux_in = 0.0;
	for (int r = r_bot; r <= r_top; ++r) {
		uint c = base + uint(r);
		float a = air_in[c];
		m_col += a;
		uint nb = c * 6u;
		// Each of the four lateral faces: my outflow is my velocity toward that neighbour, its inflow is that
		// neighbour's velocity back toward me (its own reverse link, l ^ 1). Both sides evaluate the same
		// expression per face, so the exchange conserves exactly — the property the old slot-as-axis form got
		// for free and this form keeps without needing the slot to be an axis.
		for (int l = 0; l < 4; ++l) {
			int m = nbr[nb + uint(l + 1)];
			if (m < 0 || solid[m] != 0.0) {
				continue;
			}
			flux_out += a * face_share(toward(c, l, depth), cfl);
			flux_in += air_in[m] * face_share(toward(uint(m), l ^ 1, depth), cfl);
		}
	}

	// --- New column mass. Step 0 seeds the standard atmosphere (the channel is allocated all-zero). ---
	// The seed integrates the reference profile from THIS column's own floor, so a column whose ground stands
	// high starts with less air above it — mountain tops begin at low pressure, for the right reason.
	float m_new;
	if (params.step_index == 0u) {
		float z_bot = params.core_radius + (float(r_bot) + 0.5) * params.cell_size;
		m_new = AIR_DENS_REF * exp(-(z_bot - params.sea_radius) / H_REF) * sum_w;
	} else {
		m_new = max(m_col + flux_in - flux_out, 0.0);
	}

	// --- WALK 4: settle that mass onto the hydrostatic profile (exactly conserving m_new). ---
	w = 1.0;
	float inv_sum = 1.0 / max(sum_w, 1.0e-6);
	air_out[base + uint(r_bot)] = m_new * w * inv_sum;
	for (int r = r_bot + 1; r <= r_top; ++r) {
		float t_mid = 0.5 * (temp[base + uint(r)] + temp[base + uint(r - 1)]) + T0_K;
		float h_scale = H_PER_KELVIN * clamp(t_mid, T_MIN_K, T_MAX_K);
		w *= exp(-params.cell_size / h_scale);
		air_out[base + uint(r)] = m_new * w * inv_sum;
	}

	// --- WALK 5: pressure = weight of the air above, integrated inward from space. ---
	float above = 0.0;
	for (int r = r_top; r >= r_bot; --r) {
		float a = air_out[base + uint(r)];
		pressure[base + uint(r)] = G_ACC * (above + 0.5 * a);   // cell-centred: half its own weight
		above += a;
	}
	// Everything below the atmosphere (rock, ocean interior, caves) holds no air and carries the column's
	// surface pressure, so the horizontal field stays continuous across the sea floor.
	float p_surf = G_ACC * above;
	for (int r = r_bot - 1; r >= 0; --r) {
		air_out[base + uint(r)] = 0.0;
		pressure[base + uint(r)] = p_surf;
	}
}
