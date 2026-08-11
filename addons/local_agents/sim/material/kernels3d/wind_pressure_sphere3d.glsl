#[compute]
#version 450


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
// LAPhysical.SCALE_HEIGHT_PER_K_MODEL = DRY_AIR_GAS_CONSTANT_J_KGK / (STANDARD_GRAVITY_M_S2 *
const float H_PER_KELVIN = 0.1735950488;   // LAPhysical.SCALE_HEIGHT_PER_K_MODEL
const float T0_K = 273.15;         // LAPhysical.KELVIN_OFFSET — the field stores celsius
const float T_MIN_K = 180.0;       // scale-height guard: keeps H positive and finite next to lava/ice
const float T_MAX_K = 400.0;
const float H_REF = H_PER_KELVIN * 288.15;   // seed profile scale height (~50)
const float AIR_DENS_REF = 1.0;    // air mass in a sea-level cell of the seeded standard atmosphere
const float GRAVITY_M_S2 = 9.80665;        // LAPhysical.STANDARD_GRAVITY_M_S2
const float AIR_DENSITY_KG_M3 = 1.18;      // LAPhysical.AIR_DENSITY_KG_M3
const float METRES_PER_MODEL_UNIT = 168.6; // LAPhysical.METRES_PER_MODEL_UNIT
const float MAX_FACE_SHARE = 0.2;
const float DIFFUSE_FACE = 0.01;

// Fraction of a level's air crossing one face toward a neighbour it is moving at `toward` (>=0).
float face_share(float toward, float cfl) {
	return DIFFUSE_FACE + min(max(toward, 0.0) * cfl, MAX_FACE_SHARE);
}

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
	float cfl = params.dt / params.cell_size;
	float m_col = 0.0;
	float flux_out = 0.0;
	float flux_in = 0.0;
	for (int r = r_bot; r <= r_top; ++r) {
		uint c = base + uint(r);
		float a = air_in[c];
		m_col += a;
		uint nb = c * 6u;
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
		// PASCALS: g * rho_air * (cell height in metres) * (air-units above, plus half this cell's own).
		pressure[base + uint(r)] = GRAVITY_M_S2 * AIR_DENSITY_KG_M3 * (params.cell_size * METRES_PER_MODEL_UNIT)
			* (above + 0.5 * a);
		above += a;
	}
	// Everything below the atmosphere (rock, ocean interior, caves) holds no air and carries the column's
	// surface pressure, so the horizontal field stays continuous across the sea floor.
	float p_surf = GRAVITY_M_S2 * AIR_DENSITY_KG_M3 * (params.cell_size * METRES_PER_MODEL_UNIT) * above;
	for (int r = r_bot - 1; r >= 0; --r) {
		air_out[base + uint(r)] = 0.0;
		pressure[base + uint(r)] = p_surf;
	}
}
