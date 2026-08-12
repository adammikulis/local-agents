#[compute]
#version 450

#include "neighbours.glsli"


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AirIn { float air_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer AirOut { float air_out[]; };  // written then re-read by the SAME thread
layout(set = 0, binding = 2, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer PressureOut { float pressure[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };   // along the cell's tan_a
layout(set = 0, binding = 6, std430) restrict readonly buffer VelZ { float vel_z[]; };   // along the cell's tan_b
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };     // idx*6 + slot
// LASphereGrid.link_tan: ((cell/depth)*4 + l)*2 is the unit direction toward the lateral slot N_LAT0+l
// neighbour, in that cell's own (tan_a, tan_b) axes.
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer LinkPartner { int partner[]; };
// LASphereGrid.link_arc: (cell/depth)*4 + l, radians between the two cell centres.
layout(set = 0, binding = 41, std430) restrict readonly buffer LinkArc { float larc[]; };

layout(push_constant, std430) uniform Params {
	uint surf_count;     // number of COLUMNS = cell_count / depth (this kernel's thread count)
	uint depth;          // radial shells per column
	float sea_radius;    // sea shell radius, model units — the atmosphere's floor over ocean
	float dt;            // seconds
	uint step_index;     // 0 => seed the standard atmosphere (the channel starts at all-zero)
	uint pad0;
	uint pad1;
	uint pad2;
} params;

#include "shell.glsli"
#include "cellvol.glsli"

const float H_PER_KELVIN = 0.1735950488;   // LAPhysical.SCALE_HEIGHT_PER_K_MODEL
const float T0_K = 273.15;         // LAPhysical.KELVIN_OFFSET
const float T_MIN_K = 180.0;       // scale-height guard: keeps H positive and finite next to lava/ice
const float T_MAX_K = 400.0;
const float H_REF = H_PER_KELVIN * 288.15;   // seed profile scale height, model units
const float GRAVITY_M_S2 = 9.80665;        // LAPhysical.STANDARD_GRAVITY_M_S2
const float AIR_DENSITY_KG_M3 = 1.225;     // LAPhysical.AIR_DENSITY_KG_M3
const float METRES_PER_MODEL_UNIT = 168.6; // LAPhysical.METRES_PER_MODEL_UNIT
const float DRY_AIR_GAS_CONSTANT_J_KGK = 287.0222603;  // LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK
const float STANDARD_PRESSURE_PA = 101325.0;        // LAPhysical.STANDARD_PRESSURE_PA
const float DIFFUSE_FACE = 0.01;

// Is this cell part of the atmosphere? A PER-CELL test, so the two ends of a face always agree.
bool is_air(uint c, uint depth) {
	return solid[c] == 0.0 && shell_mid(c % depth) >= params.sea_radius;
}

// Speed of cell `c` toward its lateral link `l`, m/s.
float toward(uint c, int l, uint depth) {
	uint b = ((c / depth) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// Centre-to-centre run of lateral link `l` of cell `c`, metres.
float link_run_m(uint c, int l, uint depth) {
	return larc[(c / depth) * 4u + uint(l)] * shell_mid(c % depth) * METRES_PER_MODEL_UNIT;
}

// Share of cell `c`'s air OFFERED across one face: advection at that face's own Courant number, plus mixing
// across the volume the pair share. A function of the donor and the face alone, so both ends agree on it.
float face_share(uint c, int l, uint depth) {
	int m = nbr[c * 6u + N_LAT0 + uint(l)];
	if (m < 0 || !is_air(uint(m), depth)) {
		return 0.0;
	}
	float run = max(link_run_m(c, l, depth), 1.0e-6);
	float adv = max(toward(c, l, depth), 0.0) * params.dt / run;
	float diff = DIFFUSE_FACE * min(cell_volume(c), cell_volume(uint(m))) / max(cell_volume(c), 1.0e-30);
	return adv + diff;
}

float offered_share(uint c, uint depth) {
	float t = 0.0;
	for (int l = 0; l < 4; ++l) {
		t += face_share(c, l, depth);
	}
	return t;
}

// Fraction of a cell's air that leaves in dt. A cell draining at a constant rate empties exponentially, so
// the total approaches 1 without ever reaching it and no face needs a cap.
float leaving(float offered) {
	return 1.0 - exp(-offered);
}

void main() {
	uint s = gl_GlobalInvocationID.x;
	if (s >= params.surf_count) {
		return;
	}
	uint depth = params.depth;
	uint base = s * depth;

	// --- WALK 1: the column's air cells, their hydrostatic weights, and the volume-weighted sum. ---
	float w = 1.0;
	float sum_wv = 0.0;
	int prev = -1;
	uint r_bot = depth;
	for (uint r = 0u; r < depth; ++r) {
		uint c = base + r;
		if (!is_air(c, depth)) {
			continue;
		}
		if (prev < 0) {
			r_bot = r;
		} else {
			float t_mid = 0.5 * (temp[c] + temp[uint(prev)]) + T0_K;
			float h_scale = H_PER_KELVIN * clamp(t_mid, T_MIN_K, T_MAX_K);
			w *= exp(-(shell_mid(r) - shell_mid(uint(prev) % depth)) / h_scale);
		}
		sum_wv += w * cell_volume(c);
		prev = int(c);
	}
	if (prev < 0) {
		for (uint r = 0u; r < depth; ++r) {
			air_out[base + r] = 0.0;
			pressure[base + r] = 0.0;
		}
		return;
	}

	// --- WALK 2: column mass and the lateral exchange, in ABSOLUTE amounts (fraction * volume). ---
	// Both ends of a face read the DONOR's share, so the debit and the credit are one number.
	float m_col = 0.0;
	float flux_out = 0.0;
	float flux_in = 0.0;
	for (uint r = 0u; r < depth; ++r) {
		uint c = base + r;
		if (!is_air(c, depth)) {
			continue;
		}
		float a = air_in[c];
		float vc = cell_volume(c);
		m_col += a * vc;
		float sc = offered_share(c, depth);
		float scale_c = (sc > 0.0) ? leaving(sc) / sc : 0.0;
		for (int l = 0; l < 4; ++l) {
			int m = nbr[c * 6u + N_LAT0 + uint(l)];
			int pi = partner[c * 6u + N_LAT0 + uint(l)];
			if (m < 0 || pi < 0 || !is_air(uint(m), depth)) {
				continue;
			}
			int el = int(uint(pi) % N_SLOTS) - int(N_LAT0);
			if (el < 0) {
				continue;
			}
			flux_out += a * vc * scale_c * face_share(c, l, depth);
			float sm = offered_share(uint(m), depth);
			if (sm > 0.0) {
				flux_in += air_in[m] * cell_volume(uint(m)) * (leaving(sm) / sm)
					* face_share(uint(m), el, depth);
			}
		}
	}

	// --- New column mass. Step 0 seeds it from the EQUATION OF STATE: the standard atmosphere's pressure at
	// this column's floor, over R_d T there. ---
	float m_new;
	if (params.step_index == 0u) {
		float t_bot_k = clamp(temp[base + r_bot] + T0_K, T_MIN_K, T_MAX_K);
		float p_floor = STANDARD_PRESSURE_PA * exp(-(shell_mid(r_bot) - params.sea_radius) / H_REF);
		float rho_floor = p_floor / (DRY_AIR_GAS_CONSTANT_J_KGK * t_bot_k);
		m_new = (rho_floor / AIR_DENSITY_KG_M3) * sum_wv;
	} else {
		m_new = m_col + flux_in - flux_out;
	}

	// --- WALK 3: settle that mass onto the hydrostatic profile, conserving m_new. ---
	w = 1.0;
	prev = -1;
	float inv_sum = 1.0 / max(sum_wv, 1.0e-30);
	for (uint r = 0u; r < depth; ++r) {
		uint c = base + r;
		if (!is_air(c, depth)) {
			continue;
		}
		if (prev >= 0) {
			float t_mid = 0.5 * (temp[c] + temp[uint(prev)]) + T0_K;
			float h_scale = H_PER_KELVIN * clamp(t_mid, T_MIN_K, T_MAX_K);
			w *= exp(-(shell_mid(r) - shell_mid(uint(prev) % depth)) / h_scale);
		}
		air_out[c] = m_new * w * inv_sum;
		prev = int(c);
	}

	// --- WALK 4: pressure = weight of the air above, integrated inward from space, pascals. A cell holding
	// no air carries the weight of the air standing over it. ---
	float above = 0.0;
	for (int r = int(depth) - 1; r >= 0; --r) {
		uint c = base + uint(r);
		if (!is_air(c, depth)) {
			air_out[c] = 0.0;
			pressure[c] = GRAVITY_M_S2 * AIR_DENSITY_KG_M3 * above;
			continue;
		}
		float a = air_out[c];
		float dz_m = shell_dr(uint(r)) * METRES_PER_MODEL_UNIT;
		pressure[c] = GRAVITY_M_S2 * AIR_DENSITY_KG_M3 * (above + 0.5 * a * dz_m);
		above += a * dz_m;
	}
}
