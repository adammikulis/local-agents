#[compute]
#version 450

// CUBED-SPHERE CARBON DIOXIDE — TRANSPORT pass. The sphere port of co2_transport3d.glsl: IDENTICAL
// diffusion + wind advection + downward CO2_SETTLE bias and IDENTICAL constants; only neighbour addressing
// changes. The box gathered its 6 neighbours by idx±offset with bounds ifs; here every cell reads them from
// the precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 0 = inward/DOWN (-y), 1 = -x, 2 = +x, 3 = -z,
// 4 = +z, 5 = outward/UP (+y); -1 = boundary → skipped (matches the box's world-axis lateral convention,
// same as water_sphere3d). CO₂ is denser than air: it carries an extra CO2_SETTLE share DOWN (added to this
// cell's own outflow into slot 0 AND to the inflow it gathers from the cell ABOVE, slot 5 — mass-conserving).
// Wind is still read as world-axis velocity components (vel_x/y/z). Reads only the OLD co2 snapshot +
// wind + solid, writes co2_out[g]. Constants copied EXACTLY from co2_transport3d.glsl / MaterialGas3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CO2In  { float co2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer CO2Out { float co2_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX   { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelY   { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelZ   { float vel_z[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Transport tunables — MUST match co2_transport3d.glsl / MaterialGas3D.gd exactly.
const float DIFFUSE = 0.12;
const float ADVECT = 0.08;
const float INV_WIND_REF = 1.0 / 6.0;
const float CO2_SETTLE = 0.05;   // extra downward outflow share (buoyancy: CO₂ sinks)

// Outflow/inflow share toward a neighbour the wind blows toward at speed `toward` (>=0): diffusion + advection.
float share(float toward) {
	return DIFFUSE + ADVECT * clamp(max(0.0, toward) * INV_WIND_REF, 0.0, 1.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		co2_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;

	int nb_d = nbr[base + 0u];   // DOWN (-y)
	int nb_w = nbr[base + 1u];   // -x
	int nb_e = nbr[base + 2u];   // +x
	int nb_n = nbr[base + 3u];   // -z
	int nb_s = nbr[base + 4u];   // +z
	int nb_u = nbr[base + 5u];   // UP (+y)

	bool has_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool has_w = (nb_w >= 0) && (solid[nb_w] == 0.0);
	bool has_e = (nb_e >= 0) && (solid[nb_e] == 0.0);
	bool has_n = (nb_n >= 0) && (solid[nb_n] == 0.0);
	bool has_s = (nb_s >= 0) && (solid[nb_s] == 0.0);
	bool has_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	float vxi = vel_x[g];
	float vyi = vel_y[g];
	float vzi = vel_z[g];
	float out_e = has_e ? share(vxi) : 0.0;
	float out_w = has_w ? share(-vxi) : 0.0;
	float out_s = has_s ? share(vzi) : 0.0;
	float out_n = has_n ? share(-vzi) : 0.0;
	float out_u = has_u ? share(vyi) : 0.0;
	// Down carries an extra CO2_SETTLE (buoyant sink); up carries none.
	float out_d = has_d ? (share(-vyi) + CO2_SETTLE) : 0.0;
	float keep = 1.0 - (out_e + out_w + out_s + out_n + out_u + out_d);
	float acc = co2_in[g] * max(0.0, keep);

	// Inflow: each neighbour's share TOWARD this cell. The cell ABOVE also settles CO2_SETTLE down into us.
	if (has_e) { acc += co2_in[nb_e] * share(-vel_x[nb_e]); }
	if (has_w) { acc += co2_in[nb_w] * share(vel_x[nb_w]); }
	if (has_s) { acc += co2_in[nb_s] * share(-vel_z[nb_s]); }
	if (has_n) { acc += co2_in[nb_n] * share(vel_z[nb_n]); }
	if (has_u) { acc += co2_in[nb_u] * (share(-vel_y[nb_u]) + CO2_SETTLE); }
	if (has_d) { acc += co2_in[nb_d] * share(vel_y[nb_d]); }

	co2_out[g] = max(0.0, acc);
}
